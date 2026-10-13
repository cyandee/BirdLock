import Foundation
import CoreGraphics

public struct BoxD: Codable, Hashable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double, score: Double
    public init(_ d: Detection) { x = d.x; y = d.y; w = d.w; h = d.h; score = d.score }
    public init(x: Double, y: Double, w: Double, h: Double, score: Double) { self.x = x; self.y = y; self.w = w; self.h = h; self.score = score }
    public var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    public var center: V2 { V2(x + w / 2, y + h / 2) }
    public var diag: Double { (w * w + h * h).squareRoot() }
}

public struct RegistrationLink: Codable, Sendable {
    public var delta: V2      // head displacement (source px) from previous frame
    public var quality: Double
    public var patchScale: Double  // source px per patch px
}

/// Raw per-frame analysis (model outputs, image statistics). Independent of user edits.
public struct FrameAnalysis: Codable, Sendable {
    public var index: Int
    public var birds: [BoxD] = []           // all bird detections (source coords)
    public var target: Int? = nil           // index into birds of the tracked bird
    public var keypoints: [Keypoint] = []   // pose keypoints of the tracked bird (source coords)
    public var poseScore: Double = 0
    public var head = HeadObservation()
    public var bgLinear: [Double] = [0, 0, 0]  // mean linear RGB of background
    public var sharpness: Double? = nil
    public var link: RegistrationLink? = nil

    public init(index: Int) { self.index = index }
    public var targetBox: BoxD? { target.flatMap { $0 < birds.count ? birds[$0] : nil } }
}

/// Solved per-frame track used for composition.
public struct TrackFrame: Codable, Sendable {
    public var eye: V2
    public var headCenter: V2
    public var headLength: Double   // source px (robustly smoothed)
    public var angle: Double        // head direction (beak), radians, unwrapped, smoothed lightly
    public var measuredEye: V2?     // raw eye keypoint if visible
    public var eyeVisible: Bool
    public var hasData: Bool        // any detection near this frame
    public var confidence: Double   // 0...1
}

public struct Track: Codable, Sendable {
    public var frames: [TrackFrame]
    public var template: HeadTemplate?
    public var reflectDominant: Bool
    public var facingRight: Bool    // dominant facing direction in the source image
    public var medianHeadLength: Double
}

public struct SequenceAnalysis: Codable, Sendable {
    public static let currentVersion = 3
    public var version = SequenceAnalysis.currentVersion
    public var fingerprint: String
    public var frames: [SourceFrame]
    public var fps: Double
    public var proxyLongSide: Int
    public var perFrame: [FrameAnalysis]
    public var poseSchema: PoseSchema
    public var track: Track?
    /// User edits
    public var manualEye: [Int: V2] = [:]
    public var excluded: Set<Int> = []

    public var count: Int { frames.count }
}
