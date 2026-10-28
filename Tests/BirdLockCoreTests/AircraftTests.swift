import XCTest
import CoreGraphics
import CryptoKit
@testable import BirdLockCore
import BirdLockAircraftRuntime

final class AircraftTests: XCTestCase {
    func testNativeRuntimeStaysUnloadedForCancelledInvalidOrOversizedRequests() throws {
        func blank(width: Int, height: Int) throws -> CGImage {
            let data = Data(repeating: 127, count: width*height)
            let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
            return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        }
        let runtime = AircraftPartsDetector(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let image = try blank(width: 40, height: 40), body = BoxD(x: 5,y: 5,w: 20,h: 20,score: 0.9)
        XCTAssertFalse(runtime.isLoaded)
        XCTAssertThrowsError(try runtime.detect(image: image, body: body, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertNil(try runtime.detect(image: image, body: BoxD(x: 500,y: 500,w: 20,h: 20,score: 0.9)))
        XCTAssertThrowsError(try runtime.detect(image: blank(width: 4097,height: 1), body: BoxD(x: 0,y: 0,w: 4097,h: 1,score: 0.9)))
        XCTAssertThrowsError(try runtime.detect(image: image, body: body))
        XCTAssertFalse(runtime.isLoaded)
        runtime.close()
        XCTAssertFalse(runtime.isLoaded)
    }

    private func fixtureManifest(directory: URL) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("SharedResources/AircraftModels/manifest.json"))) as? [String: Any])
    }

    func testManifestVerifiesLocalWeightsAndRejectsCorruptionAndUnsafeMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var metadata = try fixtureManifest(directory: directory)
        let weight = Data("test-model".utf8)
        metadata["file"] = "part.onnx"; metadata["bytes"] = weight.count
        metadata["sha256"] = SHA256.hash(data: weight).map { String(format: "%02x", $0) }.joined()
        let manifestURL = directory.appendingPathComponent("manifest.json"), weightURL = directory.appendingPathComponent("part.onnx")
        func save() throws { try JSONSerialization.data(withJSONObject: metadata).write(to: manifestURL) }
        try save()
        XCTAssertThrowsError(try AircraftModelManifest.load(directory: directory))
        try weight.write(to: weightURL)
        XCTAssertEqual(try AircraftModelManifest.load(directory: directory).bytes, weight.count)
        try Data("bad!-model".utf8).write(to: weightURL)
        XCTAssertThrowsError(try AircraftModelManifest.load(directory: directory))
        XCTAssertEqual(try Data(contentsOf: weightURL), Data("bad!-model".utf8))
        metadata["file"] = "../part.onnx"; try save()
        XCTAssertThrowsError(try AircraftModelManifest.load(directory: directory, verifyWeights: false))
        metadata["file"] = "part.onnx"; metadata["input_size"] = 100000; try save()
        XCTAssertThrowsError(try AircraftModelManifest.load(directory: directory, verifyWeights: false))
    }

    func testNativeInputMatchesIndependentOpenCVColorAndRotationSamples() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = try fixtureManifest(directory: directory)
        try JSONSerialization.data(withJSONObject: metadata).write(to: directory.appendingPathComponent("manifest.json"))
        let manifest = try AircraftModelManifest.load(directory: directory, verifyWeights: false)
        var rgba = [UInt8]()
        for y in 0..<7 { for x in 0..<9 { rgba += [UInt8(x*31),UInt8(y*37),UInt8((x*17+y*13)%256),255] } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let image = try XCTUnwrap(CGImage(width: 9, height: 7, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 9*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let pixels = try AircraftImagePixels(image: image), body = BoxD(x: 2,y: 1,w: 4,h: 3,score: 0.9)
        let points = [(0,0),(799,0),(0,799),(799,799),(399,399),(100,600),(700,123)]
        // Golden RGB samples produced independently by cv2.warpAffine + cv2.resize, not this sampler.
        let expected = [
            [[97,87,93],[139,75,110],[127,127,127],[127,127,127],[90,71,74],[89,120,98],[140,67,106]],
            [[127,127,127],[127,127,127],[86,56,73],[127,127,127],[127,71,94],[98,52,78],[127,126,127]],
            [[127,127,127],[127,127,127],[127,127,127],[54,27,39],[127,112,110],[130,121,125],[127,127,127]],
            [[127,127,127],[73,71,71],[127,127,127],[148,54,103],[94,112,92],[127,127,127],[68,63,63]]]
        for (r, rotation) in [0,90,180,270].enumerated() {
            let input = try XCTUnwrap(pixels.prepare(body: body, rotation: rotation, manifest: manifest))
            XCTAssertEqual(input.pixels.count, 800*800*3)
            for (i,p) in points.enumerated() { for c in 0..<3 {
                let value = (input.pixels[c*800*800+p.1*800+p.0]*manifest.imageStd[c]+manifest.imageMean[c])*255
                XCTAssertEqual(Double(value),Double(expected[r][i][c]),accuracy: 1.01,"rotation \(rotation), point \(p), channel \(c)")
            } }
        }
        XCTAssertNil(pixels.prepare(body: BoxD(x: 100,y: 100,w: 4,h: 3,score: 1), rotation: 0, manifest: manifest))
        XCTAssertNil(pixels.prepare(body: body, rotation: 45, manifest: manifest))
    }

    func testCandidateProjectionUsesImageCoordinatesAndRejectsWholeBody() throws {
        let body = BoxD(x: 50,y: 40,w: 100,h: 50,score: 0.9)
        let zero = try XCTUnwrap(AircraftInputGeometry(imageWidth: 200, imageHeight: 150, body: body, rotation: 0))
        let quarter = try XCTUnwrap(AircraftInputGeometry(imageWidth: 200, imageHeight: 150, body: body, rotation: 90))
        let a = try XCTUnwrap(zero.candidate(box: [Float(46.5)/144,0.5,0.05,0.05], score: 0.7))
        let b = try XCTUnwrap(quarter.candidate(box: [0.5,Float(97.5)/144,0.05,0.05], score: 0.7))
        for c in [a,b] { XCTAssertEqual(c.x,70,accuracy: 1e-4); XCTAssertEqual(c.y,65,accuracy: 1e-4) }
        XCTAssertNil(zero.candidate(box: [0.5,0.5,0.85,0.85], score: 1))
        XCTAssertNil(zero.candidate(box: [.nan,0.5,0.05,0.05], score: 1))
    }

    func testConsensusNeedsIndependentViewsAndRejectsNonfiniteOrDisagreeingParts() throws {
        let body = BoxD(x: 0, y: 0, w: 200, h: 100, score: 0.9)
        let duplicates = (0..<5).map { AircraftPartCandidate(rotation: 0, score: 0.8, x: Double(20+$0), y: 30, w: 20, h: 15) }
        XCTAssertNil(AircraftPartConsensus.choose([], body: body))
        XCTAssertNil(AircraftPartConsensus.choose(duplicates, body: body))
        let agreed = try XCTUnwrap(AircraftPartConsensus.choose(duplicates + [AircraftPartCandidate(rotation: 90, score: 0.7, x: 22, y: 32, w: 18, h: 16)], body: body))
        XCTAssertEqual(agreed.views, 2)
        XCTAssertEqual(agreed.center.x, 20.933333333, accuracy: 1e-6)
        XCTAssertEqual(agreed.center.y, 30.933333333, accuracy: 1e-6)
        let bad = [AircraftPartCandidate(rotation: 0, score: 0.8, x: .nan, y: 30, w: 20, h: 15),
                   AircraftPartCandidate(rotation: 90, score: 0.7, x: 22, y: 32, w: 18, h: 16)]
        XCTAssertNil(AircraftPartConsensus.choose(bad, body: body))
        XCTAssertNil(AircraftPartConsensus.choose([duplicates[0], AircraftPartCandidate(rotation: 90, score: 0.9, x: 180, y: 90, w: 20, h: 15)], body: body))
    }

    func testRepeatedRegistrationPreservesFractionalAnchorAndRejectsBlank() throws {
        let width = 320, height = 240
        var random: UInt64 = 20261018
        let texture: [UInt8] = (0..<width*height).map { _ in
            random = random &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded: random >> 32)
        }
        func image(dx: Int, dy: Int, blank: Bool = false) throws -> CGImage {
            var bytes = [UInt8](repeating: 127, count: width*height)
            if !blank {
                for y in 0..<height { for x in 0..<width {
                    let sx = x-dx, sy = y-dy
                    if sx >= 0 && sx < width && sy >= 0 && sy < height { bytes[y*width+x] = texture[sy*width+sx] }
                } }
            }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
            return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        }
        let tracker = AircraftNoseTracker()
        var previous = try image(dx: 0, dy: 0)
        var body = BoxD(x: 60, y: 50, w: 160, h: 120, score: 0.9)
        var nose = AircraftNoseObservation(x: 110.27, y: 103.31, w: 20, h: 14, score: 0.6, views: 3)
        let anchor = nose.center
        for i in 1...20 {
            let current = try image(dx: i, dy: -i)
            let newBody = BoxD(x: Double(60+i), y: Double(50-i), w: 160, h: 120, score: 0.9)
            let step = try XCTUnwrap(tracker.step(previous: previous, current: current, nose: nose, previousBody: body, currentBody: newBody))
            XCTAssertEqual(step.nose.center.x, anchor.x+Double(i), accuracy: 0.05)
            XCTAssertEqual(step.nose.center.y, anchor.y-Double(i), accuracy: 0.05)
            XCTAssertEqual(step.nose.views, 0)
            previous = current; body = newBody; nose = step.nose
        }
        XCTAssertNil(tracker.step(previous: previous, current: try image(dx: 0, dy: 0, blank: true),
                                  nose: nose, previousBody: body, currentBody: body))
        nose.x = .nan
        XCTAssertNil(tracker.step(previous: previous, current: previous, nose: nose, previousBody: body, currentBody: body))
    }
}
