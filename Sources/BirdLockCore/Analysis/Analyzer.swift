import Foundation
import CoreGraphics
import CryptoKit

public struct AnalyzerOptions: Sendable {
    public var proxyLongSide = 2560
    public var detectionThreshold = 0.15
    public var keypointMinConf = 0.35
    public var patchSize = 128
    public var patchHeadLengths = 3.0          // patch side in head lengths
    public var concurrency = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
    public init() {}
}

public enum AnalysisStage: String, Sendable {
    case detecting = "识别鸟"
    case keypoints = "定位鸟头/鸟眼"
    case registering = "亚像素配准"
    case solving = "计算轨迹"
    case aircraftDetecting = "识别飞机"
    case aircraftParts = "定位/跟踪机头"
    case background = "分析画面"
    case sharpness = "评估画面清晰度"
    case queued = "等待上次分析结束"
}

public typealias AnalysisProgress = @Sendable (AnalysisStage, Double) -> Void

/// Runs the full analysis of a burst.
public final class Analyzer: @unchecked Sendable {
    public let models: BirdModels
    public var options: AnalyzerOptions
    public let cache: ProxyCache

    public init(models: BirdModels, options: AnalyzerOptions = AnalyzerOptions(), cache: ProxyCache = .shared) {
        self.models = models
        self.options = options
        self.cache = cache
    }

    public static func fingerprint(_ frames: [SourceFrame]) -> String { fingerprint(frames, aircraftModelIdentity: nil) }

