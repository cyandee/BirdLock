import XCTest
@testable import BirdLockCore

final class ProjectTests: XCTestCase {
    func testTargetIdentityResetsAtCutsAndHintOnlyAppliesToItsClip() {
        let left = BoxD(x: 0, y: 0, w: 100, h: 100, score: 0.99)
        let distractor = BoxD(x: 0, y: 0, w: 100, h: 100, score: 0.2)
        let right = BoxD(x: 1000, y: 0, w: 100, h: 100, score: 0.9)
        let detections = [[left], [left], [distractor, right], [distractor, right]]
        let clips = [BurstClip(start: 0, count: 2, fps: 30), BurstClip(start: 2, count: 2, fps: 30)]
        XCTAssertEqual(TargetTracker.track(detections), [0, 0, 0, 0])
        XCTAssertEqual(TargetTracker.track(detections, clips: clips), [0, 0, 1, 1])
        XCTAssertEqual(TargetTracker.track(detections, hint: (2, V2(50, 50)), clips: clips), [0, 0, 0, 0])
    }

    func testImportedGroupsKeepTheirOwnCaptureRate() {
        let firstTimes: [Double] = (0..<6).map { Double($0) / 10.0 }
        let secondTimes: [Double] = (0..<6).map { 4.0 + Double($0) / 20.0 }
        let times: [Double] = firstTimes + secondTimes
        let frames: [SourceFrame] = times.enumerated().map { i, time in
            SourceFrame(id: i, url: URL(fileURLWithPath: "/test-\(i).jpg"), pixelWidth: 640,
                        pixelHeight: 480, captureTime: time, fileSize: 1, modified: 0, exif: ExifInfo())
        }
        let groups: [BurstSegment] = FrameImporter.segments(frames)
        XCTAssertEqual(groups.map(\.range), [0..<6, 6..<12])
        XCTAssertEqual(groups.map(\.fps), [10, 20])
    }

    func testBurstFPSAndCutBoundaries() {
        var settings = ExportSettings(); settings.interpolation = .blend
        let clips = [BurstClip(start: 0,count: 5,fps: 10),BurstClip(start: 5,count: 5,fps: 30)]
        let frames = ProjectTimeline.frames(used: Array(0..<10), clips: clips, closeups: [], fallbackFPS: 30, settings: settings)
        XCTAssertEqual(frames.count,18)
        XCTAssertTrue(frames.allSatisfy { ($0.a < 5) == ($0.b < 5) })
        XCTAssertEqual(frames.last!.time,17.0/30,accuracy:1e-9)
    }

    func testCloseupReplacesRangeRatherThanAddingOverIt() {
        var shot = Closeup(); shot.frame = 1; shot.endFrame = 2; shot.seconds = 2
        let frames = ProjectTimeline.frames(used: [0,1,2,3], clips: [], closeups: [shot], fallbackFPS: 30, settings: ExportSettings())
        XCTAssertEqual(frames.count,62)
        XCTAssertEqual(frames.filter { $0.closeup == 0 }.count,60)
        XCTAssertEqual(frames.filter { $0.closeup < 0 }.map(\.a),[0,3])
        XCTAssertTrue(frames.filter { $0.closeup == 0 }.allSatisfy { $0.a == 1 && $0.b == 1 })
    }

    func testExcludedCloseupAnchorStaysExcluded() {
        var shot = Closeup(); shot.frame = 1; shot.endFrame = 2
        let frames = ProjectTimeline.frames(used: [0,2,3], clips: [], closeups: [shot], fallbackFPS: 30, settings: ExportSettings())
        XCTAssertFalse(frames.contains { $0.a == 1 || $0.closeup >= 0 })
    }

    func testMusicAlignmentResolvesReplacementAndRejectsOmittedPhotos() {
        var shot = Closeup(); shot.frame = 1; shot.endFrame = 2; shot.seconds = 2
        let frames = ProjectTimeline.frames(used: [0,1,2,3], clips: [], closeups: [shot], fallbackFPS: 30, settings: ExportSettings())
        XCTAssertEqual(ProjectTimeline.sourceTime(2, outputFrames: frames, closeups: [shot])!, 1.0/30, accuracy: 1e-9)
        XCTAssertEqual(ProjectTimeline.sourceTime(3, outputFrames: frames, closeups: [shot])!, 61.0/30, accuracy: 1e-9)
        XCTAssertNil(ProjectTimeline.sourceTime(9, outputFrames: frames, closeups: [shot]))
        let trimmed = ProjectTimeline.frames(used: [0,3], clips: [], closeups: [shot], fallbackFPS: 30, settings: ExportSettings())
        XCTAssertNil(ProjectTimeline.sourceTime(2, outputFrames: trimmed, closeups: [shot]))
    }

    func testMusicOnsetsAndClimaxCandidatesAreLocalAndSilenceIsEmpty() {
        XCTAssertTrue(MusicCues.analyze(peaks: Array(repeating:0,count:480)).isEmpty)
        XCTAssertTrue(MusicCues.analyze(peaks: Array(repeating:0.2,count:480)).isEmpty)
        var peaks = [Float](repeating:0.1,count:480)
        peaks[80] = 0.9; peaks[160] = 0.9
        for i in 320..<440 { peaks[i] = 0.7 }
        let cues = MusicCues.analyze(peaks: peaks)
        XCTAssertTrue(cues.contains { !$0.climax && abs($0.time-2)<0.1 })
        XCTAssertTrue(cues.contains { $0.climax && $0.time>=8 && $0.time<=11 })
    }
}
