import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Darwin
import ImageIO
import UniformTypeIdentifiers

public enum ExportError: Error, LocalizedError {
    case rawPreviewLimit
    case noFrames, writer(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .rawPreviewLimit: return "所选画面包含较小的 RAW 机内预览。请关闭完整分辨率渲染，或重新导入并选择高分辨率 RAW。"
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
    private let scale: Double
    private var cache: [Int: (CIImage, Double)] = [:]
    private var inflight: [Int: DispatchGroup] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "birdlock.prefetch", attributes: .concurrent)
    private let limit: Int

    /// - Parameter scale: decode originals at this fraction of full size (ignored for proxies)
    init(job: RenderJob, proxy: Bool, scale: Double = 1, limit: Int = 12) {
        self.job = job; self.proxy = proxy; self.scale = scale; self.limit = limit
    }

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
            let s = job.source(i, proxy: proxy, scale: scale)
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

final class OrderedPixelBuffers: @unchecked Sendable {
    private let queue = OperationQueue()
    private let condition = NSCondition()
    private var ready: [Int:Result<CVPixelBuffer,Error>] = [:]
    init(workers: Int) { queue.maxConcurrentOperationCount = workers; queue.qualityOfService = .userInitiated }
    func submit(_ index: Int, render: @escaping () throws -> CVPixelBuffer) {
        queue.addOperation { [self] in
            let result = Result { try autoreleasepool { try render() } }
            condition.lock(); ready[index] = result; condition.broadcast(); condition.unlock()
        }
    }
    func get(_ index: Int, cancelled: () -> Bool) throws -> CVPixelBuffer {
        condition.lock(); defer { condition.unlock() }
        while ready[index] == nil {
            if cancelled() { throw ExportError.cancelled }
            _ = condition.wait(until:Date().addingTimeInterval(0.05))
        }
        return try ready.removeValue(forKey:index)!.get()
    }
    func finish() { queue.cancelAllOperations(); queue.waitUntilAllOperationsAreFinished() }
}

public final class VideoExporter {
    public private(set) var warning: String?
    private let requestedWorkers: Int?
    public init(workers: Int? = nil) { requestedWorkers = workers }

    /// Encodes the video; with `audio` the music is muxed in afterwards (the video stream is copied, not re-encoded).
    public func export(job: RenderJob, to url: URL, audio: AudioSettings? = nil, progress: @escaping (Double) -> Void,
                       isCancelled: @escaping () -> Bool) throws {
        warning = nil
        try checkRawQuality(job)
        let audio = job.mixedAudio(audio)
        try withExportDirectory(in: url.deletingLastPathComponent()) { directory in
            let output = directory.appendingPathComponent(url.lastPathComponent)
            if audio.isActive {
                let video = directory.appendingPathComponent("video-\(UUID().uuidString).\(job.export.codec.fileExtension)")
                try exportVideo(job: job, to: video, progress: { progress($0 * 0.96) }, isCancelled: isCancelled)
                try AudioMixer.mux(videoURL: video, audio: audio, duration: job.duration, to: output,
                                   fileType: job.export.codec.fileType, progress: { progress(0.96 + $0 * 0.03) },
                                   isCancelled: isCancelled)
            } else {
                try exportVideo(job: job, to: output, progress: { progress($0 * 0.99) }, isCancelled: isCancelled)
            }
            if isCancelled() { throw ExportError.cancelled }
            try publishExport(output, to: url)
        }
        progress(1)
    }

    private func withExportDirectory(in parent: URL, _ export: (URL) throws -> Void) throws {
        let directory = parent.appendingPathComponent(".BirdLock-export-\(UUID().uuidString)", isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: directory) }
        try export(directory)
    }