    /// Aircraft observations are isolated by the actual model and algorithm identity; bird keys stay unchanged.
    public static func fingerprint(_ frames: [SourceFrame], aircraftModelIdentity: String?) -> String {
        var h = SHA256()
        for f in frames { h.update(data: Data("\(f.url.path)|\(f.fileSize)|\(f.modified)\n".utf8)) }
        if let identity = aircraftModelIdentity { h.update(data: Data("subject=aircraft|model=\(identity)\n".utf8)) }
        return h.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func parallel(_ n: Int, _ body: @escaping (Int) -> Void, progress: ((Double) -> Void)?, isCancelled: @escaping () -> Bool) {
        let started = Date()
        let q = DispatchQueue(label: "birdlock.analyze", attributes: .concurrent)
        let group = DispatchGroup()
        let sem = DispatchSemaphore(value: options.concurrency)
        let lock = NSLock()
        var done = 0
        for i in 0..<n {
            if isCancelled() { break }
            sem.wait()
            group.enter()
            q.async {
                defer { sem.signal(); group.leave() }
                if isCancelled() { return }
                autoreleasepool { body(i) }
                lock.lock(); done += 1; let d = done; lock.unlock()
                progress?(Double(d) / Double(n))
            }
        }
        group.wait()
        Diagnostics.record("analysis parallel photos=\(n) workers=\(options.concurrency) seconds=\(Date().timeIntervalSince(started))")
    }

    public func analyze(frames: [SourceFrame], fps: Double, targetHint: (frame: Int, point: V2)? = nil,
                        progress: AnalysisProgress? = nil, isCancelled: @escaping @Sendable () -> Bool = { false },
                        clips: [BurstClip] = []) throws -> SequenceAnalysis {
        let n = frames.count
        let fp = Self.fingerprint(frames)
        var per = (0..<n).map { FrameAnalysis(index: $0) }
        let lock = NSLock()
        let opt = options
        let det = models.detector, pose = models.pose, schema = models.schema
        let cacheDir = cache.directory(for: fp)

        // ---- Pass 1: proxies, detection, background stats
        progress?(.detecting, 0)
        parallel(n, { i in
            let f = frames[i]
            let proxyURL = cacheDir.appendingPathComponent(String(format: "p%05d.jpg", i))
            var proxy: CGImage? = FileManager.default.fileExists(atPath: proxyURL.path) ? ImageLoader.load(proxyURL) : nil
            if proxy == nil {
                proxy = ImageLoader.load(f.url, maxPixel: opt.proxyLongSide)
                if let p = proxy { _ = ImageLoader.writeJPEG(p, to: proxyURL, quality: 0.9) }
            }
            guard let proxy else { return }
            let k = Double(f.pixelWidth) / Double(proxy.width)
            let dets = (try? det.detect(image: proxy, scoreThreshold: opt.detectionThreshold)) ?? []
            let boxes = dets.map { d in BoxD(x: d.x * k, y: d.y * k, w: d.w * k, h: d.h * k, score: d.score) }
            lock.lock(); per[i].birds = boxes; lock.unlock()
        }, progress: { p in progress?(.detecting, p) }, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }

        // ---- Target tracking
        let targets = TargetTracker.track(per.map { $0.birds }, hint: targetHint, clips: clips)
        for i in 0..<n { per[i].target = targets[i] }

        // ---- Pass 1b: keypoints on the tracked bird + background stats
        progress?(.keypoints, 0)
        parallel(n, { i in
            let f = frames[i]
            let proxyURL = cacheDir.appendingPathComponent(String(format: "p%05d.jpg", i))
            guard let proxy = ImageLoader.load(proxyURL) else { return }
            let k = Double(f.pixelWidth) / Double(proxy.width)
            lock.lock(); let box = per[i].targetBox; lock.unlock()
            let bg = Self.backgroundStats(proxy, exclude: box.map { b in
                CGRect(x: b.x / k, y: b.y / k, width: b.w / k, height: b.h / k).insetBy(dx: -b.w / k * 0.15, dy: -b.h / k * 0.15)
            })
            var kps: [Keypoint] = [], ps = 0.0
            if let b = box {
                let side = max(b.w, b.h) * (schema.inputCropExpand ?? 1.25)
                let crop = CGRect(x: b.center.x - side / 2, y: b.center.y - side / 2, width: side, height: side)
                // choose decode resolution: crop should be >= ~1.3x model input
                let needLong = Double(max(f.pixelWidth, f.pixelHeight)) * Double(pose.inputSize) * 1.3 / side
                var img: CGImage = proxy, kk = k
                if needLong > Double(max(proxy.width, proxy.height)) * 1.05 {
                    let target = Int(min(Double(max(f.pixelWidth, f.pixelHeight)), needLong))
                    if let hi = ImageLoader.load(f.url, maxPixel: target) {
                        img = hi; kk = Double(f.pixelWidth) / Double(hi.width)
                    }
                }
                let c = CGRect(x: crop.minX / kk, y: crop.minY / kk, width: crop.width / kk, height: crop.height / kk)
                if let ds = try? pose.detect(image: img, crop: c, classIndex: 0, scoreThreshold: 0.1), !ds.isEmpty {
                    // pick the pose detection that best overlaps the tracked box
                    let tb = Detection(x: b.x / kk, y: b.y / kk, w: b.w / kk, h: b.h / kk, score: 1, keypoints: [])
                    let best = ds.max { ($0.iou(tb) + 0.3 * $0.score) < ($1.iou(tb) + 0.3 * $1.score) }!
                    kps = best.keypoints.map { Keypoint(x: $0.x * kk, y: $0.y * kk, conf: $0.conf) }
                    ps = best.score
                }
            }
            let head = HeadObservation.from(keypoints: kps, schema: schema, minConf: opt.keypointMinConf)
            lock.lock()
            per[i].bgLinear = bg; per[i].keypoints = kps; per[i].poseScore = ps; per[i].head = head
            lock.unlock()
        }, progress: { p in progress?(.keypoints, p) }, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }

        var analysis = SequenceAnalysis(fingerprint: fp, frames: frames, fps: fps, proxyLongSide: opt.proxyLongSide,
                                        perFrame: per, poseSchema: schema, track: nil)
        analysis.clips = clips
        analysis.groupedDetection = true
        // ---- Initial track (no registration yet)
        progress?(.solving, 0)
        let initial = TrackBuilder.build(analysis)
        analysis.track = initial

        // ---- Pass 2: head patches (exact, resampling-free), sharpness, registration
        progress?(.registering, 0)
        var patches = [GrayPatch?](repeating: nil, count: n)
        var patchRects = [CGRect](repeating: .zero, count: n)
        let N = opt.patchSize
        // One decode scale and one patch factor for the whole sequence, so consecutive patches are
        // sampled identically (any sub-pixel convention offset cancels in the frame-to-frame deltas).
        let medHL = initial.medianHeadLength
        var g = 1.0
        for cand in [0.5, 0.25] where medHL * cand >= 90 { g = cand }
        let D = max(1, Int((medHL * g * opt.patchHeadLengths / Double(N)).rounded()))
        parallel(n, { i in
            let tf = initial.frames[i]
            guard tf.hasData else { return }
            let f = frames[i]
            let longSide = max(f.pixelWidth, f.pixelHeight)
            guard let img = ImageLoader.load(f.url, maxPixel: g < 1 ? Int((Double(longSide) * g).rounded()) : nil) else { return }
            let kk = Double(f.pixelWidth) / Double(img.width)
            let side = N * D
            let x0 = Int((tf.headCenter.x / kk - Double(side) / 2).rounded())
            let y0 = Int((tf.headCenter.y / kk - Double(side) / 2).rounded())
            let p = GrayPatch.extractExact(from: img, x0: x0, y0: y0, n: N, factor: D)
            let rect = CGRect(x: Double(x0) * kk, y: Double(y0) * kk, width: Double(side) * kk, height: Double(side) * kk)
            // sharpness on the head region at decode resolution (1:1)
            let hl = tf.headLength / kk
            let ss = Int(clamp(hl * 1.5, 16, 384))
            let sp = GrayPatch.extractExact(from: img, x0: Int(tf.headCenter.x / kk) - ss / 2, y0: Int(tf.headCenter.y / kk) - ss / 2, n: ss, factor: 1)
            let sharp = sp.map { Sharpness.score($0) }
            lock.lock(); patches[i] = p; patchRects[i] = rect; analysis.perFrame[i].sharpness = sharp; lock.unlock()
        }, progress: { p in progress?(.registering, p * 0.9) }, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }

        let pc = PhaseCorrelator(size: N)
        pc.setGaussianWindow(sigma: clamp(0.6 * medHL * g / Double(D), 8, Double(N) / 4))
        let cutStarts = Set(clips.dropFirst().map(\.start))
        for i in 1..<max(1, n) where i < n {
            if cutStarts.contains(i) { continue }
            guard let a = patches[i - 1], let b = patches[i] else { continue }
            guard let r = pc.correlate(a, b) else { continue }
            let ra = patchRects[i - 1], rb = patchRects[i]
            let sA = Double(ra.width) / Double(N), sB = Double(rb.width) / Double(N)
            let scale = 0.5 * (sA + sB)
            // head moved by: (patch origin difference) + shift in patch px * scale
            let ca = V2(Double(ra.midX), Double(ra.midY)), cb = V2(Double(rb.midX), Double(rb.midY))
            let delta = (cb - ca) + r.shift * scale
            analysis.perFrame[i].link = RegistrationLink(delta: delta, quality: r.quality, patchScale: scale)
        }
        progress?(.registering, 1)

        // ---- Final solve
        progress?(.solving, 0.5)
        analysis.track = TrackBuilder.build(analysis)
        progress?(.solving, 1)
        return analysis
    }

    /// Mean linear RGB of a heavily downsampled image, excluding `exclude` (image px coords of `img`).
    public static func backgroundStats(_ img: CGImage, exclude: CGRect?) -> [Double] {
        let W = 96, H = max(1, Int(Double(96) * Double(img.height) / Double(img.width)))
        var buf = [UInt8](repeating: 0, count: W * H * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        guard ok else { return [0, 0, 0] }
        var lut = [Double](repeating: 0, count: 256)
        for i in 0..<256 {
            let c = Double(i) / 255
            lut[i] = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let sx = Double(W) / Double(img.width), sy = Double(H) / Double(img.height)
        var sum = [0.0, 0.0, 0.0], cnt = 0.0
        for y in 0..<H {
            for x in 0..<W {
                if let e = exclude {
                    let px = (Double(x) + 0.5) / sx, py = (Double(y) + 0.5) / sy
                    if e.contains(CGPoint(x: px, y: py)) { continue }
                }
                let o = (y * W + x) * 4
                sum[0] += lut[Int(buf[o])]; sum[1] += lut[Int(buf[o + 1])]; sum[2] += lut[Int(buf[o + 2])]
                cnt += 1
            }
        }
        guard cnt > 0 else { return [0, 0, 0] }
        return sum.map { $0 / cnt }
    }
}

public enum Sharpness {
    /// Normalised Laplacian energy: var(Laplacian) / var(I). Exposure-invariant, higher = sharper.
    public static func score(_ p: GrayPatch) -> Double {
        let w = p.width, h = p.height
        guard w > 4, h > 4 else { return 0 }
        var s = 0.0, s2 = 0.0, c = 0.0
        var m = 0.0, m2 = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let v = Double(p.data[i])
                let lap = Double(p.data[i - 1] + p.data[i + 1] + p.data[i - w] + p.data[i + w]) - 4 * v
                s += lap; s2 += lap * lap; m += v; m2 += v * v; c += 1
            }
        }
        let vl = s2 / c - (s / c) * (s / c)
        let vi = m2 / c - (m / c) * (m / c)
        return vl / max(1e-6, vi)
    }
}
