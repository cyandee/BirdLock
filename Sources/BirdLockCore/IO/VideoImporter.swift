import Foundation
import AVFoundation
import CoreImage
import CryptoKit

public struct VideoInfo: Sendable {
    public let width: Int
    public let height: Int
    public let fps: Double
    public let duration: Double
}

public struct VideoImportOptions: Sendable {
    public var start = 0.0
    public var seconds = 10.0
    public var fps = 30.0
    public var profile: URL? = nil
    public init() {}
}

public enum VideoImporter {
    public static let extensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv"]

    public static func probe(_ url: URL) throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        return try awaitSync {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoImportError.invalid("视频里没有可用的画面轨道") }
            let duration = try await asset.load(.duration).seconds
            let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
            let display = CGRect(origin: .zero, size: size).applying(transform)
            let fps = Double(try await track.load(.nominalFrameRate))
            let formats = try await track.load(.formatDescriptions)
            for format in formats {
                let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                if transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String || transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String {
                    throw VideoImportError.invalid("实验视频导入暂只支持 SDR；请先将 HDR 转为 SDR")
                }
            }
            guard duration.isFinite, duration > 0, fps.isFinite, fps > 0, fps <= 1000,
                  display.width > 0, display.height > 0, display.width * display.height <= 67_108_864 else { throw VideoImportError.invalid("视频参数超出实验导入支持范围") }
            return VideoInfo(width: Int(display.width.rounded()), height: Int(display.height.rounded()), fps: fps, duration: duration)
        }
    }

    /// The import form and decoder share exactly the same clip limits and sample clock.
    public static func selection(info: VideoInfo, options: VideoImportOptions) throws -> (seconds: Double, fps: Double, count: Int) {
        guard options.start.isFinite, options.seconds.isFinite, options.fps.isFinite,
              options.start >= 0, options.start < info.duration, options.seconds > 0, (1...60).contains(options.fps)
        else { throw VideoImportError.invalid("视频片段或采样帧率无效（1–60 fps）") }
        let seconds = min(options.seconds, info.duration - options.start), fps = min(options.fps, info.fps)
        guard seconds <= 120 else { throw VideoImportError.invalid("实验导入每次最多 120 秒 / 3600 帧；请缩短片段或降低采样帧率") }
        let count = max(1, Int(ceil(seconds * fps - 1e-7)))
        guard seconds <= 120, count <= 3600 else { throw VideoImportError.invalid("实验导入每次最多 120 秒 / 3600 帧；请缩短片段或降低采样帧率") }
        return (seconds,fps,count)
    }

    private static func writeRecipe(directory:URL,source:URL,info:VideoInfo,options:VideoImportOptions,seconds:Double,fps:Double,count:Int,profile:LensProfile?) throws {
        let values=try source.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        let recipe=VideoRecipe(sourcePath:source.standardizedFileURL.path,bytes:values.fileSize ?? 0,modified:values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            width:info.width,height:info.height,start:options.start,seconds:seconds,fps:fps,count:count,lensJSON:profile.flatMap { String(data:$0.raw,encoding:.utf8) })
        try JSONEncoder().encode(recipe).write(to:directory.appendingPathComponent("video-recipe.json"),options:.atomic)
    }

    public static func extract(_ url: URL, options: VideoImportOptions, root: URL? = nil,
                               progress: @escaping @Sendable (Double) -> Void = { _ in },
                               isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> (frames: [SourceFrame], fps: Double) {
        if isCancelled() { throw CancellationError() }
        let info = try probe(url)
        let clip = try selection(info:info,options:options)
        let seconds = clip.seconds, fps = clip.fps, count = clip.count
        let profile = try options.profile.map(LensProfile.load)
        try profile?.validate(width: info.width, height: info.height)
        let fm = FileManager.default
        let source = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let identity = "v2|\(url.standardizedFileURL.path)|\(source.fileSize ?? 0)|\(source.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(options.start)|\(seconds)|\(fps)|" + (profile.map { SHA256.hash(data: $0.raw).map { String(format:"%02x",$0) }.joined() } ?? "")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format:"%02x",$0) }.joined()
        let base = root ?? ProxyCache.shared.root.appendingPathComponent("video-imports", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let final = base.appendingPathComponent(String(digest.prefix(32)), isDirectory: true)
        if let data = try? Data(contentsOf: final.appendingPathComponent("import.json")),
           let frames = try? JSONDecoder().decode([SourceFrame].self, from: data), frames.count == count,
           frames.allSatisfy({ fm.fileExists(atPath: $0.url.path) && ((try? $0.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }) {
            _ = try VideoSource.prepare(videoURL: url, stageDirectory: final, sourceStart: options.start,
                                        seconds: seconds, sampleFPS: fps, frameCount: count, isCancelled: isCancelled)
            try writeRecipe(directory:final,source:url,info:info,options:options,seconds:seconds,fps:fps,count:count,profile:profile)
            progress(1); return (frames, fps)
        }
        let evicted=fm.fileExists(atPath:final.appendingPathComponent(".evicted.json").path) && (try? final.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true
        guard !fm.fileExists(atPath: final.path) || evicted else { throw VideoImportError.invalid("视频缓存不完整，请清空缓存后重新导入") }
        let stage = base.appendingPathComponent(".extract-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let asset = AVURLAsset(url: url)
        let track = try awaitSync { try await asset.loadTracks(withMediaType: .video).first! }
        let transform = try awaitSync { try await track.load(.preferredTransform) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: options.start, preferredTimescale: 600000), duration: CMTime(seconds: seconds, preferredTimescale: 600000))
        guard reader.startReading() else { throw reader.error ?? VideoImportError.invalid("无法开始视频解码") }
        defer { reader.cancelReading() }
        let context = CIContext(options: [.cacheIntermediates: false]), color = CGColorSpace(name: CGColorSpace.sRGB)!
        var frames: [SourceFrame] = []
        func save(_ image: CIImage) throws {
            if isCancelled() { throw CancellationError() }
            let i = frames.count
            if i % 16 == 0, let free = try? base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               free < max(268_435_456, Int64(info.width * info.height * 6)) { throw VideoImportError.invalid("视频帧缓存磁盘空间不足；请缩短片段或清理缓存") }
            let image = try profile?.correct(image) ?? image
            guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: color) else { throw VideoImportError.invalid("视频帧转换失败") }
            let name = String(format:"video-%06d.jpg",i), file = stage.appendingPathComponent(name)
            guard ImageLoader.writeJPEG(cg, to: file, quality: 0.97) else { throw VideoImportError.invalid("无法写入视频帧缓存") }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            frames.append(SourceFrame(id:i,url:final.appendingPathComponent(name),pixelWidth:info.width,pixelHeight:info.height,
                captureTime:Double(i)/fps,fileSize:size,modified:source.contentModificationDate?.timeIntervalSince1970 ?? 0,exif:ExifInfo()))
            progress(Double(i+1)/Double(count))
        }
        var previous: CIImage?, lastEnd = options.start
        while let sample = output.copyNextSampleBuffer() {
            if isCancelled() { throw CancellationError() }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw VideoImportError.invalid("视频帧没有可用像素") }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite else { throw VideoImportError.invalid("视频时间戳无效") }
            let sampleDuration = CMSampleBufferGetDuration(sample).seconds
            lastEnd = pts + (sampleDuration.isFinite && sampleDuration > 0 ? sampleDuration : 1 / info.fps)
            // Uniform sample clock; use the latest source frame at or before each requested instant.
            while frames.count < count, options.start + Double(frames.count)/fps < pts - 1e-7, let last = previous { try autoreleasepool { try save(last) } }
            let transformed = CIImage(cvPixelBuffer:buffer).transformed(by: transform)
            previous = transformed.transformed(by: CGAffineTransform(translationX:-transformed.extent.minX,y:-transformed.extent.minY))
        }
        guard reader.status == .completed, let last = previous else { throw reader.error ?? VideoImportError.invalid("视频解码失败，未导入不完整片段") }
        while frames.count < count {
            guard options.start + Double(frames.count)/fps < lastEnd + 1e-7 else { throw VideoImportError.invalid("视频画面提前结束，未导入不完整片段") }
            try autoreleasepool { try save(last) }
        }
        if isCancelled() { throw CancellationError() }
        _ = try VideoSource.prepare(videoURL: url, stageDirectory: stage, sourceStart: options.start,
                                    seconds: seconds, sampleFPS: fps, frameCount: count, isCancelled: isCancelled)
        try JSONEncoder().encode(frames).write(to: stage.appendingPathComponent("import.json"), options: .atomic)
        try writeRecipe(directory:stage,source:url,info:info,options:options,seconds:seconds,fps:fps,count:count,profile:profile)
        if evicted {
            let motion=final.appendingPathComponent("motion.json")
            if fm.fileExists(atPath:motion.path) { try fm.copyItem(at:motion,to:stage.appendingPathComponent("motion.json")) }
            let backup=base.appendingPathComponent(".replaced-"+UUID().uuidString)
            try fm.moveItem(at:final,to:backup)
            do { try fm.moveItem(at:stage,to:final) }
            catch { try? fm.moveItem(at:backup,to:final);throw error }
            try? fm.removeItem(at:backup)
        } else { try fm.moveItem(at: stage, to: final) }
        return (frames, fps)
    }
}