    private func publishExport(_ staged: URL, to destination: URL) throws {
        try staged.withUnsafeFileSystemRepresentation { sourcePath in
            try destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { throw ExportError.writer("无法访问导出路径") }
                guard rename(sourcePath, destinationPath) == 0 else {
                    let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    throw ExportError.writer("无法保存 \(destination.lastPathComponent)：\(failure.localizedDescription)")
                }
            }
        }
    }

    func exportVideo(job: RenderJob, to url: URL, progress: @escaping (Double) -> Void,
                     isCancelled: @escaping () -> Bool) throws {
        let frames = job.outputFrames
        guard !frames.isEmpty else { throw ExportError.noFrames }
        let (W, H) = job.outputSize
        let s = job.export
        Diagnostics.record("video export size=\(W)x\(H) frames=\(frames.count) fps=\(s.outputFPS) codec=\(s.codec.rawValue) interpolation=\(s.interpolation.rawValue) full_resolution=\(s.useFullResolution)")
        let writer = try AVAssetWriter(outputURL: url, fileType: s.codec.fileType)
        defer { if writer.status == .writing { writer.cancelWriting() } }
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

        let pixels = job.analysis.frames.map { $0.pixelWidth * $0.pixelHeight }.max() ?? W*H
        let taskBytes = Int(Double(pixels)*pow(job.exportDecodeScale,2)*8)+W*H*12
        let workers = s.interpolation == .ai ? 1 : ResourceBudget.workers(bytesPerTask:max(1,taskBytes*2),maximum:requestedWorkers ?? 4)
        let lookahead = s.interpolation == .ai ? 1 : max(2,workers*2)
        Diagnostics.record("export resource workers=\(workers) lookahead=\(lookahead) estimated_task_bytes=\(taskBytes)")
        let pre = SourcePrefetcher(job: job, proxy: !s.useFullResolution, scale: job.exportDecodeScale, limit:lookahead*2)
        let timescale: CMTimeScale = 60000
        let frameDur = CMTime(value: CMTimeValue((Double(timescale) / s.outputFPS).rounded()), timescale: timescale)
        let cs709 = CGColorSpace(name: CGColorSpace.itur_709)!
        var lastKey: OutputFrame? = nil
        var lastBuffer: CVPixelBuffer? = nil
        var interp: ((CIImage, CIImage, Double) -> CIImage?)? = nil
        var aiBox: IsolatedInterpolator?
        var flowBudget = OpticalFlowWorkBudget(width: W, height: H)
        if s.interpolation == .ai && frames.contains(where: { $0.t > 0.001 && $0.a != $0.b }) {
            aiBox = IsolatedInterpolator(width: W, height: H, context: job.renderer.context, cancelled: isCancelled)
            if aiBox != nil {
                Diagnostics.record("optical flow worker request_limit=\(flowBudget.requestLimit)")
                interp = { a,b,t in
                    guard self.warning == nil, !isCancelled() else { return nil }
                    if flowBudget.beginRequest() {
                        aiBox?.stop(); aiBox = nil
                        job.renderer.context.clearCaches()
                        Diagnostics.record("optical flow recycling worker after processed-pixel budget")
                        aiBox = IsolatedInterpolator(width: W, height: H, context: job.renderer.context, cancelled: isCancelled)
                    }
                    guard let ai = aiBox else {
                        self.warning = "光流补帧不可用，已使用帧混合；详见诊断日志"
                        return nil
                    }
                    let result = ai.interpolate(a,b,phase: t)
                    if ai.failed { self.warning = "光流补帧异常，已使用帧混合；详见诊断日志" }
                    return result
                }
            }
            else { warning = "光流补帧不可用，已使用帧混合；详见诊断日志" }
        }
        defer { aiBox?.stop() }

        let pipeline = OrderedPixelBuffers(workers:workers)
        defer { pipeline.finish() }
        var scheduled = 0
        func schedule(until end: Int) {
            while scheduled < min(frames.count,end) {
                let index = scheduled; scheduled += 1
                let key = frames[index].renderKey(focus:s.focusMark,closeups:job.analysis.closeups ?? [])
                if index > 0 && key == frames[index-1].renderKey(focus:s.focusMark,closeups:job.analysis.closeups ?? []) { continue }
                pipeline.submit(index) {
                if isCancelled() { throw ExportError.cancelled }
                guard let pool = adaptor.pixelBufferPool else { throw ExportError.writer("no pixel buffer pool") }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                guard let pb else { throw ExportError.writer("pixel buffer") }
                guard let img = job.renderOutput(frames[index], fetch: { pre.get($0) }, interpolate: interp) else {
                    throw ExportError.writer("无法读取第 \(frames[index].a+1) 张照片")
                }
                job.renderer.context.render(img, to: pb, bounds: CGRect(x: 0, y: 0, width: W, height: H), colorSpace: cs709)
                CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                return pb
                }
            }
        }

        for (k, of) in frames.enumerated() {
            let cacheKey = of.renderKey(focus: s.focusMark, closeups: job.analysis.closeups ?? [])
            if isCancelled() { writer.cancelWriting(); throw ExportError.cancelled }
            // Prefetch upcoming sources
            var ahead: [Int] = []
            for j in k..<min(frames.count, k + lookahead) { ahead.append(frames[j].a); if frames[j].t > 0 { ahead.append(frames[j].b) } }
            pre.prefetch(ahead)
            schedule(until:k+lookahead)

            let waitStarted = Date()
            while !input.isReadyForMoreMediaData {
                if isCancelled() { writer.cancelWriting(); throw ExportError.cancelled }
                if writer.status == .failed || writer.status == .cancelled || Date().timeIntervalSince(waitStarted) > 60 {
                    throw ExportError.writer(writer.error?.localizedDescription ?? "编码器长时间未响应")
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            var pbOut: CVPixelBuffer? = nil
            if let lk = lastKey, lk == cacheKey, let lb = lastBuffer {
                pbOut = lb   // identical frame (slow-motion hold) – reuse
            } else {
                pbOut = try pipeline.get(k,cancelled:isCancelled)
            }
            if aiBox?.failed == true { warning = "光流补帧异常，已使用帧混合；详见诊断日志" }
            let t = CMTimeMultiply(frameDur, multiplier: Int32(k))
            if !adaptor.append(pbOut!, withPresentationTime: t) {
                throw ExportError.writer(writer.error?.localizedDescription ?? "append")
            }
            lastKey = cacheKey; lastBuffer = pbOut
            pre.evict(keeping: Set(ahead))
            progress(Double(k + 1) / Double(frames.count))
            if k == 0 || k % max(1,frames.count/20) == 0 { Diagnostics.record("video rendered \(k+1)/\(frames.count)") }
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.endSession(atSourceTime: CMTimeMultiply(frameDur, multiplier: Int32(frames.count)))
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed { throw ExportError.writer(writer.error?.localizedDescription ?? "finish") }
        Diagnostics.record("video export complete warning=\(warning ?? "none")")
    }

    /// Export aligned frames as an image sequence (PNG / JPEG / HEIC) – one per used source frame.
    public func exportImages(job: RenderJob, to dir: URL, type: UTType, progress: @escaping (Double) -> Void,
                             isCancelled: @escaping () -> Bool) throws {
        try checkRawQuality(job)
        let used = job.used
        guard !used.isEmpty else { throw ExportError.noFrames }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pre = SourcePrefetcher(job: job, proxy: !job.export.useFullResolution, scale: job.exportDecodeScale)
        let ext = type == .png ? "png" : (type == .heic ? "heic" : "jpg")
        try withExportDirectory(in: dir) { directory in
            var staged: [URL] = []
            for (k, i) in used.enumerated() {
                if isCancelled() { throw ExportError.cancelled }
                let ahead = used[k..<min(used.count, k + 6)]
                pre.prefetch(Array(ahead))
                let of = OutputFrame(a: i, b: i, t: 0, fade: 1)
                guard let img = job.renderOutput(of, fetch: { pre.get($0) }),
                      let cg = job.renderer.renderCGImage(img) else {
                    throw ExportError.writer("无法渲染第 \(k + 1) 个输出画面，请确认原始素材可读")
                }
                let stem = job.analysis.frames[i].url.deletingPathExtension().lastPathComponent
                let name = String(format: "%05d_", k) + stem + "." + ext
                let output = directory.appendingPathComponent(name)
                guard let dst = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
                    throw ExportError.writer("无法创建图片：\(name)")
                }
                CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
                guard CGImageDestinationFinalize(dst) else { throw ExportError.writer("无法写入图片：\(name)") }
                staged.append(output)
                pre.evict(keeping: Set(ahead))
                progress(0.99 * Double(k + 1) / Double(used.count))
            }
            if isCancelled() { throw ExportError.cancelled }
            for file in staged {
                try publishExport(file, to: dir.appendingPathComponent(file.lastPathComponent))
            }
        }
        progress(1)
    }

    private func checkRawQuality(_ job: RenderJob) throws {
        if job.export.useFullResolution && job.used.contains(where: { job.analysis.frames[$0].hasRawPreviewLimit }) {
            throw ExportError.rawPreviewLimit
        }
    }

    /// Animated GIF (downscaled), useful for quick sharing.
    public func exportGIF(job: RenderJob, to url: URL, maxSide: Int = 720, progress: @escaping (Double) -> Void,
                          isCancelled: @escaping () -> Bool) throws {
        try withExportDirectory(in: url.deletingLastPathComponent()) { directory in
            let output = directory.appendingPathComponent(url.lastPathComponent)
            try writeGIF(job: job, to: output, maxSide: maxSide, progress: { progress($0 * 0.99) }, isCancelled: isCancelled)
            if isCancelled() { throw ExportError.cancelled }
            try publishExport(output, to: url)
        }
        progress(1)
    }

    private func writeGIF(job: RenderJob, to url: URL, maxSide: Int, progress: @escaping (Double) -> Void,
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
            guard let img = job.renderOutput(of, scale: scale, fetch: { pre.get($0) }),
                  let cg = job.renderer.renderCGImage(img) else {
                throw ExportError.writer("无法渲染第 \(k + 1) 个输出画面，请确认原始素材可读")
            }
            CGImageDestinationAddImage(dst, cg, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                                                 kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
            pre.evict(keeping: Set(frames[k..<min(frames.count, k + 6)].map { $0.a }))
            progress(Double(k + 1) / Double(frames.count))
        }
        guard CGImageDestinationFinalize(dst) else { throw ExportError.writer("gif finalize") }
    }
}
