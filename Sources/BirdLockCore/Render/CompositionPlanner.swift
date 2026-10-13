import Foundation
import CoreGraphics

/// Mapping from source pixel coords (top-left origin) to output pixel coords:
///     o = p + z · R(psi) · (q − a)
public struct FrameXform: Codable, Sendable {
    public var a: V2       // source anchor
    public var p: V2       // output anchor position
    public var z: Double   // output px per source px
    public var psi: Double // rotation (radians, image coords)
    public var valid: Bool

    public init(a: V2, p: V2, z: Double, psi: Double, valid: Bool) {
        self.a = a; self.p = p; self.z = z; self.psi = psi; self.valid = valid
    }

    public func map(_ q: V2) -> V2 { p + z * (q - a).rotated(psi) }
    public func unmap(_ o: V2) -> V2 { a + ((o - p) / z).rotated(-psi) }

    /// CGAffineTransform in top-left pixel coordinates
    public var affine: CGAffineTransform {
        let c = cos(psi) * z, s = sin(psi) * z
        // o = M q + t,  M = [[c, -s],[s, c]], t = p - M a
        let tx = p.x - (c * a.x - s * a.y)
        let ty = p.y - (s * a.x + c * a.y)
        return CGAffineTransform(a: c, b: s, c: -s, d: c, tx: tx, ty: ty)
    }

    /// Source-space quadrilateral covered by the output frame
    public func sourceQuad(outW: Double, outH: Double) -> [V2] {
        [V2(0, 0), V2(outW, 0), V2(outW, outH), V2(0, outH)].map(unmap)
    }
}

public struct CompositionPlan: Sendable {
    public var xforms: [FrameXform]   // indexed by frame index
    public var outW: Double
    public var outH: Double
    /// Largest output/source pixel ratio among used frames (>1 means upscaling)
    public var maxUpscale: Double
    /// Number of frames where the crop exceeds the source image (before edge handling)
    public var outOfBoundsFrames: Int
}

public enum CompositionPlanner {
    public static func plan(track: Track, frames: [SourceFrame], composition c: Composition,
                            outW: Double, outH: Double, used: [Int]? = nil) -> CompositionPlan {
        let n = track.frames.count
        let tf = track.frames
        let usedIdx = used ?? Array(0..<n)

        // anchor in source
        var ax = tf.map { c.lockPoint == .eye ? $0.eye.x : $0.headCenter.x }
        var ay = tf.map { c.lockPoint == .eye ? $0.eye.y : $0.headCenter.y }
        if c.followSoftness > 0.001 {
            let sigma = c.followSoftness * 25
            ax = Signal.gaussian(ax, sigma: sigma)
            ay = Signal.gaussian(ay, sigma: sigma)
        }

        // reference head length
        let hl = tf.map { $0.headLength }
        let usedHL = usedIdx.map { hl[$0] }
        let medHL = Stats.median(usedHL) ?? track.medianHeadLength
        var refHL: [Double]
        switch c.sizeMode {
        case .fixedCrop: refHL = Array(repeating: medHL, count: n)
        case .lockSize: refHL = Signal.gaussian(hl.map { log($0) }, sigma: max(2, c.sizeSmoothing)).map { exp($0) }
        }

        // rotation
        let ang = tf.map { $0.angle }
        let medAng = Stats.median(usedIdx.map { ang[$0] }) ?? 0
        let off = c.rotationOffsetDeg * .pi / 180
        var psi: [Double]
        switch c.rotationMode {
        case .none: psi = Array(repeating: off, count: n)
        case .lockHead: psi = Signal.gaussian(ang, sigma: 2).map { -($0 - medAng) + off }
        case .followHeadSmooth: psi = Signal.gaussian(ang, sigma: 20).map { -0.7 * ($0 - medAng) + off }
        }

        // output anchor position (with lead room)
        let outAngle = (c.rotationMode == .none ? medAng : medAng) + off
        let facingRight = cos(outAngle) >= 0
        var u = c.anchorX
        if c.autoLeadRoom && !facingRight { u = 1 - u }
        let p = V2(u * outW, c.anchorY * outH)
        let shortSide = min(outW, outH)

        var z = (0..<n).map { shortSide / (max(1e-3, c.framing) * refHL[$0]) }

        // bounds check / auto zoom
        var need = [Double](repeating: 1, count: n)
        var oob = 0
        for i in 0..<n {
            let ws = Double(frames[i].pixelWidth), hs = Double(frames[i].pixelHeight)
            let a = V2(ax[i], ay[i])
            var zmin = 0.0
            for o in [V2(0, 0), V2(outW, 0), V2(0, outH), V2(outW, outH)] {
                let cv = (o - p).rotated(-psi[i])
                if cv.x < 0 { zmin = max(zmin, a.x > 0 ? -cv.x / a.x : .infinity) }
                if cv.x > 0 { zmin = max(zmin, ws - a.x > 0 ? cv.x / (ws - a.x) : .infinity) }
                if cv.y < 0 { zmin = max(zmin, a.y > 0 ? -cv.y / a.y : .infinity) }
                if cv.y > 0 { zmin = max(zmin, hs - a.y > 0 ? cv.y / (hs - a.y) : .infinity) }
            }
            need[i] = max(1, zmin / z[i])
            if need[i] > 1.0001 && usedIdx.contains(i) { oob += 1 }
        }
        if c.edgeFill == .autoZoom {
            let capped = need.map { min($0.isFinite ? $0 : 8, 8) }
            var r = Signal.runningMax(capped, radius: 9)
            r = Signal.gaussian(r, sigma: 3)
            for i in 0..<n { z[i] *= max(r[i], capped[i]) }
        }

        var xf: [FrameXform] = []
        for i in 0..<n {
            xf.append(FrameXform(a: V2(ax[i], ay[i]), p: p, z: z[i], psi: psi[i], valid: tf[i].hasData))
        }
        let maxUp = usedIdx.map { xf[$0].z }.max() ?? 1
        return CompositionPlan(xforms: xf, outW: outW, outH: outH, maxUpscale: maxUp, outOfBoundsFrames: oob)
    }
}
