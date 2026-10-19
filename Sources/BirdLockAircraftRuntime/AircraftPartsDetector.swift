import Foundation
import CoreGraphics
import BirdLockCore
import OnnxRuntimeBindings

/// Local aircraft-part runtime. Not yet selected by the application's analysis/UI pipeline.
/// One serial CPU session per analysis. Call close() when leaving the aircraft analysis task.
public final class AircraftPartsDetector: AircraftNoseDetecting, @unchecked Sendable {
    private struct State {
        let manifest: AircraftModelManifest
        let environment: ORTEnv
        let session: ORTSession
        let fixedInputs: [String: ORTValue]
    }
    public let directory: URL
    private let lock = NSLock()
    private var state: State?
    public init(directory: URL) { self.directory = directory }

    public var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return state != nil
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        state = nil
    }

    private func integerTensor(_ values: [Int64], shape: [NSNumber]) throws -> ORTValue {
        let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
        return try ORTValue(tensorData: data, elementType: .int64, shape: shape)
    }

    private func load() throws -> State {
        if let state { return state }
        let manifest = try AircraftModelManifest.load(directory: directory)
        let environment = try ORTEnv(loggingLevel: .error)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))))
        try options.setLogSeverityLevel(.error)
        let session = try ORTSession(env: environment, modelPath: directory.appendingPathComponent(manifest.file).path, sessionOptions: options)
        let ids = manifest.tokenIDs, size = manifest.inputSize
        let fixed: [String: ORTValue] = [
            "input_ids": try integerTensor(ids, shape: [1,NSNumber(value: ids.count)]),
            "attention_mask": try integerTensor(Array(repeating: 1, count: ids.count), shape: [1,NSNumber(value: ids.count)]),
            "token_type_ids": try integerTensor(Array(repeating: 0, count: ids.count), shape: [1,NSNumber(value: ids.count)]),
            "pixel_mask": try integerTensor(Array(repeating: 1, count: size*size), shape: [1,NSNumber(value: size),NSNumber(value: size)]),
        ]
        let state = State(manifest: manifest, environment: environment, session: session, fixedInputs: fixed)
        self.state = state
        return state
    }

    private func floats(_ value: ORTValue) throws -> [Float] {
        let bytes = try value.tensorData() as Data
        guard bytes.count % MemoryLayout<Float>.size == 0 else { throw ModelError.badOutput("飞机模型数据长度") }
        var values = [Float](repeating: 0, count: bytes.count/MemoryLayout<Float>.size)
        values.withUnsafeMutableBytes { _ = bytes.copyBytes(to: $0) }
        return values
    }

    /// Cancellation is checked before/after each native runtime call and before preprocessing.
    /// Progress callbacks run on the caller's analysis worker; they must not re-enter this object.
    public func detect(image: CGImage, body: BoxD, isCancelled: () -> Bool = { false },
                       progress: ((Double) -> Void)? = nil) throws -> AircraftNoseObservation? {
        lock.lock(); defer { lock.unlock() }
        do {
            if isCancelled() { throw CancellationError() }
            guard AircraftInputGeometry(imageWidth: image.width, imageHeight: image.height, body: body, rotation: 0) != nil else { return nil }
            guard max(image.width, image.height) <= 4096 else { throw AircraftModelError.proxyTooLarge }
            let loaded = try load()
            if isCancelled() { throw CancellationError() }
            let raster = try AircraftImagePixels(image: image)
            var candidates: [AircraftPartCandidate] = []
            for (index, rotation) in [0,90,180,270].enumerated() {
                if isCancelled() { throw CancellationError() }
                // Drain Objective-C tensor wrappers on every direction, including cancellation;
                // an entire long burst must not retain their temporary dictionaries/buffers.
                let rotationCandidates: [AircraftPartCandidate] = try autoreleasepool {
                    var found: [AircraftPartCandidate] = []
                    guard let input = raster.prepare(body: body, rotation: rotation, manifest: loaded.manifest) else { return [] }
                    if isCancelled() { throw CancellationError() }
                    let data = input.pixels.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
                    var inputs = loaded.fixedInputs
                    let size = loaded.manifest.inputSize
                    inputs["pixel_values"] = try ORTValue(tensorData: data, elementType: .float,
                        shape: [1,3,NSNumber(value: size),NSNumber(value: size)])
                    let output = try loaded.session.run(withInputs: inputs, outputNames: ["logits","pred_boxes"], runOptions: nil)
                    if isCancelled() { throw CancellationError() }
                    guard let logitValue = output["logits"], let boxValue = output["pred_boxes"] else { throw ModelError.badOutput("飞机模型缺少输出") }
                    let logitShape = try logitValue.tensorTypeAndShapeInfo().shape.map(\.intValue)
                    let boxShape = try boxValue.tensorTypeAndShapeInfo().shape.map(\.intValue)
                    guard logitShape == [1,900,256], boxShape == [1,900,4] else { throw ModelError.badOutput("飞机模型输出维度") }
                    let logits = try floats(logitValue), boxes = try floats(boxValue)
                    guard logits.count == 900*256, boxes.count == 900*4 else { throw ModelError.badOutput("飞机模型输出长度") }
                    guard (0..<900).allSatisfy({ logits[$0*256+loaded.manifest.noseTokenIndex].isFinite }) else {
                        throw ModelError.badOutput("飞机模型输出包含无效数值")
                    }
                    let scores = (0..<900).map { i -> Double in
                        let logit = Double(logits[i*256+loaded.manifest.noseTokenIndex])
                        return logit.isFinite ? 1/(1+exp(-max(-40,min(40,logit)))) : 0
                    }
                    for i in (0..<900).sorted(by: { scores[$0] > scores[$1] }).prefix(15) {
                        if let c = input.geometry.candidate(box: Array(boxes[(i*4)..<(i*4+4)]), score: scores[i]) { found.append(c) }
                    }
                    return found
                }
                candidates.append(contentsOf: rotationCandidates)
                progress?(Double(index+1)/4)
            }
            return AircraftPartConsensus.choose(candidates, body: body)
        } catch {
            // Do not keep a large inference arena alive after a failed or cancelled task.
            state = nil
            throw error
        }
    }
}
