import XCTest
import CoreGraphics
import CryptoKit
@testable import BirdLockCore
import BirdLockAircraftRuntime

final class AircraftBackendTests: XCTestCase {
    private func analysis(count: Int = 3) -> SequenceAnalysis {
        let frames = (0..<count).map { i in SourceFrame(id: i,url: URL(fileURLWithPath: "/bird\(i).jpg"),pixelWidth: 640,
            pixelHeight: 480,captureTime: nil,fileSize: 1,modified: 1,exif: ExifInfo()) }
        let per = (0..<count).map { i -> FrameAnalysis in
            var value = FrameAnalysis(index: i)
            value.birds = [BoxD(x: 50,y: 50,w: 200,h: 100,score: 0.9)];value.target = 0
            if i != 1 { value.aircraft = AircraftFrameObservation(nose: AircraftNoseObservation(x: Double(60+i*2),y: 70,w: 20,h: 14,score: 0.6,views: 3),source: .detected) }
            return value
        }
        return SequenceAnalysis(fingerprint: "test",frames: frames,fps: 30,proxyLongSide: 640,perFrame: per,poseSchema: .cub15,
                                subject: .aircraft,modelIdentity: "parts-v1")
    }

    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testOldCacheDefaultsToBirdAndNewSubjectAndModelCachesStaySeparate() throws {
        var a = analysis();a.manualEye[1] = V2(74,77);a.excluded = [2];a.groupedDetection = true
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as? [String: Any])
        old.removeValue(forKey: "subject");old.removeValue(forKey: "modelIdentity")
        var per = try XCTUnwrap(old["perFrame"] as? [[String: Any]])
        for i in per.indices { per[i].removeValue(forKey: "aircraft") }
        old["perFrame"] = per
        let legacy = try JSONDecoder().decode(SequenceAnalysis.self,from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(legacy.analysisSubject,.bird)
        XCTAssertEqual(legacy.manualEye[1],V2(74,77));XCTAssertEqual(legacy.excluded,[2]);XCTAssertEqual(legacy.groupedDetection,true)
        let modern = try JSONDecoder().decode(SequenceAnalysis.self,from: JSONEncoder().encode(a))
        XCTAssertEqual(modern.analysisSubject,.aircraft);XCTAssertEqual(modern.modelIdentity,"parts-v1")
        XCTAssertEqual(modern.perFrame[0].aircraft?.nose?.center,V2(70,77))
        var edited = modern;edited.manualEye[1] = V2(80,81);edited.excluded = []
        XCTAssertEqual(modern.manualEye[1],V2(74,77));XCTAssertEqual(modern.excluded,[2])
        let keys = [Analyzer.fingerprint(a.frames),Analyzer.fingerprint(a.frames,aircraftModelIdentity: "v1"),
                    Analyzer.fingerprint(a.frames,aircraftModelIdentity: "v2")]
        XCTAssertEqual(Set(keys).count,3)
        XCTAssertEqual(keys[0],"b50224ee5d0a5f2fd55ded0b")
    }

    func testAircraftDoesNotUseBirdPoseOrBodyCentresAsNosesAndDoesNotCrossCuts() {
        var a = analysis()
        for i in a.perFrame.indices {
            a.perFrame[i].head.points[HeadPoint.eye.rawValue] = V2(500,400)
            a.perFrame[i].head.conf[HeadPoint.eye.rawValue] = 1
            a.perFrame[i].link = RegistrationLink(delta: V2(200,150),quality: 100,patchScale: 1)
        }
        var track = TrackBuilder.build(a)
        XCTAssertEqual(track.frames.map(\.hasData),[true,false,true])
        XCTAssertTrue(track.frames.allSatisfy { !$0.eyeVisible && $0.measuredEye == nil })
        XCTAssertEqual(track.frames[0].headCenter,V2(70,77));XCTAssertEqual(track.frames[2].headCenter,V2(74,77))
        for i in a.perFrame.indices { a.perFrame[i].aircraft = nil }
        XCTAssertTrue(TrackBuilder.build(a).frames.allSatisfy { !$0.hasData })
        a.manualEye[1] = V2(80,90);track = TrackBuilder.build(a)
        XCTAssertEqual(track.frames.map(\.hasData),[false,true,false]);XCTAssertEqual(track.frames[1].headCenter,V2(80,90))
        var grouped = analysis(count: 4)
        grouped.clips = [BurstClip(start: 0,count: 2,fps: 30),BurstClip(start: 2,count: 2,fps: 30)]
        grouped.perFrame[0].aircraft = nil
        track = TrackBuilder.build(grouped)
        XCTAssertEqual(track.frames.map(\.hasData),[false,false,true,true])
        XCTAssertEqual(track.frames[0].headCenter,V2(0,0));XCTAssertEqual(track.frames[1].headLength,100)
    }

