import Foundation
import CoreGraphics
import BirdLockCore

public protocol AircraftBodyDetecting: AnyObject {
    func detectAircraftBodies(image: CGImage, scoreThreshold: Double) throws -> [Detection]
}

extension YOLOModel: AircraftBodyDetecting {
    public func detectAircraftBodies(image: CGImage, scoreThreshold: Double) throws -> [Detection] {
        guard let index = airplaneClassIndex else { throw ModelError.badOutput("当前整机检测模型不包含飞机类别") }
        return try detect(image: image,classIndex: index,scoreThreshold: scoreThreshold)
    }
}

/// Photo-to-track aircraft backend. The bird pose model is never called.
/// Called only for the independent aircraft subject; bird pose models are not loaded.
public final class AircraftAnalyzer: @unchecked Sendable {
    private static let workSlot = DispatchSemaphore(value: 1)
    private let detectorFactory: () throws -> AircraftBodyDetecting
    public let cache: ProxyCache
    public let manifest: AircraftModelManifest
    private let directory: URL
    private let options: AnalyzerOptions
    private let partsFactory: (() -> AircraftNoseDetecting)?

    /// Borrow an existing detector; its external owner controls its memory lifetime.
    public convenience init(detector: AircraftBodyDetecting, partsDirectory: URL, cache: ProxyCache = .shared,
                options: AnalyzerOptions = AnalyzerOptions(), partsFactory: (() -> AircraftNoseDetecting)? = nil) throws {
        try self.init(detectorFactory: { detector },partsDirectory: partsDirectory,cache: cache,options: options,partsFactory: partsFactory)
    }

    /// Product analysis should create a scoped detector, so its Core ML buffers can be released
    /// before the separate part runtime is loaded. A factory must not capture an existing model.
    public init(detectorFactory: @escaping () throws -> AircraftBodyDetecting, partsDirectory: URL, cache: ProxyCache = .shared,
                options: AnalyzerOptions = AnalyzerOptions(), partsFactory: (() -> AircraftNoseDetecting)? = nil) throws {
        self.detectorFactory = detectorFactory; self.directory = partsDirectory; self.cache = cache; self.options = options
        self.manifest = try AircraftModelManifest.load(directory: partsDirectory,verifyWeights: false)
        self.partsFactory = partsFactory
    }

    public func analyze(frames: [SourceFrame], fps: Double, targetHint: (frame: Int,point: V2)? = nil,
                        clips: [BurstClip] = [], progress: AnalysisProgress? = nil,
                        isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> SequenceAnalysis {
        if isCancelled() { throw CancellationError() }
        var notified = false
        while Self.workSlot.wait(timeout: .now()+0.1) != .success {
            if isCancelled() { throw CancellationError() }
            if !notified { progress?(.queued,0);notified = true }
        }
        defer { Self.workSlot.signal() }
        if isCancelled() { throw CancellationError() }
        return try analyzeSerial(frames: frames,fps: fps,targetHint: targetHint,clips: clips,progress: progress,isCancelled: isCancelled)
    }

    private func analyzeSerial(frames: [SourceFrame], fps: Double, targetHint: (frame: Int,point: V2)?,
                               clips: [BurstClip],progress: AnalysisProgress?,isCancelled: @escaping @Sendable () -> Bool) throws -> SequenceAnalysis {
        let count = frames.count, identity = manifest.analysisIdentity
        let fingerprint = Analyzer.fingerprint(frames,aircraftModelIdentity: identity)
        let proxyLongSide = max(1,min(4096,options.proxyLongSide))
        var per = (0..<count).map { FrameAnalysis(index: $0) }, scales = [Double](repeating: 1,count: count)
        func check() throws { if isCancelled() { throw CancellationError() } }
        func read(_ i: Int) -> CGImage? { cache.loadProxy(fingerprint: fingerprint,index: i) }
        // Decode one photo at a time; the large part model has a separate, serial lifetime below.
        progress?(.aircraftDetecting,0)
        try check()
        try autoreleasepool {
            let detector = try detectorFactory()
            for i in 0..<count {
                try check()
                try autoreleasepool {
                    let photo = frames[i], url = cache.proxyURL(fingerprint: fingerprint,index: i)
                    var image = read(i)
                    if image == nil {
                        image = ImageLoader.load(photo.url,maxPixel: proxyLongSide)
                        if let image, !ImageLoader.writeJPEG(image,to: url,quality: 0.9) {
                            throw ModelError.badOutput("无法保存分析预览，请检查剩余空间")
                        }
                    }
                    guard let image else { return }
                    let k = Double(photo.pixelWidth)/Double(image.width); scales[i] = k
                    let detected = try detector.detectAircraftBodies(image: image,scoreThreshold: options.detectionThreshold)
                    per[i].birds = detected.map { BoxD(x: $0.x*k,y: $0.y*k,w: $0.w*k,h: $0.h*k,score: $0.score) }
                }
                progress?(.aircraftDetecting,Double(i+1)/Double(max(1,count)))
            }
        }
        try check()
        let targets = TargetTracker.track(per.map(\.birds),hint: targetHint,clips: clips)
        for i in 0..<count { per[i].target = targets[i] }
        progress?(.background,0)
        for i in 0..<count {
            try check()
            autoreleasepool {
                guard let image = read(i) else { return }
                let k = scales[i]
                let exclude = per[i].targetBox.map { CGRect(x: $0.x/k,y: $0.y/k,width: $0.w/k,height: $0.h/k).insetBy(dx: -$0.w/k*0.15,dy: -$0.h/k*0.15) }
                per[i].bgLinear = Analyzer.backgroundStats(image,exclude: exclude)
            }
            progress?(.background,Double(i+1)/Double(max(1,count)))
        }
        let bodies = per.indices.map { i -> BoxD? in
            guard let body = per[i].targetBox else { return nil }
            let k = scales[i]
            return BoxD(x: body.x/k,y: body.y/k,w: body.w/k,h: body.h/k,score: body.score)
        }
        try check()
        let parts = partsFactory?() ?? AircraftPartsDetector(directory: directory)
        let observed = try AircraftSequenceAnalyzer.run(bodies: bodies,clips: clips,detector: parts,loadImage: read,
            isCancelled: isCancelled,progress: { progress?(.aircraftParts,$0) })
        for i in 0..<count {
            var record = observed[i]
            if var nose = record.nose {
                let k = scales[i];nose.x *= k;nose.y *= k;nose.w *= k;nose.h *= k;record.nose = nose
            }
            per[i].aircraft = record
        }
        progress?(.sharpness,0)
        for i in 0..<count {
            try check()
            autoreleasepool {
                guard let nose = observed[i].nose,let image = read(i) else { return }
                let side = Int(max(16,min(384,(max(nose.w,nose.h)*1.5).rounded())))
                if let patch = GrayPatch.extractExact(from: image,x0: Int(nose.center.x.rounded())-side/2,
                    y0: Int(nose.center.y.rounded())-side/2,n: side,factor: 1) { per[i].sharpness = Sharpness.score(patch) }
            }
            progress?(.sharpness,Double(i+1)/Double(max(1,count)))
        }
        try check()
        var analysis = SequenceAnalysis(fingerprint: fingerprint,frames: frames,fps: fps,proxyLongSide: proxyLongSide,
            perFrame: per,poseSchema: .aircraft,subject: .aircraft,modelIdentity: identity)
        analysis.clips = clips;analysis.groupedDetection = true
        progress?(.solving,0)
        analysis.track = TrackBuilder.build(analysis)
        progress?(.solving,1)
        return analysis
    }
}
