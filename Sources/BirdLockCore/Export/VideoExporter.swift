import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

public enum ExportError: Error, LocalizedError {
    case noFrames, writer(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .noFrames: return "没有可导出的帧"
        case .writer(let s): return "视频写入失败：\(s)"
        case .cancelled: return "已取消"
        }
    }
}

/// Small LRU of decoded full-resolution sources, filled ahead of time on background threads.
final class SourcePrefetcher: @unchecked Sendable {
    private let job: RenderJob
    private let proxy: Bool
    private var cache: [Int: (CIImage, Double)] = [:]
    private var inflight: [Int: DispatchGroup] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "birdlock.prefetch", attributes: .concurrent)
    private let limit: Int

    init(job: RenderJob, proxy: Bool, limit: Int = 12) { self.job = job; self.proxy = proxy; self.limit = limit }

    func prefetch(_ idx: [Int]) {
        for i in idx { start(i) }
    }

    private func start(_ i: Int) {
        lock.lock()
        if cache[i] != nil || inflight[i] != nil { lock.unlock(); return }
        let g = DispatchGroup(); g.enter(); inflight[i] = g
        lock.unlock()
        queue.async { [self] in
            // Force decode now (CGImage from ImageIO with ShouldCacheImmediately)
            let s = job.source(i, proxy: proxy)
            lock.lock()
            if let s { cache[i] = s }
            inflight[i] = nil
            lock.unlock()
            g.leave()
        }
    }

    func get(_ i: Int) -> (CIImage, Double)? {
        start(i)
        lock.lock(); let g = inflight[i]; lock.unlock()
        g?.wait()
        lock.lock(); defer { lock.unlock() }
        return cache[i]
    }

    func evict(keeping keep: Set<Int>) {
        lock.lock()
        if cache.count > limit { for k in cache.keys where !keep.contains(k) { cache[k] = nil } }
        lock.unlock()
    }
}

public final class VideoExporter {
    public init() {}

