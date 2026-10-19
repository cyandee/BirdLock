import Foundation
import AVFoundation
import CoreMedia

public enum AudioError: Error, LocalizedError {
    case noAudio(String)
    case arrange(String, String)
    public var errorDescription: String? {
        switch self {
        case .noAudio(let name): return "「\(name)」里没有可用的音轨"
        case .arrange(let name, let detail): return "无法编排音频「\(name)」：\(detail)"
        }
    }
}

private final class ResultBox<T>: @unchecked Sendable { var value: Result<T, Error>? }

/// Runs an async AVFoundation load from synchronous (background-thread) code.
func awaitSync<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try box.value!.get()
}

/// Background music: waveform overview, the arranged mix (offset, loop, volume, fades) and muxing into a video.
public enum AudioMixer {
    public static let fileExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "mp4", "mov", "m4v"]

    public struct Overview: Sendable {
        public var duration: Double
        /// Peak level (0…1) per bin
        public var peaks: [Float]
        public var binsPerSecond: Double
    }

    /// Decodes the whole file at a low sample rate and returns peak levels for drawing a waveform.
    public static func overview(url: URL, binsPerSecond: Double = 40) throws -> Overview {
        let asset = AVURLAsset(url: url)
        let tracks = try awaitSync { try await asset.loadTracks(withMediaType: .audio) }
        guard let track = tracks.first else { throw AudioError.noAudio(url.lastPathComponent) }
        let duration = try awaitSync { try await asset.load(.duration) }.seconds
        let reader = try AVAssetReader(asset: asset)
        let rate = 8000.0
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? AudioError.noAudio(url.lastPathComponent) }
        let bin = max(1, Int(rate / binsPerSecond))
        var peaks: [Float] = []
        peaks.reserveCapacity(Int(duration * binsPerSecond) + 1)
        var cur: Float = 0, cnt = 0
        var data = [Float]()
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb)
            let count = len / MemoryLayout<Float>.size
            if data.count < count { data = [Float](repeating: 0, count: count) }
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!) }
            for k in 0..<count {
                cur = max(cur, abs(data[k])); cnt += 1
                if cnt == bin { peaks.append(min(1, cur)); cur = 0; cnt = 0 }
            }
        }
        if cnt > 0 { peaks.append(min(1, cur)) }
        return Overview(duration: duration.isFinite ? duration : Double(peaks.count) / binsPerSecond, peaks: peaks, binsPerSecond: binsPerSecond)
    }

    /// The music laid out on a 0-based timeline of `duration` seconds (starting at `startOffset` in the file,
    /// repeated if `loop`), with volume and fades as an audio mix.
    public static func makeMix(_ s: AudioSettings, duration: Double) async throws -> (AVMutableComposition, AVMutableAudioMix) {
        let comp = AVMutableComposition()
        let ts: CMTimeScale = 48000
        func t(_ v: Double) -> CMTime { CMTime(value: Int64((v * Double(ts)).rounded()), timescale: ts) }
        let layers = s.arrangedTracks.filter { $0.timelineStart < duration }
        let gain = CloseupAudio.gain(tracks: layers, duration: duration)
        var parameters: [AVAudioMixInputParameters] = []
        for layer in layers {
            try Task.checkCancellation()
            guard let url = layer.sourceURL else { throw AudioError.noAudio(layer.title) }
            let asset = AVURLAsset(url: url)
            guard let src = try await asset.loadTracks(withMediaType: .audio).first else { throw AudioError.noAudio(layer.title) }
            let musicDur = try await asset.load(.duration).seconds
            guard musicDur.isFinite, musicDur > 0.001,
                  let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw AudioError.noAudio(layer.title)
            }
            let start = max(0, layer.timelineStart)
            let limit = layer.duration > 0 ? min(duration, start + layer.duration) : duration
            var at = start
            var from = clamp(layer.startOffset, 0, max(0, musicDur - 0.001))
            while at < limit - 0.00001 {
                try Task.checkCancellation()
                let len = min(musicDur - from, limit - at)
                guard len > 0.00001 else { break }
                do {
                    try track.insertTimeRange(CMTimeRange(start: t(from), duration: t(len)), of: src, at: t(at))
                } catch {
                    throw AudioError.arrange(layer.title, String(describing: error))
                }
                at += len
                guard layer.loop else { break }
                from = 0
            }
            let span = at - start
            let vol = Float(clamp(layer.volume, 0, 2) * gain)
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(vol, at: t(start))
            let fi = min(max(0, layer.fadeIn), span / 2), fo = min(max(0, layer.fadeOut), span - fi)
            if fi > 0.01 { p.setVolumeRamp(fromStartVolume: 0, toEndVolume: vol, timeRange: CMTimeRange(start: t(start), duration: t(fi))) }
            if fo > 0.01 { p.setVolumeRamp(fromStartVolume: vol, toEndVolume: 0, timeRange: CMTimeRange(start: t(at - fo), duration: t(fo))) }
            parameters.append(p)
        }
        // AVFoundation discards trailing empty ranges; a zero-valued PCM bed retains the video clock.
        if comp.duration.seconds < duration {
            guard let root = SoundLibrary.directory else { throw AudioError.noAudio("静音资源") }
            let silence = AVURLAsset(url: root.appendingPathComponent("silence.wav"))
            guard let src = try await silence.loadTracks(withMediaType: .audio).first,
                  let pad = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw AudioError.noAudio("静音资源")
            }
            var at = max(0, comp.duration.seconds)
            while at < duration - 0.00001 {
                try Task.checkCancellation()
                let len = min(1, duration - at)
                try pad.insertTimeRange(CMTimeRange(start: .zero, duration: t(len)), of: src, at: t(at))
                at += len
            }
            let p = AVMutableAudioMixInputParameters(track: pad)
            p.setVolume(0, at: .zero)
            parameters.append(p)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return (comp, mix)
    }

    /// Copies the (already encoded) video of `videoURL` and adds the music as an AAC track.
    public static func mux(videoURL: URL, audio s: AudioSettings, duration: Double, to outURL: URL, fileType: AVFileType,
                           progress: ((Double) -> Void)? = nil, isCancelled: @escaping () -> Bool = { false }) throws {
        let (comp, mix) = try awaitSync { try await makeMix(s, duration: duration) }
        let video = AVURLAsset(url: videoURL)
        guard let vTrack = try awaitSync({ try await video.loadTracks(withMediaType: .video) }).first else {
            throw ExportError.writer("no video track")
        }
        let vFormat = try awaitSync { try await vTrack.load(.formatDescriptions) }.first

        let vReader = try AVAssetReader(asset: video)
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        vOut.alwaysCopiesSampleData = false
        vReader.add(vOut)

        let aReader = try AVAssetReader(asset: comp)
        let aOut = AVAssetReaderAudioMixOutput(audioTracks: comp.tracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        aOut.audioMix = mix
        aReader.add(aOut)
        aReader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 48000))

        try? FileManager.default.removeItem(at: outURL)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: fileType)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vFormat)
        vIn.expectsMediaDataInRealTime = false
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
        ])
        aIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn), writer.canAdd(aIn) else { throw ExportError.writer("cannot add tracks") }
        writer.add(vIn); writer.add(aIn)
        guard vReader.startReading(), aReader.startReading() else {
            throw ExportError.writer((vReader.error ?? aReader.error)?.localizedDescription ?? "reader")
        }
        guard writer.startWriting() else { throw ExportError.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        let lock = NSLock()
        var failed = false
        func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, label: String, onSample: ((CMSampleBuffer) -> Void)?) {
            group.enter()
            var finished = false
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "birdlock.mux.\(label)")) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    lock.lock(); let stop = failed || isCancelled(); lock.unlock()
                    guard !stop, let sb = output.copyNextSampleBuffer() else {
                        finished = true; input.markAsFinished(); group.leave(); return
                    }
                    onSample?(sb)
                    if !input.append(sb) {
                        lock.lock(); failed = true; lock.unlock()
                        finished = true; input.markAsFinished(); group.leave(); return
                    }
                }
            }
        }
        pump(vIn, vOut, label: "video") { sb in
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            if duration > 0, t.isFinite { progress?(min(1, t / duration)) }
        }
        pump(aIn, aOut, label: "audio", onSample: nil)
        group.wait()
        if isCancelled() {
            writer.cancelWriting(); vReader.cancelReading(); aReader.cancelReading()
            throw ExportError.cancelled
        }
        if failed { writer.cancelWriting(); throw ExportError.writer(writer.error?.localizedDescription ?? "mux") }
        if vReader.status == .failed || aReader.status == .failed {
            writer.cancelWriting()
            throw ExportError.writer((vReader.error ?? aReader.error)?.localizedDescription ?? "音视频读取失败")
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 48000))
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed { throw ExportError.writer(writer.error?.localizedDescription ?? "finish") }
    }
}
