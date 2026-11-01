import XCTest
import AVFoundation
@testable import BirdLockCore

final class AudioTests: XCTestCase {
    func testCloseupMutesBurstAndResumesWithoutMutingMusicOrChangingSavedTracks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("ramp.wav"), rate = 48000
        let format = AVAudioFormat(standardFormatWithSampleRate:Double(rate),channels:2)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:UInt32(rate*2))!
        buffer.frameLength = UInt32(rate*2)
        for i in 0..<(rate*2) { for c in 0..<2 { buffer.floatChannelData![c][i] = Float(0.1+Double(i)/Double(rate)*0.2) } }
        try autoreleasepool { let file = try AVAudioFile(forWriting:url,settings:format.settings);try file.write(from:buffer) }
        var camera = AudioTrack();camera.assetID = "sony-20";camera.volume = 1;camera.startOffset = 0.2;camera.timelineStart = 0.1;camera.duration = 0.9;camera.loop = false
        var music = AudioTrack();music.url = url;music.volume = 0.2;music.loop = false
        var settings = AudioSettings();settings.tracks = [camera,music]
        let frames = (0..<12).map { i -> OutputFrame in var f = OutputFrame(a:i,b:i,t:0,fade:1,time:Double(i)/10);f.closeup = (3..<7).contains(i) ? 0 : -1;return f }
        var mixed = CloseupAudio.muteBursts(settings,frames:frames,fps:10)
        XCTAssertEqual(mixed,CloseupAudio.muteBursts(settings,frames:frames,fps:10))
        XCTAssertTrue(settings.tracks[0].muteRanges.isEmpty);XCTAssertTrue(mixed.tracks[1].muteRanges.isEmpty)
        mixed.tracks[0].assetID = nil;mixed.tracks[0].url = url
        let (comp,mix) = try await AudioMixer.makeMix(mixed,duration:1.2)
        let reader = try AVAssetReader(asset:comp)
        let output = AVAssetReaderAudioMixOutput(audioTracks:comp.tracks(withMediaType:.audio),audioSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:rate,AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:false])
        output.audioMix = mix;reader.add(output);XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        while let sb = output.copyNextSampleBuffer() {
            let bb = try XCTUnwrap(CMSampleBufferGetDataBuffer(sb)), size = CMBlockBufferGetDataLength(bb)
            var part = [Float](repeating:0,count:size/4)
            part.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb,atOffset:0,dataLength:size,destination:$0.baseAddress!) }
            samples += part
        }
        XCTAssertEqual(reader.status,.completed,String(describing:reader.error))
        for time in [0.2,0.299,0.301,0.5,0.699,0.701,0.8,1.1] {
            let burst = (time >= 0.1 && time < 1 && !(0.3..<0.7).contains(time)) ? 0.1+(time+0.1)*0.2 : 0
            XCTAssertEqual(Double(samples[Int((time*Double(rate)).rounded())*2]),(burst+0.2*(0.1+time*0.2))/1.2,accuracy:0.002,"\(time)s")
        }
    }
    func testOldMusicSettingsAndIndependentTracksRoundTrip() throws {
        let old = try JSONDecoder().decode(AudioSettings.self, from: Data(#"{"volume":0.7,"loop":false}"#.utf8))
        XCTAssertTrue(old.tracks.isEmpty)
        var s = old
        var layer = AudioTrack(); layer.assetID = "sony-10"; layer.timelineStart = 0.25
        s.tracks = [layer]
        let restored = try JSONDecoder().decode(AudioSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(restored.tracks, s.tracks)
        XCTAssertTrue(restored.isActive)
        XCTAssertNotNil(restored.tracks[0].sourceURL)
        XCTAssertEqual(SoundLibrary.assets.count, 12)
    }

    func testMixKeepsIndependentTimingMuteAndFullVideoDuration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9600)!
        buffer.frameLength = 9600
        for i in 0..<9600 { buffer.floatChannelData![0][i] = 0.4 }
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        var first = AudioTrack(); first.url = url; first.loop = false; first.volume = 1
        var second = first; second.id = UUID(); second.timelineStart = 0.4
        var silent = first; silent.id = UUID(); silent.muted = true
        var s = AudioSettings(); s.tracks = [first, second, silent]
        let (comp, mix) = try await AudioMixer.makeMix(s, duration: 1)
        let tracks = comp.tracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 3) // Two audible layers and a silent tail.
        XCTAssertEqual(comp.duration.seconds, 1, accuracy: 0.001)
        XCTAssertEqual(mix.inputParameters.count, 3)
        let secondContent = tracks[1].segments.filter { !$0.isEmpty }
        XCTAssertEqual(secondContent[0].timeMapping.target.start.seconds, 0.4, accuracy: 0.001)
        XCTAssertEqual(secondContent[0].timeMapping.target.duration.seconds, 0.2, accuracy: 0.001)
        var start: Float = 0, end: Float = 0
        var range = CMTimeRange.zero
        XCTAssertTrue(mix.inputParameters[0].getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 0.5, accuracy: 0.001)
    }

    func testMissingActiveAudioFailsVisibly() async {
        var track = AudioTrack(); track.assetID = "missing-sound"
        var settings = AudioSettings(); settings.tracks = [track]
        do {
            _ = try await AudioMixer.makeMix(settings, duration: 1)
            XCTFail("Missing active audio must not silently disappear")
        } catch { }
    }

    func testBundledMP3AndWAVDecodeTogether() async throws {
        var s = AudioSettings()
        s.url = try XCTUnwrap(SoundLibrary.url(for: "nikon-z8"))
        var effect = AudioTrack(); effect.assetID = "sony-20"; effect.timelineStart = 0.5; effect.duration = 1
        s.tracks = [effect]
        let (comp, mix) = try await AudioMixer.makeMix(s, duration: 2.3)
        let reader = try AVAssetReader(asset: comp)
        let output = AVAssetReaderAudioMixOutput(audioTracks: comp.tracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.audioMix = mix
        reader.add(output)
        XCTAssertTrue(reader.startReading(), String(describing: reader.error))
        var samples = 0
        while let sb = output.copyNextSampleBuffer() { samples += CMSampleBufferGetNumSamples(sb) }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        XCTAssertEqual(comp.duration.seconds, 2.3, accuracy: 1.0 / 48000)
        // Compressed source decoding may include a final partial packet; mux trims its session.
        XCTAssertEqual(Double(samples) / 48000, 2.3, accuracy: 1152.0 / 44100)
    }
}
