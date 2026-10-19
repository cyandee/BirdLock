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
    private var overlayCacheBytes = 0
    private static let overlayCacheLimit = 64 * 1024 * 1024
    private var watermarkImage: CIImage??
    private let lock = NSLock()

    private func cacheOverlay(_ image: CGImage?, key: String) {
        guard let image else { return }
        let cost = image.bytesPerRow * image.height
        guard cost <= Self.overlayCacheLimit else { return }
        lock.lock(); defer { lock.unlock() }
        if let old = overlayCache.removeValue(forKey:key) { overlayCacheBytes -= old.bytesPerRow * old.height }
        if overlayCache.count >= 128 || overlayCacheBytes + cost > Self.overlayCacheLimit {
            overlayCache.removeAll(); overlayCacheBytes = 0
        }
        overlayCache[key] = image; overlayCacheBytes += cost
    }

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
        plan = ProjectTimeline.plan(analysis, track: track, composition: composition, width: Double(sz.w), height: Double(sz.h), used: used)
        gains = Deflicker.gains(analysis, look: look)
        if analysis.clips?.isEmpty == false || analysis.closeups?.isEmpty == false {
            outputFrames = ProjectTimeline.frames(used: used, clips: analysis.clips ?? [], closeups: analysis.closeups ?? [], fallbackFPS: analysis.fps, settings: export)
        } else { outputFrames = TimeMapper.outputFrames(used: used, sourceFPS: analysis.fps, settings: export) }
    }

    /// Derived events follow the final edit, including reverse/repeat, without duplicating saved tracks.
    public func mixedAudio(_ userAudio: AudioSettings? = nil) -> AudioSettings {
        var result = userAudio ?? AudioSettings()
        result.tracks += CloseupAudio.tracks(frames: outputFrames, closeups: analysis.closeups ?? [])
        return result
    }

    public var outputSize: (w: Int, h: Int) { export.outputSize }
    public var duration: Double { Double(outputFrames.count) / export.outputFPS }
    public func contains(_ i: Int) -> Bool { i >= 0 && i < analysis.count && i < plan.xforms.count }

    public func previewFrame(_ frame: Int) -> OutputFrame {
        if let index = analysis.closeups?.firstIndex(where: { $0.frame <= frame && frame <= max($0.frame, $0.endFrame) }),
           var of = outputFrames.first(where: { $0.closeup == index }) {
            of.shotTime = 0.35
            return of
        }
        return OutputFrame(a: frame, b: frame, t: 0, fade: 1)
    }

    /// Decode scale for exporting at full quality: enough pixels for the largest zoom of any used frame
    /// (plus headroom for the Lanczos downsample), but no more.
    public var exportDecodeScale: Double { decodeScale(needed: min(1, plan.maxUpscale * max(1, analysis.closeups?.map(\.zoom).max() ?? 1) * 1.2)) }

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
            cacheOverlay(img,key:key)
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
    /// Where the camera would show its AF frame in output frame `i`: the eye, or the head while the eye is hidden.
    /// Returns centre (output px at `scale`) and frame side.
    public func focusTarget(_ i: Int, scale: Double) -> (center: V2, side: Double)? {
        guard contains(i), track.frames.indices.contains(i) else { return nil }
        let tf = track.frames[i]
        guard tf.hasData else { return nil }
        let fm = export.focusMark
        let xf = plan.xforms[i].scaled(scale)
        let aircraft = analysis.analysisSubject == .aircraft
        let eyeSeen = !aircraft && (tf.eyeVisible || analysis.manualEye[i] != nil)
        let onHead = aircraft || (!eyeSeen && fm.headWhenHidden)
        let side = tf.headLength * xf.z * (onHead ? 1.3 : 0.42) * fm.size
        return (xf.map(onHead ? tf.headCenter : tf.eye), max(10 * scale, side))
    }

    public func focusRect(_ i: Int, target: String, scale: Double) -> CGRect? {
        let aircraft = analysis.analysisSubject == .aircraft
        if aircraft && target == "eye" { return nil }
        guard contains(i), track.frames[i].hasData || (aircraft && target == "body") else { return nil }
        if target == "eye", let t = focusTarget(i, scale: scale) {
            return CGRect(x: t.center.x - t.side / 2, y: t.center.y - t.side / 2, width: t.side, height: t.side)
        }
        let xf = plan.xforms[i].scaled(scale)
        if target == "head" {
            let c = xf.map(track.frames[i].headCenter)
            let side = max(10 * scale, track.frames[i].headLength * xf.z * 1.3 * export.focusMark.size)
            return CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
        }
        guard target == "body", let b = analysis.perFrame[i].targetBox else { return nil }
        var rect = b.rect
        if aircraft && track.frames[i].hasData {
            let nose = analysis.perFrame[i].aircraft?.nose
            if nose != nil || analysis.manualEye[i] != nil {
                let center = track.frames[i].headCenter
                let w = nose?.w ?? track.frames[i].headLength, h = nose?.h ?? track.frames[i].headLength
                rect = rect.union(CGRect(x: center.x-w/2,y: center.y-h/2,width: w,height: h))
            }
        }
        // Transform all four corners, including wings, before computing the output bounding box.
        let points = [V2(rect.minX, rect.minY), V2(rect.maxX, rect.minY), V2(rect.minX, rect.maxY), V2(rect.maxX, rect.maxY)].map(xf.map)
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let k = clamp(export.focusMark.bodySize, 0.5, 2.5) * 1.04
        return r.insetBy(dx: -r.width * (k - 1) / 2, dy: -r.height * (k - 1) / 2)
    }

    private func focusMark(_ of: OutputFrame, target: String, scale: Double, outH: Int) -> CIImage? {
        guard let a = focusRect(of.a, target: target, scale: scale) else { return nil }
        var r = a
        if of.t > 0.001, of.b != of.a, let b = focusRect(of.b, target: target, scale: scale) {
            r = CGRect(x: a.minX + (b.minX - a.minX) * of.t, y: a.minY + (b.minY - a.minY) * of.t,
                       width: a.width + (b.width - a.width) * of.t, height: a.height + (b.height - a.height) * of.t)
        }
        let fm = export.focusMark
        let outShort = Double(min(outputSize.w, outputSize.h)) * scale
        let line = max(1, (outShort * 0.0024 * fm.lineWidth).rounded())
        let outW = max(2, Int((Double(outputSize.w) * scale).rounded()))
        guard let layout = FocusMark.clippedLayout(rect:r,viewport:CGRect(x:0,y:0,width:outW,height:outH),line:line,style:fm.style) else { return nil }
        let color = fm.color(for: target)
        let key = "focus|\(layout.cacheKey)|\(line)|\(fm.style.rawValue)|\(color.rawValue)"
        lock.lock(); var cg = overlayCache[key]; lock.unlock()
        if cg == nil {
            cg = FocusMark.image(layout:layout,line:line,style:fm.style,color:color)
            cacheOverlay(cg,key:key)
        }
        guard let cg else { return nil }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX:layout.bounds.minX,
                                                                     y:Double(outH)-layout.bounds.maxY))
    }

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
        let fm = export.focusMark
        let flashOn = fm.flashOn(at: of.time)
        if fm.enabled {
            let targets = [("eye", fm.showEye), ("head", fm.showHead), ("body", fm.showBody && (!fm.blinkBody || flashOn))]
            for (target, enabled) in targets where enabled {
                if let mark = focusMark(of, target: target, scale: Double(w) / Double(sz.w), outH: h) { img = mark.composited(over: img) }
            }
        }
        if of.closeup >= 0, let shots = analysis.closeups, shots.indices.contains(of.closeup) {
            let shot = shots[of.closeup]
            let zoom = clamp(shot.zoom, 1, 8)
            let cx = clamp(shot.centerX, 0.5 / zoom, 1 - 0.5 / zoom)
            let cy = clamp(shot.centerY, 0.5 / zoom, 1 - 0.5 / zoom)
            img = img.transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))
                .transformed(by: CGAffineTransform(translationX: Double(w) * (0.5 - cx * zoom), y: Double(h) * (0.5 - (1 - cy) * zoom)))
                .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            if shot.animatedFrame {
                let phase = min(1, of.shotTime / 0.35)
                let fraction = 0.84 + 0.08 * (1 - pow(1 - phase, 3))
                if let mark = FocusMark.image(width: Int(Double(w) * fraction), height: Int(Double(h) * fraction),
                    line: max(1, Double(min(w,h)) * 0.002), style: .brackets, color: shot.color) {
                    let layer = CIImage(cgImage: mark)
                    img = layer.transformed(by: CGAffineTransform(translationX: (Double(w) - layer.extent.width)/2, y: (Double(h) - layer.extent.height)/2))
                        .applyingFilter("CIColorMatrix", parameters: ["inputAVector":CIVector(x:0,y:0,z:0,w:0.7 + 0.3 * sin(of.shotTime * .pi * 2))])
                        .composited(over: img)
                }
            }
        }
        for o in overlays(for: of.a, outW: w, outH: h) {
            let oi = CIImage(cgImage: o.image)
            let y = Double(h) - Double(o.origin.y) - Double(o.image.height)
            var placed = oi.transformed(by: CGAffineTransform(translationX: o.origin.x, y: y))
            if o.opacity < 0.999 {
                placed = placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: o.opacity)])
            }
            img = placed.composited(over: img)
        }
        if fm.captureFlash, flashOn {
            let fraction = clamp(fm.captureSize, 0.25, 0.98)
            if let mark = FocusMark.image(width: Int(Double(w) * fraction), height: Int(Double(h) * fraction),
                                          line: max(1, Double(min(w, h)) * 0.0012), style: .box, color: fm.captureColor) {
                let layer = CIImage(cgImage: mark)
                img = layer.transformed(by: CGAffineTransform(translationX: (Double(w) - layer.extent.width) / 2,
                                                               y: (Double(h) - layer.extent.height) / 2))
                    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.55)])
                    .composited(over: img)
            }
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
