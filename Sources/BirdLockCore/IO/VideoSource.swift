import Foundation
import AVFoundation
import CryptoKit

public struct VideoSourceInfo: Codable, Sendable {
    public var version = 1
    public var sourcePath: String
    public var start: Double
    public var seconds: Double
    public var fps: Double
    public var count: Int
    public var audioFile: String?
}

public struct VideoAudioArrangement: Sendable {
    public var url: URL?
    public var error: String?
    public var hasSource: Bool
}

/// PCM is extracted once. Every finished edit gets one cached continuous track, not many tiny clips.
public enum VideoSource {
    private static let rate = 48000.0
    private static let manifest = "video-source.json"
    private static let audioFile = "original-audio.wav"

    public static func prepare(videoURL: URL, stageDirectory: URL, sourceStart: Double, seconds: Double,
                               sampleFPS: Double, frameCount: Int,
                               isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> VideoSourceInfo {
        if isCancelled() { throw CancellationError() }
        guard sourceStart.isFinite, seconds.isFinite, sampleFPS.isFinite, sourceStart >= 0, seconds > 0, seconds <= 600, sampleFPS > 0 else {
            throw AudioError.arrange("视频原声", "视频原声片段参数无效")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: stageDirectory, withIntermediateDirectories: true)
        let recordURL = stageDirectory.appendingPathComponent(manifest)
        if let data = try? Data(contentsOf: recordURL), let old = try? JSONDecoder().decode(VideoSourceInfo.self, from: data),
           old.sourcePath == videoURL.standardizedFileURL.path, old.start == sourceStart, old.seconds == seconds,
           old.fps == sampleFPS, old.count == frameCount,
           old.audioFile == nil || fm.fileExists(atPath: stageDirectory.appendingPathComponent(audioFile).path) { return old }
        var info = VideoSourceInfo(sourcePath: videoURL.standardizedFileURL.path, start: sourceStart, seconds: seconds, fps: sampleFPS, count: frameCount)
        let asset = AVURLAsset(url: videoURL)
        if let track = try awaitSync({ try await asset.loadTracks(withMediaType: .audio).first }) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:rate, AVNumberOfChannelsKey:2,
                AVLinearPCMBitDepthKey:16, AVLinearPCMIsFloatKey:false, AVLinearPCMIsNonInterleaved:false,
                AVLinearPCMIsBigEndianKey:false,
            ])
            reader.add(output)
            reader.timeRange = CMTimeRange(start: CMTime(seconds:sourceStart,preferredTimescale:48000),duration:CMTime(seconds:seconds,preferredTimescale:48000))
            guard reader.startReading() else { throw reader.error ?? AudioError.noAudio("视频原声") }
            defer { reader.cancelReading() }
            let count = Int((seconds*rate).rounded())
            var body = Data(repeating:0,count:count*4)
            while let sample = output.copyNextSampleBuffer() {
                if isCancelled() { throw CancellationError() }
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let size = CMBlockBufferGetDataLength(block)
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard pts.isFinite else { throw AudioError.arrange("视频原声", "音频时间戳无效") }
                let begin = Int(((pts-sourceStart)*rate).rounded()), skip = max(0,-begin), destination = max(0,begin)
                let samples = min(size/4-skip,count-destination)
                if samples <= 0 { continue }
                var part = Data(count:samples*4)
                let status = part.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:skip*4,dataLength:samples*4,destination:$0.baseAddress!) }
                guard status == kCMBlockBufferNoErr else { throw AudioError.arrange("视频原声", "无法读取音频样本") }
                body.replaceSubrange(destination*4..<(destination+samples)*4,with:part)
            }
            guard reader.status == .completed else { throw reader.error ?? AudioError.noAudio("视频原声") }
            if isCancelled() { throw CancellationError() }
            try (header(frames:count)+body).write(to:stageDirectory.appendingPathComponent(audioFile),options:.atomic)
            info.audioFile = audioFile
        }
        if isCancelled() { throw CancellationError() }
        try JSONEncoder().encode(info).write(to:recordURL,options:.atomic)
        return info
    }

    private struct Reference {
        var directory: URL
        var info: VideoSourceInfo
        var ordinal: Int
    }
    private static func reference(_ frame: SourceFrame) throws -> Reference? {
        let directory = frame.url.deletingLastPathComponent()
        for root in [directory,directory.deletingLastPathComponent()] {
            let url = root.appendingPathComponent(manifest)
            guard FileManager.default.fileExists(atPath:url.path) else { continue }
            let info: VideoSourceInfo
            do { info = try JSONDecoder().decode(VideoSourceInfo.self,from:Data(contentsOf:url)) }
            catch { throw AudioError.arrange("视频原声", "视频原声缓存损坏，请重新导入视频") }
            let digits = frame.url.deletingPathExtension().lastPathComponent.reversed().prefix(while: { $0.isNumber }).reversed()
            let ordinal = Int(String(digits)) ?? frame.id
            guard info.version == 1, info.fps.isFinite, info.fps > 0, ordinal >= 0, ordinal < info.count,
                  info.audioFile == nil || info.audioFile == audioFile else { throw AudioError.arrange("视频原声", "视频原声缓存损坏，请重新导入视频") }
            return Reference(directory:root,info:info,ordinal:ordinal)
        }
        return nil
    }

    /// User-facing export names and locations refer to the original video, including silent clips.
    public static func originalURL(frames: [SourceFrame]) -> URL? {
        guard let first = frames.first, let ref = try? reference(first), !ref.info.sourcePath.isEmpty else { return nil }
        return URL(fileURLWithPath:ref.info.sourcePath)
    }

    public static func originalTrack(frames: [SourceFrame]) throws -> AudioTrack? {
        for frame in frames {
            if let ref = try reference(frame), ref.info.audioFile != nil {
                var track = AudioTrack(); track.url = ref.directory.appendingPathComponent(audioFile)
                track.videoOriginal = true;track.volume = 1;track.loop = false
                return track
            }
        }
        return nil
    }

    private struct Segment: Codable {
        var path: String
        var from: Double
        var to: Double
        var start: Double
        var seconds: Double
    }
    private struct Identity: Encodable {
        var version = 2
        var count: Int
        var sources: [String:[Double]]
        var segments: [Segment]
    }

    public static func arrange(frames: [SourceFrame], outputFrames: [OutputFrame], outputFPS: Double,
                               cacheRoot: URL) -> VideoAudioArrangement {
        var hasSource = frames.contains { frame in
            let root = frame.url.deletingLastPathComponent()
            return [root,root.deletingLastPathComponent()].contains { FileManager.default.fileExists(atPath:$0.appendingPathComponent(manifest).path) }
        }
        do {
            let refs = try frames.map(reference)
            hasSource = refs.contains { $0?.info.audioFile != nil }
            guard hasSource else { return VideoAudioArrangement(url:nil,error:nil,hasSource:false) }
            var segments: [Segment] = [], sources: [String:[Double]] = [:]
            for frame in outputFrames {
                var at = frame.time
                for span in frame.sourceAudio {
                    defer { at += span.seconds }
                    guard refs.indices.contains(span.frame), let ref = refs[span.frame], ref.info.audioFile != nil else { continue }
                    let url = ref.directory.appendingPathComponent(audioFile), path = url.path
                    guard FileManager.default.fileExists(atPath:path) else { throw AudioError.arrange("视频原声", "缓存中的视频原声缺失，请重新导入视频") }
                    if sources[path] == nil {
                        let attrs = try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
                        sources[path] = [Double(attrs.fileSize ?? 0),attrs.contentModificationDate?.timeIntervalSince1970 ?? 0]
                    }
                    let from = (Double(ref.ordinal)+span.from)/ref.info.fps, to = (Double(ref.ordinal)+span.to)/ref.info.fps
                    if let last = segments.last, last.path == path,
                       abs(last.start+last.seconds-at)<1e-7, abs(last.to-from)<1e-7,
                       abs((last.to-last.from)/last.seconds-(to-from)/span.seconds)<1e-7 {
                        segments[segments.count-1].to = to;segments[segments.count-1].seconds += span.seconds
                    } else { segments.append(Segment(path:path,from:from,to:to,start:at,seconds:span.seconds)) }
                }
            }
            let count = Int((Double(outputFrames.count)/outputFPS*rate).rounded())
            guard UInt64(count)*4 <= UInt64(UInt32.max)-36 else { throw AudioError.arrange("视频原声", "视频原声音轨过长，请减少重复次数") }
            let encoder = JSONEncoder();encoder.outputFormatting = .sortedKeys
            let identity = try encoder.encode(Identity(count:count,sources:sources,segments:segments))
            let key = SHA256.hash(data:identity).map { String(format:"%02x",$0) }.joined()
            let root = cacheRoot.appendingPathComponent("video-audio",isDirectory:true)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let final = root.appendingPathComponent(key+".wav")
            if (try? final.resourceValues(forKeys:[.fileSizeKey]).fileSize) == 44+count*4 { return VideoAudioArrangement(url:final,error:nil,hasSource:true) }
            let audio = try sources.mapValues { _ in [Int16]() }
            var decoded = audio
            for path in sources.keys { decoded[path] = try pcm(Data(contentsOf:URL(fileURLWithPath:path))) }
            let temporary = root.appendingPathComponent(".original-"+UUID().uuidString+".wav")
            FileManager.default.createFile(atPath:temporary.path,contents:header(frames:count))
            defer { try? FileManager.default.removeItem(at:temporary) }
            let writer = try FileHandle(forWritingTo:temporary)
            try writer.seekToEnd()
            do {
                var cursor = 0
                func silence(_ length: Int) throws {
                    var remaining = length
                    while remaining > 0 { let n = min(remaining,32768);try writer.write(contentsOf:Data(repeating:0,count:n*4));remaining -= n }
                }
                for segment in segments {
                    let first = max(cursor,Int((segment.start*rate).rounded())), stop = min(count,Int(((segment.start+segment.seconds)*rate).rounded()))
                    if first > cursor { try silence(first-cursor) }
                    guard let source = decoded[segment.path] else { continue }
                    let sourceCount = source.count/2
                    var k = first
                    while k < stop {
                        let end = min(stop,k+32768)
                        var buffer = [Int16](repeating:0,count:(end-k)*2)
                        for index in k..<end {
                            let pos = segment.from*rate+((Double(index)+0.5)/rate-segment.start)/segment.seconds*(segment.to-segment.from)*rate-0.5
                            guard pos >= -0.500001, pos < Double(sourceCount)-0.499999 else { continue }
                            let low = Int(floor(pos)), alpha = pos-Double(low)
                            for channel in 0..<2 {
                                let a = Double(source[clamp(low,0,sourceCount-1)*2+channel]), b = Double(source[clamp(low+1,0,sourceCount-1)*2+channel])
                                buffer[(index-k)*2+channel] = Int16(clamping:Int((a*(1-alpha)+b*alpha).rounded()))
                            }
                        }
                        try buffer.withUnsafeBytes { try writer.write(contentsOf:Data($0)) }
                        k = end
                    }
                    cursor = stop
                }
                if cursor < count { try silence(count-cursor) }
                try writer.close()
            } catch { try? writer.close();throw error }
            do { try FileManager.default.moveItem(at:temporary,to:final) }
            catch { if !FileManager.default.fileExists(atPath:final.path) { throw error } }
            return VideoAudioArrangement(url:final,error:nil,hasSource:true)
        } catch { return VideoAudioArrangement(url:nil,error:error.localizedDescription,hasSource:hasSource) }
    }

    public static func resolve(_ settings: AudioSettings, arrangement: VideoAudioArrangement, duration: Double) -> AudioSettings {
        var result = settings
        result.tracks = result.tracks.compactMap { layer in
            guard layer.videoOriginal else { return layer }
            guard arrangement.hasSource else { return nil }
            var track = layer
            track.url = arrangement.url ?? layer.url;track.assetID = nil;track.startOffset = 0;track.timelineStart = 0
            track.duration = duration;track.loop = false;track.muteRanges = [];track.arrangementError = arrangement.error
            return track
        }
        return result
    }

    private static func header(frames: Int) -> Data {
        var data = Data("RIFF".utf8)
        func u32(_ n: UInt32) { var v = n.littleEndian;withUnsafeBytes(of:&v) { data.append(contentsOf:$0) } }
        func u16(_ n: UInt16) { var v = n.littleEndian;withUnsafeBytes(of:&v) { data.append(contentsOf:$0) } }
        u32(UInt32(frames*4+36));data.append(Data("WAVEfmt ".utf8));u32(16);u16(1);u16(2);u32(48000);u32(192000);u16(4);u16(16)
        data.append(Data("data".utf8));u32(UInt32(frames*4));return data
    }
    private static func pcm(_ data: Data) throws -> [Int16] {
        func u16(_ at: Int) -> UInt16 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:at,as:UInt16.self).littleEndian } }
        func u32(_ at: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:at,as:UInt32.self).littleEndian } }
        guard data.count>=44,String(data:data[0..<4],encoding:.ascii)=="RIFF",String(data:data[8..<12],encoding:.ascii)=="WAVE" else { throw AudioError.noAudio("视频原声缓存") }
        var at=12,valid=false
        while at+8<=data.count {
            let name=String(data:data[at..<at+4],encoding:.ascii),size=Int(u32(at+4)),begin=at+8
            guard begin+size<=data.count else { break }
            if name=="fmt ",size>=16 { valid=u16(begin)==1 && u16(begin+2)==2 && u32(begin+4)==48000 && u16(begin+14)==16 }
            if name=="data",valid,size>0 {
                return stride(from:begin,to:begin+size-size%2,by:2).map { Int16(bitPattern:u16($0)) }
            }
            at=begin+size+(size%2)
        }
        throw AudioError.arrange("视频原声", "视频原声缓存格式无效，请重新导入视频")
    }
}
