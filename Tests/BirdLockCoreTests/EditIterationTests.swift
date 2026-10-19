import XCTest
@testable import BirdLockCore

final class EditIterationTests: XCTestCase {
    private func fixture() -> SequenceAnalysis {
        let frames = (0..<6).map { SourceFrame(id: $0,url: URL(fileURLWithPath: "/photo-\($0).jpg"),pixelWidth: 640,pixelHeight: 480,captureTime: Double($0)/30,fileSize: 0,modified: 0,exif: ExifInfo()) }
        var a = SequenceAnalysis(fingerprint: Analyzer.fingerprint(frames),frames: frames,fps: 30,proxyLongSide: 640,
            perFrame: (0..<6).map { var f = FrameAnalysis(index: $0); f.sharpness = Double($0); return f },poseSchema: .cub15)
        a.clips = [BurstClip(start:0,count:2,fps:10),BurstClip(start:2,count:2,fps:30),BurstClip(start:4,count:2,fps:15)]
        a.groupedDetection = true; a.manualEye = [0: V2(40,50),3: V2(60,70)]; a.excluded = [1,4]
        var shot = Closeup();shot.frame = 2;shot.endFrame = 3;shot.seconds = 0.5;a.closeups = [shot]
        return a
    }
    func testOrderCarriesEditsAndCaptureRatesWithPhotos() throws {
        let a = fixture(), result = try ClipOrder.reorder(a,order:[2,0,1]), b = result.analysis
        XCTAssertEqual(result.oldIndices,[4,5,0,1,2,3]);XCTAssertEqual(b.frames.map(\.id),Array(0..<6))
        XCTAssertEqual(b.perFrame.map(\.sharpness),[4,5,0,1,2,3]);XCTAssertEqual(b.manualEye,[2:V2(40,50),5:V2(60,70)])
        XCTAssertEqual(b.excluded,[0,3]);XCTAssertEqual(b.closeups![0].frame,4);XCTAssertEqual(b.closeups![0].endFrame,5)
        XCTAssertEqual(b.clips!.map(\.fps),[15,10,30]);XCTAssertEqual(a.excluded,[1,4])
        let restored = try ClipOrder.reorder(b,order:[1,2,0]).analysis
        XCTAssertEqual(restored.frames,a.frames);XCTAssertEqual(restored.fingerprint,a.fingerprint)
        var aircraft = a;aircraft.subject = .aircraft;aircraft.modelIdentity = "fixture"
        XCTAssertNotEqual(try ClipOrder.reorder(aircraft,order:[0,1,2]).analysis.fingerprint,a.fingerprint)
    }
    func testRejectsCrossCutCloseupsAndInvalidOrder() {
        var a = fixture();a.closeups![0].frame = 1
        XCTAssertThrowsError(try ClipOrder.reorder(a,order:[2,0,1]))
        XCTAssertThrowsError(try ClipOrder.reorder(a,order:[0,0,2]))
        XCTAssertEqual(a.closeups![0].frame,1)
    }
    func testOldCloseupKeepsSilentAndNewShotRoundTrips() throws {
        XCTAssertFalse(try JSONDecoder().decode(Closeup.self,from:Data(#"{"frame":2}"#.utf8)).shutterEnabled)
        XCTAssertTrue(try JSONDecoder().decode(Closeup.self,from:JSONEncoder().encode(Closeup())).shutterEnabled)
    }
    func testOneShotTimingRepeatReverseAndExclusion() {
        var shot = Closeup();shot.frame = 1;shot.endFrame = 2;shot.seconds = 1
        var s = ExportSettings();s.repeatCount = 2
        for mode in [LoopMode.forward,.reverse] {
            s.loop = mode
            let frames = ProjectTimeline.frames(used:[0,1,2,3],clips:[],closeups:[shot],fallbackFPS:30,settings:s)
            let tracks = CloseupAudio.tracks(frames:frames,closeups:[shot])
            XCTAssertEqual(tracks.map(\.timelineStart),[1.0/30,33.0/30]);XCTAssertTrue(tracks.allSatisfy { !$0.loop && $0.fadeIn == 0 && $0.fadeOut == 0 })
            XCTAssertTrue(CloseupAudio.tracks(frames:ProjectTimeline.frames(used:[0,2,3],clips:[],closeups:[shot],fallbackFPS:30,settings:s),closeups:[shot]).isEmpty)
        }
        shot.frame = 0;shot.endFrame = 0;shot.seconds = 1.0/30;s.loop = .forward
        XCTAssertEqual(CloseupAudio.tracks(frames:ProjectTimeline.frames(used:[0],clips:[],closeups:[shot],fallbackFPS:30,settings:s),closeups:[shot]).count,2)
    }
    func testHeadroomCountsOverlappingEventsOnly() {
        var bg = AudioTrack();bg.assetID = "nikon-z8";bg.volume = 0.5
        let shots = (1..<10).map { i -> AudioTrack in var t = AudioTrack();t.assetID = "single-canon-rebel";t.timelineStart = Double(i);t.duration = 0.2;t.volume = 0.7;return t }
        XCTAssertEqual(CloseupAudio.gain(tracks:[bg]+shots,duration:10),1/1.2,accuracy:1e-9)
        XCTAssertEqual(CloseupAudio.gain(tracks:shots+[shots[0]],duration:10),1/1.4,accuracy:1e-9)
    }
}
