import Foundation
import CoreImage
import CoreGraphics
import Metal

public struct LookSettings: Codable, Hashable, Sendable {
    public var deflicker: Bool = true
    public var deflickerStrength: Double = 1.0
    public var deflickerWindow: Double = 8     // frames (gaussian sigma)
    public var exposureEV: Double = 0
    public var stabilization = VideoStabilizationSettings()
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LookSettings()
        deflicker = c.value(.deflicker, d.deflicker)
        deflickerStrength = c.value(.deflickerStrength, d.deflickerStrength)
        deflickerWindow = c.value(.deflickerWindow, d.deflickerWindow)
        exposureEV = c.value(.exposureEV, d.exposureEV)
        stabilization = c.value(.stabilization, d.stabilization)
    }
}

/// Per-frame RGB gains that remove exposure/white-balance flicker.
public enum Deflicker {
    public static func gains(_ a: SequenceAnalysis, look: LookSettings) -> [[Double]] {
        if let clips = a.clips, clips.count > 1 {
            return clips.flatMap { clip -> [[Double]] in
                var sub = a
                let range = clip.start..<(clip.start + clip.count)
                sub.frames = Array(a.frames[range]); sub.perFrame = Array(a.perFrame[range]); sub.clips = nil
                return gains(sub, look: look)
            }
        }
        let n = a.count
        let ev = pow(2, look.exposureEV)
        guard look.deflicker, n > 2 else { return Array(repeating: [ev, ev, ev], count: n) }
        var out = Array(repeating: [ev, ev, ev], count: n)
        for ch in 0..<3 {
            let lg = a.perFrame.map { $0.bgLinear[ch] > 1e-5 ? log($0.bgLinear[ch]) : .nan }
            // robust target: running median then gaussian
            var tgt = Signal.median(lg, radius: Int(look.deflickerWindow))
            tgt = Signal.gaussian(tgt, sigma: look.deflickerWindow)
            for i in 0..<n where lg[i].isFinite && tgt[i].isFinite {
                let g = exp((tgt[i] - lg[i]) * look.deflickerStrength)
                out[i][ch] = clamp(g, 0.5, 2.0) * ev
            }
        }
        return out
    }
}

public struct OverlayItem: Sendable {
    public var image: CGImage
    public var origin: CGPoint   // top-left in output px
    public var opacity: Double
}

/// Renders one output frame with Core Image (Metal backed).
public final class FrameRenderer: @unchecked Sendable {
    public let context: CIContext
    public static let shared = FrameRenderer()
    private static let projectiveKernel = CIWarpKernel(source: """
        kernel vec2 stabilizedSource(vec3 row0, vec3 row1, vec3 row2) {
            vec3 p = vec3(destCoord(), 1.0);
            vec3 q = vec3(dot(row0, p), dot(row1, p), dot(row2, p));
            return q.xy / q.z;
        }
        """)

