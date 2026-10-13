import Foundation
import CoreImage
import CoreGraphics

public struct FrameSelection: Codable, Hashable, Sendable {
    public var trimStart: Int = 0
    public var trimEnd: Int? = nil      // inclusive; nil = last
    public var dropBlurry = false
    public var blurThreshold = 0.55     // relative to the sequence median sharpness
    public var dropUntracked = true
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FrameSelection()
        trimStart = c.value(.trimStart, d.trimStart)
        trimEnd = c.value(.trimEnd, d.trimEnd)
        dropBlurry = c.value(.dropBlurry, d.dropBlurry)
        blurThreshold = c.value(.blurThreshold, d.blurThreshold)
        dropUntracked = c.value(.dropUntracked, d.dropUntracked)
    }
}

/// Largest power-of-two reduction (1, 1/2, 1/4, 1/8) that still gives at least `needed` source pixels
/// per original pixel. JPEG decodes at these scales directly in the DCT domain, which is much faster.
public func decodeScale(needed: Double) -> Double {
    var s = 1.0
    while s > 0.125 + 1e-9 && s / 2 >= needed { s /= 2 }
    return s
}

public extension FrameXform {
    func scaled(_ s: Double) -> FrameXform {
        var x = self; x.z *= s; x.p *= s; return x
    }
}

public enum FrameStatus: String, Sendable {
    case ok, excluded, blurry, untracked, trimmed
}

/// Everything needed to render frames for one set of settings.
public final class RenderJob: @unchecked Sendable {
    public let analysis: SequenceAnalysis
    public let track: Track
    public let composition: Composition
    public let look: LookSettings
    public let export: ExportSettings
    public let selection: FrameSelection
    public let plan: CompositionPlan
    public let gains: [[Double]]
    public let used: [Int]
    public let status: [FrameStatus]
    public let outputFrames: [OutputFrame]
    public let renderer: FrameRenderer
    public let cache: ProxyCache
    public let watermark: WatermarkSettings
    private var overlayCache: [String: CGImage] = [:]
    private var watermarkImage: CIImage??
    private let lock = NSLock()

    public init(analysis: SequenceAnalysis, composition: Composition, look: LookSettings, export: ExportSettings,
                selection: FrameSelection, watermark: WatermarkSettings = WatermarkSettings(),
                renderer: FrameRenderer = .shared, cache: ProxyCache = .shared) {
        self.analysis = analysis
        self.watermark = watermark
        self.track = analysis.track ?? TrackBuilder.build(analysis)
        self.composition = composition
        self.look = look
        self.export = export
        self.selection = selection
        self.renderer = renderer
        self.cache = cache
        let n = analysis.count
        let sharp = analysis.perFrame.map { $0.sharpness ?? .nan }
        let medSharp = Stats.median(sharp) ?? 0
        var st = [FrameStatus](repeating: .ok, count: n)
        let end = min(n - 1, selection.trimEnd ?? (n - 1))
        for i in 0..<n {
            if i < selection.trimStart || i > end { st[i] = .trimmed; continue }
            if analysis.excluded.contains(i) { st[i] = .excluded; continue }
            if selection.dropUntracked && !track.frames[i].hasData { st[i] = .untracked; continue }
            if selection.dropBlurry, sharp[i].isFinite, medSharp > 0, sharp[i] < medSharp * selection.blurThreshold { st[i] = .blurry }
        }
        status = st
        used = (0..<n).filter { st[$0] == .ok }
        let sz = export.outputSize
        plan = CompositionPlanner.plan(track: track, frames: analysis.frames, composition: composition,
                                       outW: Double(sz.w), outH: Double(sz.h), used: used.isEmpty ? nil : used)
        gains = Deflicker.gains(analysis, look: look)
        outputFrames = TimeMapper.outputFrames(used: used, sourceFPS: analysis.fps, settings: export)
    }

    public var outputSize: (w: Int, h: Int) { export.outputSize }
    public var duration: Double { Double(outputFrames.count) / export.outputFPS }
    public func contains(_ i: Int) -> Bool { i >= 0 && i < analysis.count && i < plan.xforms.count }

    /// Decode scale for exporting at full quality: enough pixels for the largest zoom of any used frame
    /// (plus headroom for the Lanczos downsample), but no more.
    public var exportDecodeScale: Double { decodeScale(needed: min(1, plan.maxUpscale * 1.2)) }

    /// Decoded source as CIImage plus its scale relative to the original pixel grid.
    /// - Parameter scale: decode the original at this fraction of its size (1 = full resolution)
    public func source(_ i: Int, proxy: Bool, scale: Double = 1) -> (CIImage, Double)? {
        guard i >= 0, i < analysis.count else { return nil }
        let f = analysis.frames[i]
        if proxy, let p = cache.loadProxy(fingerprint: analysis.fingerprint, index: i) {
            return (CIImage(cgImage: p), Double(p.width) / Double(f.pixelWidth))
        }
        let longSide = max(f.pixelWidth, f.pixelHeight)
        let maxPixel: Int? = scale < 0.999 ? Int((Double(longSide) * scale).rounded(.up)) : nil
        guard let cg = ImageLoader.load(f.url, maxPixel: maxPixel) else { return nil }
        return (CIImage(cgImage: cg), Double(cg.width) / Double(f.pixelWidth))
    }

