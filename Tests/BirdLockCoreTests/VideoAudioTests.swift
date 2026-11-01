import XCTest
import AVFoundation
@testable import BirdLockCore

final class VideoAudioTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return root
    }
    private func source(_ root: URL) throws -> (URL,[Int16]) {
        let url = root.appendingPathComponent("原声音轨.wav")
        let format = AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:48000,channels:2,interleaved:true)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!
        buffer.frameLength = 48000
        var samples = [Int16](repeating:0,count:96000)
        for i in 0..<48000 { samples[i*2] = Int16(Double(i)*0.4-12000); samples[i*2+1] = Int16(Double(i)*0.2+1000) }
        for i in samples.indices { buffer.int16ChannelData![0][i] = samples[i] }
        try autoreleasepool {
            let writer = try AVAudioFile(forWriting:url,settings:format.settings,commonFormat:.pcmFormatInt16,interleaved:true)
            try writer.write(from:buffer)
        }
        return (url,samples)
    }
    private func read(_ url: URL) throws -> [Int16] {
        let data = try Data(contentsOf:url)
        XCTAssertEqual(String(data:data.prefix(4),encoding:.ascii),"RIFF")
        XCTAssertEqual(String(data:data[36..<40],encoding:.ascii),"data")
        return data.subdata(in:44..<data.count).withUnsafeBytes { Array($0.bindMemory(to:Int16.self)) }
    }
    private func frames(_ root: URL, count: Int = 10) -> [SourceFrame] {
        (0..<count).map { SourceFrame(id:$0,url:root.appendingPathComponent(String(format:"video-%06d.jpg",$0)),pixelWidth:64,pixelHeight:48,captureTime:Double($0)/10,fileSize:0,modified:0,exif:ExifInfo()) }
    }
    private func assertSamples(_ actual: [Int16], _ expected: [Int16], tolerance: Int = 0, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count,expected.count,file:file,line:line)
        let wrong = zip(actual,expected).enumerated().first { abs(Int($0.element.0)-Int($0.element.1)) > tolerance }
        XCTAssertNil(wrong?.offset,"PCM mismatch: \(String(describing:wrong))",file:file,line:line)
    }
    func testAudioExtractionUsesExactClipClockAndVisibleMarker() throws {
        let root = try temporary(), (url,samples) = try source(root), cache = root.appendingPathComponent("clip")
        let info = try VideoSource.prepare(videoURL:url,stageDirectory:cache,sourceStart:0.2,seconds:0.6,sampleFPS:10,frameCount:6)
        XCTAssertEqual(info.sourcePath,url.path);XCTAssertEqual(info.audioFile,"original-audio.wav")
        assertSamples(try read(cache.appendingPathComponent("original-audio.wav")),Array(samples[19200..<76800]))
        let marker = try XCTUnwrap(VideoSource.originalTrack(frames:frames(cache,count:6)))
        XCTAssertTrue(marker.videoOriginal);XCTAssertEqual(marker.volume,1);XCTAssertFalse(marker.loop)
        XCTAssertThrowsError(try VideoSource.prepare(videoURL:url,stageDirectory:root.appendingPathComponent("cancel"),sourceStart:0,seconds:1,sampleFPS:10,frameCount:10,isCancelled:{true}))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("cancel").path))
    }
    func testOriginalSoundIsContinuousAtFractionalSamplingAndHalfSpeed() async throws {
        let root = try temporary(), (url,samples) = try source(root), cache = root.appendingPathComponent("clip")
        _ = try VideoSource.prepare(videoURL:url,stageDirectory:cache,sourceStart:0,seconds:1,sampleFPS:10,frameCount:10)
        let sourceFrames = frames(cache)
        var settings = ExportSettings();settings.outputFPS = 20
        let timeline = TimeMapper.outputFrames(used:Array(0..<10),sourceFPS:10,settings:settings)
        let audio = VideoSource.arrange(frames:sourceFrames,outputFrames:timeline,outputFPS:20,cacheRoot:root)
        XCTAssertNil(audio.error);XCTAssertTrue(audio.hasSource)
        let result = try read(XCTUnwrap(audio.url))
        XCTAssertEqual(result.count,91200)
        assertSamples(result,Array(samples.prefix(result.count)))
        XCTAssertEqual(audio.url,VideoSource.arrange(frames:sourceFrames,outputFrames:timeline,outputFPS:20,cacheRoot:root).url)
        var marker = try XCTUnwrap(VideoSource.originalTrack(frames:sourceFrames));marker.muted = true;marker.volume = 0.25
        var user = AudioSettings();user.tracks = [marker]
        let resolved = VideoSource.resolve(user,arrangement:audio,duration:Double(timeline.count)/20)
        XCTAssertTrue(resolved.tracks[0].muted);XCTAssertEqual(resolved.tracks[0].volume,0.25)
        XCTAssertEqual(user.tracks[0].url,marker.url);XCTAssertNotEqual(resolved.tracks[0].url,marker.url)
        var audible = resolved;audible.tracks[0].muted = false;audible.tracks[0].volume = 1
        let (composition,mix) = try await AudioMixer.makeMix(audible,duration:Double(timeline.count)/20)
        let reader = try AVAssetReader(asset:composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks:composition.tracks(withMediaType:.audio),audioSettings:[
            AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,
            AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsNonInterleaved:false,AVLinearPCMIsBigEndianKey:false])
        output.audioMix = mix;reader.add(output);XCTAssertTrue(reader.startReading())
        var decoded: [Int16] = []
        while let sample = output.copyNextSampleBuffer() {
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample)),size = CMBlockBufferGetDataLength(block)
            var part = [Int16](repeating:0,count:size/2)
            part.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:size,destination:$0.baseAddress!) }
            decoded += part
        }
        XCTAssertEqual(reader.status,.completed,String(describing:reader.error))
        assertSamples(decoded,result,tolerance:1)
        settings.speed = 0.5
        let slow = TimeMapper.outputFrames(used:Array(0..<10),sourceFPS:10,settings:settings)
        let slowResult = VideoSource.arrange(frames:sourceFrames,outputFrames:slow,outputFPS:20,cacheRoot:root)
        XCTAssertNil(slowResult.error)
        let actual = try read(XCTUnwrap(slowResult.url))
        var expected = [Int16](repeating:0,count:actual.count)
        for i in 0..<(actual.count/2) {
            let p = (Double(i)+0.5)*0.5-0.5, a = Int(floor(p)), alpha = p-Double(a)
            for channel in 0..<2 {
                let x = Double(samples[max(0,a)*2+channel]), y = Double(samples[max(0,a+1)*2+channel])
                expected[i*2+channel] = Int16((x*(1-alpha)+y*alpha).rounded())
            }
        }
        assertSamples(actual,expected,tolerance:1)
    }
    func testReverseCutsRepeatsAndCloseupUseTheFinishedTimeline() throws {
        let root = try temporary(), (url,samples) = try source(root), cache = root.appendingPathComponent("clip")
        _ = try VideoSource.prepare(videoURL:url,stageDirectory:cache,sourceStart:0,seconds:1,sampleFPS:10,frameCount:10)
        let sourceFrames = frames(cache)
        func cell(_ i: Int) -> [Int16] { Array(samples[i*9600..<(i+1)*9600]) }
        func reverseSamples(_ pcm: [Int16]) -> [Int16] {
            stride(from:pcm.count-2,through:0,by:-2).flatMap { [pcm[$0],pcm[$0+1]] }
        }
        func render(_ timeline: [OutputFrame]) throws -> [Int16] {
            let audio = VideoSource.arrange(frames:sourceFrames,outputFrames:timeline,outputFPS:10,cacheRoot:root)
            XCTAssertNil(audio.error);return try read(XCTUnwrap(audio.url))
        }
        var settings = ExportSettings();settings.outputFPS = 10
        let used = [2,4,5,8], selected = used.flatMap(cell)
        assertSamples(try render(TimeMapper.outputFrames(used:used,sourceFPS:10,settings:settings)),selected)
        settings.loop = .reverse
        assertSamples(try render(TimeMapper.outputFrames(used:used,sourceFPS:10,settings:settings)),reverseSamples(selected))
        settings.loop = .pingPong;settings.repeatCount = 2
        let ping = ProjectTimeline.frames(used:[2,4],clips:[],closeups:[],fallbackFPS:10,settings:settings)
        let pingExpected = cell(2)+cell(4)+reverseSamples(cell(2))+cell(4)+reverseSamples(cell(2))
        assertSamples(try render(ping),pingExpected)
        settings.loop = .forward;settings.repeatCount = 1
        var shot = Closeup();shot.frame = 2;shot.endFrame = 3;shot.seconds = 0.2
        let shots = ProjectTimeline.frames(used:Array(0..<10),clips:[],closeups:[shot],fallbackFPS:10,settings:settings)
        var expected = samples
        expected.replaceSubrange(19200..<38400,with:Array(repeating:0,count:19200))
        assertSamples(try render(shots),expected)
    }
}