    public init() {
        let opts: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .cacheIntermediates: false,
            .name: "BirdLock",
        ]
        if let dev = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: dev, options: opts)
        } else {
            context = CIContext(options: opts)
        }
    }

    /// Build the output CIImage (extent = 0,0,outW,outH in CI bottom-left coords).
    /// - Parameters:
    ///   - source: decoded source (full res or a proxy)
    ///   - sourceScale: source-image pixels per original-source pixel (proxy = proxyW / fullW)
    public func compose(source: CIImage, sourceScale: Double, originalHeight: Double, xform: FrameXform,
                        outW: Int, outH: Int, gains: [Double], edgeFill: EdgeFill, overlays: [OverlayItem] = []) -> CIImage {
        var img = source
        let Hs = Double(source.extent.height)
        // Exposure / flicker gains in linear working space
        if gains.count == 3, gains.contains(where: { abs($0 - 1) > 1e-4 }) {
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gains[0], y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gains[1], z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gains[2], w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        }
        // Total transform from *this image's* top-left pixel coords to output top-left coords:
        //   o = M_xf · (q_img / sourceScale)
        let zEff = xform.z / sourceScale
        var preScale = 1.0
        var work = img
        let extent = img.extent
        if zEff < 0.6 {
            // High quality downsample first (Lanczos), the residual transform is then ~unit scale.
            preScale = zEff
            // Restrict to the area we need (plus margin) to save work
            let quad = xform.sourceQuad(outW: Double(outW), outH: Double(outH)).map { $0 * sourceScale }
            let xs = quad.map { $0.x }, ys = quad.map { $0.y }
            let margin = 8 / zEff
            let r = CGRect(x: xs.min()! - margin, y: Hs - ys.max()! - margin,
                           width: xs.max()! - xs.min()! + 2 * margin, height: ys.max()! - ys.min()! + 2 * margin)
            let roi = r.intersection(extent)
            if !roi.isNull, roi.width > 2, roi.height > 2 {
                work = work.cropped(to: roi)
            }
            work = work.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: preScale, kCIInputAspectRatioKey: 1.0])
        }
        // Build the CI-space affine:  CI (bottom-left) coords of `work` -> CI coords of output.
        // work CI coords w = preScale * (q_img_ci);  q_img_ci = (x, Hs - y_top)
        let M = xform.affine // top-left source(original) -> top-left output
        var T = CGAffineTransform.identity
        // 1. work CI -> img CI
        T = T.concatenating(CGAffineTransform(scaleX: 1 / preScale, y: 1 / preScale))
        // 2. img CI (bottom-left) -> img top-left
        T = T.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: Hs))
        // 3. img top-left -> original top-left
        T = T.concatenating(CGAffineTransform(scaleX: 1 / sourceScale, y: 1 / sourceScale))
        // 4. original -> output top-left
        T = T.concatenating(M)
        // 5. output top-left -> output CI
        T = T.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: Double(outH)))

        let outRect = CGRect(x: 0, y: 0, width: outW, height: outH)
        // Compose the projective camera correction and subject framing in one sampling pass.
        // The inverse maps output CI pixels directly into the (possibly Lanczos reduced) source.
        let inverseProjective: Mat3? = xform.prewarp.flatMap { values in
            guard values.count == 9, values.allSatisfy(\.isFinite) else { return nil }
            let affine = Mat3([Double(M.a),Double(M.c),Double(M.tx),Double(M.b),Double(M.d),Double(M.ty),0,0,1])
            guard let inverse = (affine * Mat3(values)).inverse else { return nil }
            let outputFlip = Mat3([1,0,0,0,-1,Double(outH),0,0,1])
            let sourceCI = Mat3([sourceScale*preScale,0,0,0,-sourceScale*preScale,Hs*preScale,0,0,1])
            return sourceCI * inverse * outputFlip
        }
        func transformed(_ input: CIImage) -> CIImage {
            guard let inverseProjective, let kernel = Self.projectiveKernel else { return input.transformed(by: T, highQualityDownsample: false) }
            let values = inverseProjective.v
            let vectors = stride(from:0,to:9,by:3).map { CIVector(x:values[$0],y:values[$0+1],z:values[$0+2]) }
            return kernel.apply(extent:outRect,roiCallback:{ _, rect in
                let corners = [V2(rect.minX,rect.minY),V2(rect.maxX,rect.minY),V2(rect.maxX,rect.maxY),V2(rect.minX,rect.maxY)].map(inverseProjective.apply)
                guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return work.extent }
                let xs = corners.map(\.x), ys = corners.map(\.y)
                return CGRect(x:xs.min()!-3,y:ys.min()!-3,width:xs.max()!-xs.min()!+6,height:ys.max()!-ys.min()!+6)
            },image:input,arguments:vectors) ?? input.transformed(by:T,highQualityDownsample:false)
        }
        var result: CIImage
        switch edgeFill {
        case .black, .autoZoom, .shift:
            let base = CIImage(color: .black).cropped(to: outRect)
            result = transformed(work).composited(over: base)
        case .blurExtend:
            let bg = transformed(work.clampedToExtent()).applyingGaussianBlur(sigma: Double(min(outW, outH)) * 0.02).cropped(to: outRect)
            result = transformed(work).composited(over: bg)
        }
        for o in overlays {
            let oi = CIImage(cgImage: o.image)
            let y = Double(outH) - Double(o.origin.y) - Double(o.image.height)
            var placed = oi.transformed(by: CGAffineTransform(translationX: o.origin.x, y: y))
            if o.opacity < 0.999 {
                placed = placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: o.opacity)])
            }
            result = placed.composited(over: result)
        }
        return result.cropped(to: outRect)
    }

    public func renderCGImage(_ img: CIImage) -> CGImage? {
        context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// Blend two output images (for frame blending interpolation)
    public static func blend(_ a: CIImage, _ b: CIImage, t: Double) -> CIImage {
        guard t > 0.001 else { return a }
        guard t < 0.999 else { return b }
        return a.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: b, kCIInputTimeKey: t])
    }
}