    func testAircraftHasNoEyeFrameAndWholeAirframeIncludesIndependentNose() throws {
        var a = analysis();a.perFrame[0].birds[0] = BoxD(x: 100,y: 50,w: 150,h: 100,score: 0.9)
        a.track = TrackBuilder.build(a)
        var composition = Composition();composition.edgeFill = .black;composition.autoLeadRoom = false
        var selection = FrameSelection();selection.dropUntracked = false;selection.dropBlurry = false
        let job = RenderJob(analysis: a,composition: composition,look: LookSettings(),export: ExportSettings(),
                            selection: selection,cache: ProxyCache(root: try temporary()))
        XCTAssertNil(job.focusRect(0,target: "eye",scale: 1))
        XCTAssertNotNil(job.focusRect(0,target: "head",scale: 1));XCTAssertNil(job.focusRect(1,target: "head",scale: 1))
        XCTAssertNotNil(job.focusRect(1,target: "body",scale: 1))
        let rect = try XCTUnwrap(job.focusRect(0,target: "body",scale: 1))
        let point = job.plan.xforms[0].map(V2(60,70))
        XCTAssertTrue(rect.contains(CGPoint(x: point.x,y: point.y)))
        XCTAssertEqual(a.perFrame[0].targetBox?.x,100);XCTAssertEqual(a.perFrame[0].targetBox?.w,150)
    }

    private final class Bodies: AircraftBodyDetecting {
        func detectAircraftBodies(image: CGImage,scoreThreshold: Double) throws -> [Detection] {
            [Detection(x: 60,y: 50,w: 160,h: 120,score: 0.9,keypoints: [])]
        }
    }
    private final class Parts: AircraftNoseDetecting {
        var calls = 0, closes = 0
        func detect(image: CGImage,body: BoxD,isCancelled: () -> Bool,progress: ((Double) -> Void)?) throws -> AircraftNoseObservation? {
            calls += 1
            return AircraftNoseObservation(x: 110,y: 100,w: 20,h: 14,score: 0.6,views: 3)
        }
        func close() { closes += 1 }
    }

    func testScopedBodyDetectorIsReleasedBeforePartModelFactoryRuns() throws {
        let root = try temporary()
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        final class Scoped: AircraftBodyDetecting {
            let release: () -> Void
            init(_ release: @escaping () -> Void) { self.release = release }
            deinit { release() }
            func detectAircraftBodies(image: CGImage,scoreThreshold: Double) throws -> [Detection] { [] }
        }
        var released = false, bodyCreations = 0
        let parts = Parts()
        let analyzer = try AircraftAnalyzer(detectorFactory: { bodyCreations += 1;return Scoped { released = true } },
            partsDirectory: repo.appendingPathComponent("SharedResources/AircraftModels"),cache: ProxyCache(root: root),partsFactory: {
                XCTAssertTrue(released);return parts
            })
        _ = try analyzer.analyze(frames: [],fps: 30)
        XCTAssertTrue(released);XCTAssertEqual(bodyCreations,1);XCTAssertEqual(parts.calls,0);XCTAssertEqual(parts.closes,1)
        XCTAssertThrowsError(try analyzer.analyze(frames: [],fps: 30,isCancelled: { true }))
        XCTAssertEqual(bodyCreations,1)
    }

