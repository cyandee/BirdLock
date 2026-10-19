import Foundation

public struct SoundAsset: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let file: String
    public let fps: Int
    public let cameraID: String
    public let camera: String
    public let variant: String
    public let kind: String
    public let duration: Double
}

public enum SoundLibrary {
    public static var directory: URL? {
        var candidates: [URL] = []
        if let resource = Bundle.main.resourceURL { candidates.append(resource.appendingPathComponent("Audio")) }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("SharedResources/Audio"))
        var root = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<8 {
            candidates.append(root.appendingPathComponent("SharedResources/Audio"))
            root.deleteLastPathComponent()
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("library.json").path) }
    }

    public static var assets: [SoundAsset] {
        guard let root = directory, let data = try? Data(contentsOf: root.appendingPathComponent("library.json")),
              let list = try? JSONDecoder().decode([SoundAsset].self, from: data) else { return [] }
        return list.filter { !$0.file.contains("/") && !$0.file.contains("..") && FileManager.default.fileExists(atPath: root.appendingPathComponent($0.file).path) }
    }

    public static func canonicalID(_ id: String) -> String {
        ["sony-10": "sony-a1m2-10", "sony-20": "sony-a1m2-30"][id] ?? id
    }
    public static var burstAssets: [SoundAsset] { assets.filter { $0.kind == "burst" } }
    public static var cameras: [String] {
        var seen = Set<String>(); return burstAssets.compactMap { seen.insert($0.cameraID).inserted ? $0.cameraID : nil }
    }
    public static func asset(for id: String) -> SoundAsset? { assets.first { $0.id == canonicalID(id) } }
    public static func url(for id: String) -> URL? {
        guard let asset = asset(for: id), let root = directory else { return nil }
        return root.appendingPathComponent(asset.file)
    }
}

/// An independently arranged audio layer. Bundled sounds persist by ID so app moves remain safe.
public struct AudioTrack: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var url: URL? = nil
    public var assetID: String? = nil
    public var startOffset = 0.0
    public var timelineStart = 0.0
    /// Zero means play to the end of the video.
    public var duration = 0.0
    public var volume = 0.5
    public var fadeIn = 0.0
    public var fadeOut = 0.0
    public var loop = true
    public var muted = false
    public init() {}
    public var sourceURL: URL? { assetID.flatMap(SoundLibrary.url) ?? url }
    public var isActive: Bool { !muted && volume > 0.001 && (url != nil || assetID != nil) }
    public var title: String { assetID.flatMap(SoundLibrary.asset)?.title ?? url?.lastPathComponent ?? (assetID != nil ? "已移除档位，请重新选择音效" : "音频轨道") }
}
