import Foundation

/// Semantic bird parts. Raw values match keypoint names in the pose model's sidecar json.
public enum BirdPart: String, Codable, CaseIterable, Sendable {
    case back, beak, belly, breast, crown, forehead
    case leftEye = "left_eye", rightEye = "right_eye"
    case leftLeg = "left_leg", rightLeg = "right_leg"
    case leftWing = "left_wing", rightWing = "right_wing"
    case nape, tail, throat
    case leftShoulder = "left_shoulder", rightShoulder = "right_shoulder"
    case headTop = "head_top"

    public static let headParts: [BirdPart] = [.beak, .crown, .forehead, .leftEye, .rightEye, .nape, .throat, .headTop]
}

public struct PoseSchema: Codable, Sendable {
    public var keypoints: [String]
    public var inputCropExpand: Double?

    public static let cub15 = PoseSchema(keypoints: ["back", "beak", "belly", "breast", "crown", "forehead", "left_eye", "left_leg",
                                                     "left_wing", "nape", "right_eye", "right_leg", "right_wing", "tail", "throat"],
                                         inputCropExpand: 1.25)
    public static let aircraft = PoseSchema(keypoints: [], inputCropExpand: nil)

    public func index(of part: BirdPart) -> Int? { keypoints.firstIndex(of: part.rawValue) }
}

public enum ModelStore {
    public static let detectorName = "BirdDetector"
    public static let poseName = "BirdPose"

    /// Directories searched for compiled models (*.mlmodelc), in order.
    public static func searchDirectories() -> [URL] {
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["BIRDLOCK_MODELS"] { dirs.append(URL(fileURLWithPath: env)) }
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("Models")) }
        // Development: walk up from the executable looking for a "Models" folder (repo root)
        var u = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            dirs.append(u.appendingPathComponent("Models"))
            u.deleteLastPathComponent()
        }
        return dirs
    }

    public static func locate(_ name: String) -> URL? {
        let fm = FileManager.default
        for d in searchDirectories() {
            let u = d.appendingPathComponent(name + ".mlmodelc")
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    public static func loadSchema(for modelURL: URL) -> PoseSchema {
        let j = modelURL.deletingPathExtension().appendingPathExtension("json")
        if let d = try? Data(contentsOf: j), let s = try? JSONDecoder().decode(PoseSchema.self, from: d) { return s }
        return .cub15
    }
}

/// Holds both models; created once and shared.
public final class BirdModels: @unchecked Sendable {
    public let detector: YOLOModel
    public let pose: YOLOModel
    public let schema: PoseSchema

    public init(detectorURL: URL? = nil, poseURL: URL? = nil) throws {
        guard let d = detectorURL ?? ModelStore.locate(ModelStore.detectorName) else { throw ModelError.notFound(ModelStore.detectorName) }
        guard let p = poseURL ?? ModelStore.locate(ModelStore.poseName) else { throw ModelError.notFound(ModelStore.poseName) }
        detector = try YOLOModel(url: d, keypointCount: 0)
        schema = ModelStore.loadSchema(for: p)
        pose = try YOLOModel(url: p, keypointCount: schema.keypoints.count)
    }
}
