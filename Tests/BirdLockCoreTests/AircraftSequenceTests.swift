import XCTest
import CoreGraphics
@testable import BirdLockCore

final class AircraftSequenceTests: XCTestCase {
    private final class Detector: AircraftNoseDetecting {
        var calls: [Double] = [], closes = 0
        var handler: ((BoxD) throws -> AircraftNoseObservation?)?
        func detect(image: CGImage, body: BoxD, isCancelled: () -> Bool, progress: ((Double) -> Void)?) throws -> AircraftNoseObservation? {
            calls.append(body.x); progress?(1)
            if let handler { return try handler(body) }
            return AircraftNoseObservation(x: body.x+50.27,y: body.y+53.31,w: 20,h: 14,score: 0.6,views: 3)
        }
        func close() { closes += 1 }
    }

    private func image(frame: Int, group: Int = 0) throws -> CGImage {
        let width = 320, height = 240
        var seed = UInt64(20261018+group)
        let texture: [UInt8] = (0..<width*height).map { _ in
            seed = seed &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded: seed >> 32)
        }
        var pixels = [UInt8](repeating: 127, count: width*height)
        for y in 0..<height { for x in 0..<width {
            let sx = x-frame, sy = y+frame
            if sx >= 0 && sx < width && sy >= 0 && sy < height { pixels[y*width+x] = texture[sy*width+sx] }
        } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 8,
            bytesPerRow: width,space: CGColorSpaceCreateDeviceGray(),bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent))
    }

    func testEachBurstGetsItsOwnSeedAndBidirectionalSubpixelTracking() throws {
        let bodies: [BoxD?] = (0..<16).map { i -> BoxD? in
            let score: Double = i%8 == 4 ? 1 : 0.8
            return BoxD(x: 60+Double(i),y: 50-Double(i),w: 160,h: 120,score: score)
        }
        let detector = Detector()
        var reads: [Int] = [], progress: [Double] = []
        let result = try AircraftSequenceAnalyzer.run(bodies: bodies,
            clips: [BurstClip(start: 0,count: 8,fps: 30),BurstClip(start: 8,count: 8,fps: 30)], detector: detector,
            refreshInterval: 100, loadImage: { i in reads.append(i); return try self.image(frame: i,group: i/8) }, progress: { progress.append($0) })
        XCTAssertEqual(detector.calls,[64,72])
        XCTAssertEqual(detector.closes,1)
        XCTAssertEqual(reads.sorted(),Array(0..<16))
        XCTAssertEqual(result.indices.filter { result[$0].source == .detected },[4,12])
        for i in result.indices {
            let nose = try XCTUnwrap(result[i].nose)
            XCTAssertEqual(nose.center.x,120.27+Double(i),accuracy: 0.05)
            XCTAssertEqual(nose.center.y,110.31-Double(i),accuracy: 0.05)
            if result[i].source == .tracked {
                XCTAssertEqual(nose.views,0)
                XCTAssertGreaterThan(try XCTUnwrap(result[i].registrationQuality),12)
            }
        }
        XCTAssertEqual(progress.last,1)
        XCTAssertTrue(zip(progress,progress.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testFailedSemanticRefreshLeavesGapUntilRetry() throws {
        let bodies: [BoxD?] = (0..<8).map { i -> BoxD? in
            let score: Double = i == 0 ? 1 : 0.8
            return BoxD(x: 60+Double(i),y: 50-Double(i),w: 160,h: 120,score: score)
        }
        let detector = Detector()
        detector.handler = { body in
            if body.x == 63 { return nil }
            return AircraftNoseObservation(x: body.x+50.27,y: body.y+53.31,w: 20,h: 14,score: 0.6,views: 3)
        }
        let result = try AircraftSequenceAnalyzer.run(bodies: bodies,detector: detector,refreshInterval: 3,retryInterval: 2,
                                                      loadImage: { try self.image(frame: $0) })
        XCTAssertEqual(detector.calls,[60,63,65])
        XCTAssertEqual(result.map(\.source),[.detected,.tracked,.tracked,.missing,.missing,.detected,.tracked,.tracked])
        XCTAssertNil(result[3].nose); XCTAssertNil(result[4].nose)
        XCTAssertEqual(detector.closes,1)
    }

    func testTrackerKeepsNoseWhenCoarseBodyBoxJumpsAndChangesShape() throws {
        let nose = AircraftNoseObservation(x: 110.27,y: 103.31,w: 20,h: 14,score: 0.6,views: 3)
        let tracked = try XCTUnwrap(AircraftNoseTracker().step(previous: image(frame: 0),current: image(frame: 1),nose: nose,
            previousBody: BoxD(x: 60,y: 50,w: 160,h: 120,score: 0.9), currentBody: BoxD(x: 120,y: 40,w: 120,h: 140,score: 0.9)))
        XCTAssertEqual(tracked.nose.center.x,nose.center.x+1,accuracy: 0.05)
        XCTAssertEqual(tracked.nose.center.y,nose.center.y-1,accuracy: 0.05)
        XCTAssertEqual(tracked.nose.w,20);XCTAssertEqual(tracked.nose.h,14)
    }

    func testCancellationAndDecodeFailureAlwaysReleaseDetector() throws {
        let body = BoxD(x: 60,y: 50,w: 160,h: 120,score: 1), detector = Detector()
        var stop = false
        XCTAssertThrowsError(try AircraftSequenceAnalyzer.run(bodies: [body],detector: detector,loadImage: { _ in
            stop = true; return try self.image(frame: 0)
        },isCancelled: { stop })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(detector.calls.isEmpty)
        XCTAssertEqual(detector.closes,1)
        enum Failure: Error { case decode, inference }
        XCTAssertThrowsError(try AircraftSequenceAnalyzer.run(bodies: [body],detector: detector,loadImage: { _ in throw Failure.decode }))
        XCTAssertEqual(detector.closes,2)
        detector.handler = { _ in throw Failure.inference }
        XCTAssertThrowsError(try AircraftSequenceAnalyzer.run(bodies: [body],detector: detector,loadImage: { _ in try self.image(frame: 0) }))
        XCTAssertEqual(detector.closes,3)
    }

    func testMissingSubjectsAndInvalidClipsDoNotDecodeOrInfer() throws {
        let detector = Detector()
        func unexpected(_ i: Int) -> CGImage? { XCTFail("Unexpected decode"); return nil }
        let result = try AircraftSequenceAnalyzer.run(bodies: [nil,nil,nil],detector: detector,loadImage: unexpected)
        XCTAssertTrue(result.allSatisfy { $0.nose == nil })
        for clips in [[BurstClip(start: 1,count: 2,fps: 30)], [BurstClip(start: 0,count: 4,fps: 30)],
                      [BurstClip(start: 0,count: 1,fps: 30)], [BurstClip(start: 0,count: 2,fps: 30),BurstClip(start: 1,count: 1,fps: 30)]] {
            XCTAssertThrowsError(try AircraftSequenceAnalyzer.run(bodies: [nil,nil,nil],clips: clips,detector: detector,loadImage: unexpected))
        }
        XCTAssertTrue(detector.calls.isEmpty)
        XCTAssertEqual(detector.closes,5)
    }
}