    func testQueuedAircraftAnalysisCanCancelBeforeCreatingAnotherModel() throws {
        final class Flag: @unchecked Sendable {
            let lock = NSLock();private var value = false
            var cancelled: Bool { lock.lock();defer { lock.unlock() };return value }
            func cancel() { lock.lock();value = true;lock.unlock() }
        }
        let root = try temporary()
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = repo.appendingPathComponent("SharedResources/AircraftModels")
        let active = expectation(description: "First analysis owns slot"), queued = expectation(description: "Second queued")
        let firstDone = expectation(description: "First finished"), secondDone = expectation(description: "Queued request cancelled")
        let release = DispatchSemaphore(value: 0), flag = Flag()
        defer { release.signal() }
        let first = try AircraftAnalyzer(detectorFactory: {
            active.fulfill()
            guard release.wait(timeout: .now()+5) == .success else { throw ModelError.badOutput("Test holder timed out") }
            return Bodies()
        },partsDirectory: directory,cache: ProxyCache(root: root.appendingPathComponent("first")))
        let second = try AircraftAnalyzer(detectorFactory: {
            XCTFail("Queued cancellation created another model");return Bodies()
        },partsDirectory: directory,cache: ProxyCache(root: root.appendingPathComponent("second")))
        DispatchQueue.global().async {
            do { _ = try first.analyze(frames: [],fps: 30) } catch { XCTFail("Unexpected first request failure: \(error)") }
            firstDone.fulfill()
        }
        wait(for: [active],timeout: 2)
        DispatchQueue.global().async {
            do {
                _ = try second.analyze(frames: [],fps: 30,progress: { stage,_ in if stage == .queued { queued.fulfill() } },isCancelled: { flag.cancelled })
                XCTFail("Cancelled request finished normally")
            } catch is CancellationError {} catch { XCTFail("Unexpected queue failure: \(error)") }
            secondDone.fulfill()
        }
        wait(for: [queued],timeout: 2);flag.cancel()
        wait(for: [secondDone],timeout: 2)
        release.signal();wait(for: [firstDone],timeout: 2)
        let deadline = Date().addingTimeInterval(2)
        let third = try AircraftAnalyzer(detector: Bodies(),partsDirectory: directory,cache: ProxyCache(root: root.appendingPathComponent("third")))
        _ = try third.analyze(frames: [],fps: 30,isCancelled: { Date() > deadline })
    }

    func testNativePhotoBackendScalesNosesPreservesSourcesAndRoundTripsCache() throws {
        let root = try temporary(), source = root.appendingPathComponent("飞机照片")
        try FileManager.default.createDirectory(at: source,withIntermediateDirectories: true)
        var random: UInt64 = 20261018
        let bytes: [UInt8] = (0..<640*480).map { _ in random = random &* 6364136223846793005 &+ 1;return UInt8(truncatingIfNeeded: random >> 32) }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 640,height: 480,bitsPerComponent: 8,bitsPerPixel: 8,bytesPerRow: 640,
            space: CGColorSpaceCreateDeviceGray(),bitmapInfo: CGBitmapInfo(rawValue: 0),provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent))
        for i in 0..<3 { XCTAssertTrue(ImageLoader.writeJPEG(image,to: source.appendingPathComponent("\(i).jpg"))) }
        let frames = FrameImporter.importFrames([source]);XCTAssertEqual(frames.count,3)
        let before = try frames.map { SHA256.hash(data: try Data(contentsOf: $0.url)) }
        let cache = ProxyCache(root: root.appendingPathComponent("cache"))
        let sentinel = cache.directory(for: Analyzer.fingerprint(frames)).appendingPathComponent("analysis.json")
        try Data("bird cache".utf8).write(to: sentinel)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let parts = Parts();var options = AnalyzerOptions();options.proxyLongSide = 320
        let analyzer = try AircraftAnalyzer(detector: Bodies(),partsDirectory: repo.appendingPathComponent("SharedResources/AircraftModels"),
                                           cache: cache,options: options,partsFactory: { parts })
        let a = try analyzer.analyze(frames: frames,fps: 30)
        XCTAssertEqual(a.analysisSubject,.aircraft);XCTAssertEqual(a.modelIdentity,analyzer.manifest.analysisIdentity)
        XCTAssertEqual(a.fingerprint,Analyzer.fingerprint(frames,aircraftModelIdentity: analyzer.manifest.analysisIdentity))
        XCTAssertTrue(a.poseSchema.keypoints.isEmpty)
        XCTAssertTrue(a.perFrame.allSatisfy { $0.keypoints.isEmpty && $0.head.validCount == 0 })
        XCTAssertEqual(a.perFrame[0].aircraft?.nose?.center,V2(240,214))
        XCTAssertEqual(a.perFrame[0].aircraft?.nose?.w,40)
        XCTAssertTrue(try XCTUnwrap(a.track).frames.allSatisfy(\.hasData))
        XCTAssertEqual(parts.calls,1);XCTAssertEqual(parts.closes,1)
        XCTAssertEqual(try String(contentsOf: sentinel,encoding: .utf8),"bird cache")
        XCTAssertEqual(try frames.map { SHA256.hash(data: try Data(contentsOf: $0.url)) },before)
        cache.saveAnalysis(a)
        let restored = try XCTUnwrap(cache.loadAnalysis(fingerprint: a.fingerprint))
        XCTAssertEqual(restored.analysisSubject,.aircraft);XCTAssertEqual(restored.modelIdentity,a.modelIdentity)
        XCTAssertThrowsError(try analyzer.analyze(frames: frames,fps: 30,isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(parts.calls,1);XCTAssertEqual(parts.closes,1)
    }
}