    /// The watermark picture (loaded once), or nil when disabled / missing.
    public func watermarkCIImage() -> CIImage? {
        guard watermark.isActive, let path = watermark.imagePath else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let cached = watermarkImage { return cached }
        let img = ImageLoader.load(URL(fileURLWithPath: path)).map { CIImage(cgImage: $0) }
        watermarkImage = .some(img)
        return img
    }

    func overlays(for i: Int, outW: Int, outH: Int) -> [OverlayItem] {
        let o = export.overlay
        guard o.showExif || !o.customText.isEmpty else { return [] }
        let exif = o.exifPerFrame ? analysis.frames[i].exif : (analysis.frames.first?.exif ?? ExifInfo())
        let lines = TextOverlay.lines(for: exif, settings: o)
        let fs = Double(min(outW, outH)) * 0.022 * o.textScale
        let key = lines.joined(separator: "\n") + "|\(fs)"
        lock.lock(); var img = overlayCache[key]; lock.unlock()
        if img == nil {
            img = TextOverlay.render(lines: lines, fontSize: fs)
            lock.lock(); overlayCache[key] = img; lock.unlock()
        }
        guard let img else { return [] }
        let origin = TextOverlay.place(img, corner: o.corner, outW: outW, outH: outH, margin: Double(min(outW, outH)) * 0.03)
        return [OverlayItem(image: img, origin: origin, opacity: o.opacity)]
    }

    /// Compose one source frame into the output. `scale` < 1 renders a smaller preview.
    public func compose(frame i: Int, source: CIImage, sourceScale: Double, scale: Double = 1, withOverlays: Bool = true) -> CIImage {
        let sz = outputSize
        guard contains(i) else {
            return CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: max(2, Double(sz.w) * scale), height: max(2, Double(sz.h) * scale)))
        }
        let w = max(2, Int((Double(sz.w) * scale).rounded())), h = max(2, Int((Double(sz.h) * scale).rounded()))
        let xf = plan.xforms[i].scaled(Double(w) / Double(sz.w))
        let fill = composition.edgeFill
        return renderer.compose(source: source, sourceScale: sourceScale, originalHeight: Double(analysis.frames[i].pixelHeight),
                                xform: xf, outW: w, outH: h, gains: gains[i], edgeFill: fill,
                                overlays: withOverlays ? overlays(for: i, outW: w, outH: h) : [])
    }

    /// Render a single output frame (handles blending and fades). `fetch` supplies decoded sources.
    /// - Parameter includeWatermark: false for the interactive preview (the app draws the watermark itself so it can be dragged)
    public func renderOutput(_ of: OutputFrame, scale: Double = 1, includeWatermark: Bool = true, fetch: (Int) -> (CIImage, Double)?,
                             interpolate: ((CIImage, CIImage, Double) -> CIImage?)? = nil) -> CIImage? {
        guard contains(of.a), contains(of.b) else { return nil }
        guard let (sa, ka) = fetch(of.a) else { return nil }
        var img = compose(frame: of.a, source: sa, sourceScale: ka, scale: scale, withOverlays: false)
        if of.t > 0.001, of.b != of.a, let (sb, kb) = fetch(of.b) {
            let b = compose(frame: of.b, source: sb, sourceScale: kb, scale: scale, withOverlays: false)
            img = interpolate?(img, b, of.t) ?? FrameRenderer.blend(img, b, t: of.t)
        }
        let sz = outputSize
        let w = max(2, Int((Double(sz.w) * scale).rounded())), h = max(2, Int((Double(sz.h) * scale).rounded()))
        for o in overlays(for: of.a, outW: w, outH: h) {
            let oi = CIImage(cgImage: o.image)
            let y = Double(h) - Double(o.origin.y) - Double(o.image.height)
            var placed = oi.transformed(by: CGAffineTransform(translationX: o.origin.x, y: y))
            if o.opacity < 0.999 {
                placed = placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: o.opacity)])
            }
            img = placed.composited(over: img)
        }
        if includeWatermark, let wm = watermarkCIImage() {
            let r = watermark.rect(imageSize: wm.extent.size, outW: Double(w), outH: Double(h))
            if r.width >= 1 {
                let k = r.width / wm.extent.width
                var placed = k < 1
                    ? wm.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1.0])
                    : wm.transformed(by: CGAffineTransform(scaleX: k, y: k))
                placed = placed.transformed(by: CGAffineTransform(translationX: r.minX - placed.extent.minX,
                                                                  y: Double(h) - r.maxY - placed.extent.minY))
                if watermark.opacity < 0.999 {
                    placed = placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: watermark.opacity)])
                }
                img = placed.composited(over: img)
            }
        }
        if of.fade < 0.999 {
            let black = CIImage(color: .black).cropped(to: img.extent)
            img = FrameRenderer.blend(black, img, t: of.fade)
        }
        return img.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }
}
