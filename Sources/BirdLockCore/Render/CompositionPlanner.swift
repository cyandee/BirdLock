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
    /// Number of used frames where the desired crop exceeds the source image (before edge handling)
    public var outOfBoundsFrames: Int
    /// `.shift`: used frames where the crop was moved so the bird left its anchor point
    public var shiftedFrames: Int = 0
    /// `.shift` / `.autoZoom`: used frames that were zoomed in to stay inside the source
    public var zoomedFrames: Int = 0
    /// Used frames whose crop is limited by the size of the source image (framing wider than the photo)
    public var imageLimitedFrames: Int = 0
    /// Anchor X was mirrored for lead room (bird flies to the left)
    public var mirrored: Bool = false
}

public enum CompositionPlanner {
    static let corners: (Double, Double) -> [V2] = { w, h in [V2(0, 0), V2(w, 0), V2(0, h), V2(w, h)] }

    public static func plan(track: Track, frames: [SourceFrame], composition c: Composition,
                            outW: Double, outH: Double, used: [Int]? = nil) -> CompositionPlan {
        let n = track.frames.count
        let tf = track.frames
        let usedIdx = used ?? Array(0..<n)
        let usedSet = Set(usedIdx)

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
        let outAngle = medAng + off
        let facingRight = cos(outAngle) >= 0
        var u = c.anchorX
        let mirrored = c.autoLeadRoom && !facingRight
        if mirrored { u = 1 - u }
        let p = V2(u * outW, c.anchorY * outH)
        let shortSide = min(outW, outH)
        let outCorners = corners(outW, outH)

        var z = (0..<n).map { shortSide / (max(1e-3, c.framing) * refHL[$0]) }

        // Source-space bounding box of the crop for frame i at zoom zz (anchor kept at p).
        func cropBox(_ i: Int, _ zz: Double) -> (lo: V2, hi: V2) {
            var lo = V2(.infinity, .infinity), hi = V2(-.infinity, -.infinity)
            for o in outCorners {
                let e = (o - p).rotated(-psi[i]) / zz
                lo = V2(min(lo.x, e.x), min(lo.y, e.y)); hi = V2(max(hi.x, e.x), max(hi.y, e.y))
            }
            let a = V2(ax[i], ay[i])
            return (a + lo, a + hi)
        }
        func imageSize(_ i: Int) -> V2 { V2(Double(frames[i].pixelWidth), Double(frames[i].pixelHeight)) }

        // bounds check: zoom factor needed to keep the crop inside with the anchor fixed
        var need = [Double](repeating: 1, count: n)
        var oob = 0
        for i in 0..<n {
            let ws = Double(frames[i].pixelWidth), hs = Double(frames[i].pixelHeight)
            let a = V2(ax[i], ay[i])
            var zmin = 0.0
            for o in outCorners {
                let cv = (o - p).rotated(-psi[i])
                if cv.x < 0 { zmin = max(zmin, a.x > 0 ? -cv.x / a.x : .infinity) }
                if cv.x > 0 { zmin = max(zmin, ws - a.x > 0 ? cv.x / (ws - a.x) : .infinity) }
                if cv.y < 0 { zmin = max(zmin, a.y > 0 ? -cv.y / a.y : .infinity) }
                if cv.y > 0 { zmin = max(zmin, hs - a.y > 0 ? cv.y / (hs - a.y) : .infinity) }
            }
            need[i] = max(1, zmin / z[i])
            if need[i] > 1.0001 && usedSet.contains(i) { oob += 1 }
        }

        /// Smallest source translation that moves the crop inside the image (nil if it is larger than the image)
        func fitShift(_ i: Int, _ zz: Double) -> V2? {
            let (lo, hi) = cropBox(i, zz)
            let s = imageSize(i)
            guard hi.x - lo.x <= s.x + 1e-6, hi.y - lo.y <= s.y + 1e-6 else { return nil }
            return V2(clamp(0, -lo.x, s.x - hi.x), clamp(0, -lo.y, s.y - hi.y))
        }
        /// Output position of the anchor after moving the crop by `t` (source px)
        func anchorAfter(_ i: Int, _ zz: Double, _ t: V2) -> V2 { p - zz * t.rotated(psi[i]) }

        /// Slides each crop inside the photo (for frames that still exceed it at their final zoom), easing the
        /// slide in and out so the bird glides away from its anchor instead of jumping. Returns shifted anchors.
        func slideInside() -> [V2] {
            var dx = [Double](repeating: 0, count: n), dy = dx
            for i in 0..<n {
                let d = anchorAfter(i, z[i], fitShift(i, z[i]) ?? .zero) - p
                dx[i] = d.x; dy[i] = d.y
            }
            // Dilate each direction separately (moving further inside is always allowed), then re-clamp.
            func ease(_ v: [Double]) -> [Double] {
                let pos = Signal.gaussian(Signal.runningMax(v.map { max(0, $0) }, radius: 5), sigma: 2.5)
                let neg = Signal.gaussian(Signal.runningMax(v.map { max(0, -$0) }, radius: 5), sigma: 2.5)
                return (0..<v.count).map { i in max(pos[i], max(0, v[i])) - max(neg[i], max(0, -v[i])) }
            }
            dx = ease(dx); dy = ease(dy)
            return (0..<n).map { i in
                var t = -(V2(dx[i], dy[i]).rotated(-psi[i])) / z[i]
                let (lo, hi) = cropBox(i, z[i])
                let s = imageSize(i)
                t.x = hi.x - lo.x <= s.x + 1e-6 ? clamp(t.x, -lo.x, s.x - hi.x) : (s.x - lo.x - hi.x) / 2
                t.y = hi.y - lo.y <= s.y + 1e-6 ? clamp(t.y, -lo.y, s.y - hi.y) : (s.y - lo.y - hi.y) / 2
                return anchorAfter(i, z[i], t)
            }
        }

        var anchors = [V2](repeating: p, count: n)
        var zoomed = 0, limited = 0
        switch c.edgeFill {
        case .autoZoom:
            // Cap the zoom at 8× (beyond that the crop slides instead) – but always zoom enough for the crop to fit the photo
            let capped = (0..<n).map { i -> Double in
                let (lo, hi) = cropBox(i, z[i])
                let s = imageSize(i)
                let fit = max(1, (hi.x - lo.x) / s.x, (hi.y - lo.y) / s.y) * (1 + 1e-9)
                return min(need[i].isFinite ? need[i] : 8, max(8, fit))
            }
            var r = Signal.runningMax(capped, radius: 9)
            r = Signal.gaussian(r, sigma: 3)
            for i in 0..<n {
                z[i] *= max(r[i], capped[i])
                if usedSet.contains(i) && max(r[i], capped[i]) > 1.001 { zoomed += 1 }
            }
            // Beyond the zoom cap (bird right at the photo's edge) slide the crop rather than show black
            anchors = slideInside()
        case .shift:
            // Virtual camera constrained to the photo: the crop keeps its size (up to the size of the photo)
            // and slides inside the image when the bird gets close to an edge. The bird then leaves its
            // anchor, but never closer to the output edge than `edgeMargin` – unless that would need more
            // than `maxEdgeZoom` of extra zoom.
            let m = clamp(c.edgeMargin, 0, 0.45)
            let safeLo = V2(min(m * outW, p.x), min(m * outH, p.y))
            let safeHi = V2(max((1 - m) * outW, p.x), max((1 - m) * outH, p.y))
            func inSafe(_ q: V2) -> Bool { q.x >= safeLo.x - 0.5 && q.x <= safeHi.x + 0.5 && q.y >= safeLo.y - 0.5 && q.y <= safeHi.y + 0.5 }

            var k = [Double](repeating: 1, count: n)
            var kFit = [Double](repeating: 1, count: n)
            for i in 0..<n {
                let (lo, hi) = cropBox(i, z[i])
                let s = imageSize(i)
                kFit[i] = max(1, (hi.x - lo.x) / s.x, (hi.y - lo.y) / s.y) * (1 + 1e-9)
                func ok(_ kk: Double) -> Bool {
                    guard let t = fitShift(i, z[i] * kk) else { return false }
                    return inSafe(anchorAfter(i, z[i] * kk, t))
                }
                var lo2 = kFit[i]
                if ok(lo2) { k[i] = lo2; continue }
                let kMax = kFit[i] * max(1, c.maxEdgeZoom)
                if !ok(kMax) { k[i] = kMax; continue }
                var hi2 = kMax
                for _ in 0..<24 { let mid = 0.5 * (lo2 + hi2); if ok(mid) { hi2 = mid } else { lo2 = mid } }
                k[i] = hi2
            }
            // Gradual zoom changes (zoom in early, release slowly)
            var r = Signal.runningMax(k, radius: 9)
            r = Signal.gaussian(r, sigma: 3)
            for i in 0..<n {
                let kk = max(r[i], k[i])
                z[i] *= kk
                if usedSet.contains(i) {
                    if kFit[i] > 1.001 { limited += 1 }
                    if kk > kFit[i] * 1.001 { zoomed += 1 }
                }
            }
            anchors = slideInside()
        case .blurExtend, .black:
            break
        }
        let shifted = usedIdx.filter { (anchors[$0] - p).length > 0.5 }.count

        var xf: [FrameXform] = []
        for i in 0..<n {
            xf.append(FrameXform(a: V2(ax[i], ay[i]), p: anchors[i], z: z[i], psi: psi[i], valid: tf[i].hasData))
        }
        let maxUp = usedIdx.map { xf[$0].z }.max() ?? 1
        return CompositionPlan(xforms: xf, outW: outW, outH: outH, maxUpscale: maxUp, outOfBoundsFrames: oob,
                               shiftedFrames: shifted, zoomedFrames: zoomed, imageLimitedFrames: limited, mirrored: mirrored)
    }
}
