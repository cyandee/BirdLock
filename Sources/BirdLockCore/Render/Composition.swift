import Foundation
import CoreGraphics

public enum LockPoint: String, Codable, CaseIterable, Sendable, Identifiable {
    case eye, headCenter
    public var id: String { rawValue }
    public var title: String { self == .eye ? "鸟眼（遮挡时自动用鸟头）" : "鸟头中心" }
}

public enum SizeMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case lockSize      // bird keeps the same size on screen
    case fixedCrop     // constant crop size: bird grows/shrinks naturally
    public var id: String { rawValue }
    public var title: String { self == .lockSize ? "锁定主体大小" : "固定取景（自然远近）" }
}

public enum RotationMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, lockHead, followHeadSmooth
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "不旋转"
        case .lockHead: return "锁定头部角度"
        case .followHeadSmooth: return "柔和校正倾斜"
        }
    }
}

public enum EdgeFill: String, Codable, CaseIterable, Sendable, Identifiable {
    case shift, autoZoom, blurExtend, black
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .shift: return "平移取景，用满原图（推荐）"
        case .autoZoom: return "放大避免越界（保持锁定）"
        case .blurExtend: return "模糊延展填充"
        case .black: return "黑边"
        }
    }
}

public struct Composition: Codable, Hashable, Sendable {
    public var lockPoint: LockPoint = .eye
    /// Anchor position in the output frame, normalised (0..1, top-left origin)
    public var anchorX: Double = 0.5
    public var anchorY: Double = 0.45
    /// Automatically mirror anchorX so there is more space in front of the bird
    public var autoLeadRoom: Bool = true
    /// Output short side = framing × head length
    public var framing: Double = 14
    public var sizeMode: SizeMode = .lockSize
    /// Smoothing of the bird size (frames, gaussian sigma)
    public var sizeSmoothing: Double = 12
    public var rotationMode: RotationMode = .none
    public var rotationOffsetDeg: Double = 0
    /// 0 = hard lock; 1 = very soft camera follow
    public var followSoftness: Double = 0
    public var edgeFill: EdgeFill = .shift
    /// `.shift`: the anchor keeps at least this distance (fraction of the output size) from the output edge
    public var edgeMargin: Double = 0.12
    /// `.shift`: largest extra zoom used to keep the bird away from the edge
    public var maxEdgeZoom: Double = 1.6

    public static let framingRange: ClosedRange<Double> = 2...300

    public init() {}

    // Tolerant decoding: settings saved by older versions (missing keys, unknown values) keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Composition()
        lockPoint = c.value(.lockPoint, d.lockPoint)
        anchorX = c.value(.anchorX, d.anchorX)
        anchorY = c.value(.anchorY, d.anchorY)
        autoLeadRoom = c.value(.autoLeadRoom, d.autoLeadRoom)
        framing = c.value(.framing, d.framing)
        sizeMode = c.value(.sizeMode, d.sizeMode)
        sizeSmoothing = c.value(.sizeSmoothing, d.sizeSmoothing)
        rotationMode = c.value(.rotationMode, d.rotationMode)
        rotationOffsetDeg = c.value(.rotationOffsetDeg, d.rotationOffsetDeg)
        followSoftness = c.value(.followSoftness, d.followSoftness)
        edgeFill = c.value(.edgeFill, d.edgeFill)
        edgeMargin = c.value(.edgeMargin, d.edgeMargin)
        maxEdgeZoom = c.value(.maxEdgeZoom, d.maxEdgeZoom)
    }
}

public extension KeyedDecodingContainer {
    /// Decodes `key`, falling back to `fallback` when it is missing or cannot be decoded.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

public struct CompositionPreset: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var detail: String
    public var composition: Composition

    public init(id: String, name: String, detail: String, composition: Composition) {
        self.id = id; self.name = name; self.detail = detail; self.composition = composition
    }

    public static let all: [CompositionPreset] = {
        var p: [CompositionPreset] = []
        var c = Composition()
        c.anchorX = 0.5; c.anchorY = 0.5; c.autoLeadRoom = false; c.framing = 14
        p.append(.init(id: "center", name: "鸟眼居中", detail: "鸟眼锁定在画面正中，最经典的锁头效果", composition: c))

        c = Composition()
        c.anchorX = 0.36; c.anchorY = 0.42; c.autoLeadRoom = true; c.framing = 14
        p.append(.init(id: "lead", name: "前方留白", detail: "鸟眼在三分线附近，飞行方向留出空间", composition: c))

        c = Composition()
        c.anchorX = 0.5; c.anchorY = 0.45; c.autoLeadRoom = false; c.framing = 6; c.rotationMode = .lockHead
        p.append(.init(id: "closeup", name: "头部特写", detail: "放大鸟头，锁定头部角度，强调眼神", composition: c))

        c = Composition()
        c.anchorX = 0.42; c.anchorY = 0.4; c.autoLeadRoom = true; c.framing = 26
        p.append(.init(id: "wide", name: "全身舒展", detail: "取景宽松，完整展示振翅", composition: c))

        c = Composition()
        c.anchorX = 0.4; c.anchorY = 0.45; c.autoLeadRoom = true; c.framing = 18; c.followSoftness = 0.45
        c.rotationMode = .followHeadSmooth
        p.append(.init(id: "cine", name: "电影跟随", detail: "镜头柔和跟随，鸟在画面中轻微浮动", composition: c))

        c = Composition()
        c.anchorX = 0.5; c.anchorY = 0.5; c.autoLeadRoom = false; c.framing = 20; c.sizeMode = .fixedCrop
        p.append(.init(id: "natural", name: "自然远近", detail: "鸟头锁定，大小随距离自然变化", composition: c))
        return p
    }()
}

public struct AspectRatio: Codable, Hashable, Sendable, Identifiable {
    public var w: Double
    public var h: Double
    public var label: String
    public var id: String { label }
    public init(w: Double, h: Double, label: String) { self.w = w; self.h = h; self.label = label }
    public var value: Double { w / h }

    public static let presets: [AspectRatio] = [
        .init(w: 9, h: 16, label: "9:16 竖屏"),
        .init(w: 3, h: 4, label: "3:4 小红书"),
        .init(w: 4, h: 5, label: "4:5"),
        .init(w: 1, h: 1, label: "1:1"),
        .init(w: 5, h: 4, label: "5:4"),
        .init(w: 4, h: 3, label: "4:3"),
        .init(w: 3, h: 2, label: "3:2"),
        .init(w: 16, h: 9, label: "16:9"),
        .init(w: 1.85, h: 1, label: "1.85:1 电影"),
        .init(w: 2, h: 1, label: "2:1"),
        .init(w: 2.39, h: 1, label: "2.39:1 宽银幕"),
        .init(w: 21, h: 9, label: "21:9"),
    ]
}