    public func export(job: RenderJob, to url: URL, progress: @escaping (Double) -> Void,
                       isCancelled: @escaping () -> Bool) throws {
        let frames = job.outputFrames
        guard !frames.isEmpty else { throw ExportError.noFrames }
        let (W, H) = job.outputSize
        let s = job.export
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: s.codec.fileType)
        var settings: [String: Any] = [
            AVVideoCodecKey: s.codec.avCodec,
            AVVideoWidthKey: W,
            AVVideoHeightKey: H,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if s.codec == .h264 || s.codec == .hevc {
            let bpp = s.quality.bpp * (s.codec == .hevc ? 0.6 : 1)
            let bitrate = Double(W * H) * s.outputFPS * bpp
            var comp: [String: Any] = [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoExpectedSourceFrameRateKey: Int(s.outputFPS.rounded()),
                AVVideoMaxKeyFrameIntervalKey: Int(s.outputFPS.rounded()),
                AVVideoAllowFrameReorderingKey: true,
            ]
            if s.codec == .h264 { comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            settings[AVVideoCompressionPropertiesKey] = comp
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: W,
            kCVPixelBufferHeightKey as String: H,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        guard writer.canAdd(input) else { throw ExportError.writer("cannot add input") }
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        let pre = SourcePrefetcher(job: job, proxy: !s.useFullResolution)
        let lookahead = 8
        let timescale: CMTimeScale = 60000
        let frameDur = CMTime(value: CMTimeValue((Double(timescale) / s.outputFPS).rounded()), timescale: timescale)
        let cs709 = CGColorSpace(name: CGColorSpace.itur_709)!
        var lastKey: OutputFrame? = nil
        var lastBuffer: CVPixelBuffer? = nil
        var interp: ((CIImage, CIImage, Double) -> CIImage?)? = nil
        var aiBox: AnyObject? = nil
        if s.interpolation == .ai, #available(macOS 15.4, *), AIInterpolator.isSupported,
           let ai = AIInterpolator(width: W, height: H, context: job.renderer.context) {
            aiBox = ai
            interp = { a, b, t in ai.interpolate(a, b, phase: t) }
        }
        defer { _ = aiBox }

        for (k, of) in frames.enumerated() {
            if isCancelled() { writer.cancelWriting(); throw ExportError.cancelled }
            // Prefetch upcoming sources
            var ahead: [Int] = []
            for j in k..<min(frames.count, k + lookahead) { ahead.append(frames[j].a); if frames[j].t > 0 { ahead.append(frames[j].b) } }
            pre.prefetch(ahead)

            while !input.isReadyForMoreMediaData {
                if isCancelled() { writer.cancelWriting(); throw ExportError.cancelled }
                Thread.sleep(forTimeInterval: 0.002)
            }
            var pbOut: CVPixelBuffer? = nil
            if let lk = lastKey, lk == of, let lb = lastBuffer {
                pbOut = lb   // identical frame (slow-motion hold) – reuse
            } else {
                guard let pool = adaptor.pixelBufferPool else { throw ExportError.writer("no pixel buffer pool") }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                guard let pb else { throw ExportError.writer("pixel buffer") }
                guard let img = job.renderOutput(of, fetch: { pre.get($0) }, interpolate: interp) else { continue }
                job.renderer.context.render(img, to: pb, bounds: CGRect(x: 0, y: 0, width: W, height: H), colorSpace: cs709)
                CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                pbOut = pb
            }
            let t = CMTimeMultiply(frameDur, multiplier: Int32(k))
            if !adaptor.append(pbOut!, withPresentationTime: t) {
                throw ExportError.writer(writer.error?.localizedDescription ?? "append")
            }
            lastKey = of; lastBuffer = pbOut
            pre.evict(keeping: Set(ahead))
            progress(Double(k + 1) / Double(frames.count))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.endSession(atSourceTime: CMTimeMultiply(frameDur, multiplier: Int32(frames.count)))
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed { throw ExportError.writer(writer.error?.localizedDescription ?? "finish") }
    }

    /// Export aligned frames as an image sequence (PNG / JPEG / HEIC) – one per used source frame.
    public func exportImages(job: RenderJob, to dir: URL, type: UTType, progress: @escaping (Double) -> Void,
                             isCancelled: @escaping () -> Bool) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pre = SourcePrefetcher(job: job, proxy: !job.export.useFullResolution)
        let used = job.used
        guard !used.isEmpty else { throw ExportError.noFrames }
        let ext = type == .png ? "png" : (type == .heic ? "heic" : "jpg")
        for (k, i) in used.enumerated() {
            if isCancelled() { throw ExportError.cancelled }
            pre.prefetch(Array(used[k..<min(used.count, k + 6)]))
            let of = OutputFrame(a: i, b: i, t: 0, fade: 1)
            guard let img = job.renderOutput(of, fetch: { pre.get($0) }), let cg = job.renderer.renderCGImage(img) else { continue }
            let name = String(format: "%05d_", k) + (job.analysis.frames[i].url.deletingPathExtension().lastPathComponent) + "." + ext
            let u = dir.appendingPathComponent(name)
            if let d = CGImageDestinationCreateWithURL(u as CFURL, type.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
                CGImageDestinationFinalize(d)
            }
            pre.evict(keeping: Set(used[k..<min(used.count, k + 6)]))
            progress(Double(k + 1) / Double(used.count))
        }
    }

    /// Animated GIF (downscaled), useful for quick sharing.
    public func exportGIF(job: RenderJob, to url: URL, maxSide: Int = 720, progress: @escaping (Double) -> Void,
                          isCancelled: @escaping () -> Bool) throws {
        let frames = job.outputFrames
        guard !frames.isEmpty else { throw ExportError.noFrames }
        let (W, H) = job.outputSize
        let scale = min(1, Double(maxSide) / Double(max(W, H)))
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw ExportError.writer("gif")
        }
        CGImageDestinationSetProperties(dst, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let pre = SourcePrefetcher(job: job, proxy: true)
        let delay = 1 / job.export.outputFPS
        for (k, of) in frames.enumerated() {
            if isCancelled() { throw ExportError.cancelled }
            pre.prefetch(frames[k..<min(frames.count, k + 6)].map { $0.a })
            guard let img = job.renderOutput(of, scale: scale, fetch: { pre.get($0) }), let cg = job.renderer.renderCGImage(img) else { continue }
            CGImageDestinationAddImage(dst, cg, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                                                 kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
            pre.evict(keeping: Set(frames[k..<min(frames.count, k + 6)].map { $0.a }))
            progress(Double(k + 1) / Double(frames.count))
        }
        guard CGImageDestinationFinalize(dst) else { throw ExportError.writer("gif finalize") }
    }
}
