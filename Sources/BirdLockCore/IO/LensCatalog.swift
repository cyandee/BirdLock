import Foundation
import CryptoKit

public struct LensCatalogEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let sourceURL: String
    public let cameraBrand: String
    public let cameraModels: [String]
    public let lensModels: [String]
    public let width: Int
    public let height: Int
    public let fps: Double
    public let focalLength: Double?
    public let fixedFocalLength: Bool
    public let fixedLens: Bool
    public let settings: [String]
    public let stabilizationModes: [String]
    public let autoMatch: Bool
}

public struct LensMatch: Sendable {
    public var metadata: CameraMetadata
    public var candidates: [LensCatalogEntry]
    public var selected: LensCatalogEntry?
    public var message: String
    public var selectedURL: URL? { selected?.url }
    public init(metadata: CameraMetadata, candidates: [LensCatalogEntry], selected: LensCatalogEntry? = nil, message: String = "") {
        self.metadata = metadata; self.candidates = candidates; self.selected = selected; self.message = message
    }
}

public enum LensCatalog {
    private final class CatalogCache: @unchecked Sendable {
        let lock = NSLock()
        var key = ""
        var value: [LensCatalogEntry] = []
    }
    private static let cache = CatalogCache()
    public static let databaseURL = URL(string: "https://github.com/gyroflow/lens_profiles")!
    public static let calibrationURL = URL(string: "https://docs.gyroflow.xyz/app/getting-started/lens-calibration")!
    public static let helpText = "先在 Gyroflow 的「镜头配置」中搜索相机、镜头、焦距和拍摄模式，选中对应配置后导出 JSON。数据库没有时，可按官方镜头标定教程创建配置。索尼相机的同名 XML 可直接导入，用于读取机身、镜头及拍摄模式。"

    public static var directory: URL? {
        if let path = ProcessInfo.processInfo.environment["BIRDLOCK_LENS_PROFILES"] { return URL(fileURLWithPath: path, isDirectory: true) }
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources.appendingPathComponent("LensProfiles")) }
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("SharedResources/LensProfiles"))
        var parent = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 { roots.append(parent.appendingPathComponent("SharedResources/LensProfiles")); parent.deleteLastPathComponent() }
        return roots.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
    }

    public static func entries(root: URL? = nil) throws -> [LensCatalogEntry] {
        guard let root = root ?? directory else { return [] }
        let attributes = try root.appendingPathComponent("manifest.json").resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        let key = "\(root.path)|\(attributes.fileSize ?? 0)|\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        cache.lock.lock()
        if cache.key == key { let result = cache.value; cache.lock.unlock(); return result }
        cache.lock.unlock()
        guard let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any],
              let entries = manifest["profiles"] as? [[String: Any]] else { throw VideoImportError.invalid("内置镜头配置清单无效") }
        let result = try entries.map { entry in
            guard let id = entry["id"] as? String, let title = entry["title"] as? String,
                  let file = entry["file"] as? String, file == (file as NSString).lastPathComponent, !file.contains(".."),
                  let hash = entry["sha256"] as? String, let source = entry["sourceURL"] as? String,
                  let cameras = entry["cameraModels"] as? [String], let w = entry["width"] as? Int,
                  let h = entry["height"] as? Int, let fps = entry["fps"] as? Double else { throw VideoImportError.invalid("内置镜头配置清单无效") }
            let url = root.appendingPathComponent(file), raw = try Data(contentsOf: url)
            guard SHA256.hash(data: raw).map({ String(format: "%02x", $0) }).joined() == hash else { throw VideoImportError.invalid("内置镜头配置校验失败：" + title) }
            return LensCatalogEntry(id: id, title: title, url: url, sourceURL: source, cameraBrand: entry["cameraBrand"] as? String ?? "", cameraModels: cameras,
                lensModels: entry["lensModels"] as? [String] ?? [], width: w, height: h, fps: fps,
                focalLength: entry["focalLength"] as? Double, fixedFocalLength: entry["fixedFocalLength"] as? Bool ?? false,
                fixedLens: entry["fixedLens"] as? Bool ?? false, settings: entry["settings"] as? [String] ?? [], stabilizationModes: entry["stabilizationModes"] as? [String] ?? [], autoMatch: entry["autoMatch"] as? Bool ?? true)
        }
        cache.lock.lock(); cache.key = key; cache.value = result; cache.lock.unlock()
        return result
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
    public static func search(_ query: String, in entries: [LensCatalogEntry]) -> [LensCatalogEntry] {
        var text = query.lowercased()
        for (local,brand) in [("索尼","sony"),("佳能","canon"),("尼康","nikon"),("松下","panasonic"),("富士","fujifilm"),("大疆","dji"),("适马","sigma"),("腾龙","tamron")] { text = text.replacingOccurrences(of:local,with:brand) }
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map { normalized(String($0)) }.filter { !$0.isEmpty }
        return entries.filter { entry in
            let haystack = normalized(([entry.title,entry.cameraBrand]+entry.cameraModels+entry.lensModels+entry.settings).joined(separator:" "))
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }
    public static func match(_ metadata: CameraMetadata, width: Int, height: Int, fps: Double, root: URL? = nil) throws -> LensMatch {
        guard width > 0, height > 0 else { return LensMatch(metadata: metadata, candidates: [], message: "请先导入可读取尺寸的视频。") }
        guard !metadata.cameraModel.isEmpty else { return LensMatch(metadata: metadata, candidates: [], message: "未识别到相机型号，可选择内置组合或导入配置。") }
        if let w = metadata.width, let h = metadata.height, w != width || h != height { return LensMatch(metadata: metadata, candidates: [], message: "XML 与视频的尺寸不同，请检查是否为对应文件。") }
        let camera = normalized(metadata.cameraModel), lens = normalized(metadata.lensModel), mode = normalized(metadata.cameraSetting)
        var candidates: [LensCatalogEntry] = [], exact: [LensCatalogEntry] = []
        for entry in try entries(root: root) {
            if !metadata.cameraBrand.isEmpty, !entry.cameraBrand.isEmpty, !normalized(metadata.cameraBrand).hasPrefix(normalized(entry.cameraBrand)) { continue }
            guard entry.cameraModels.map(normalized).contains(camera),
                  abs((Double(width) / Double(height)) / (Double(entry.width) / Double(entry.height)) - 1) <= 0.002,
                  fps <= 0 || entry.fps <= 0 || abs(fps - entry.fps) / entry.fps <= 0.015 else { continue }
            let lenses = entry.lensModels.map(normalized)
            if !lens.isEmpty, !lenses.isEmpty, !lenses.contains(lens) { continue }
            if let focal = metadata.focalLength, let expected = entry.focalLength, abs(focal / expected - 1) > 0.015 { continue }
            candidates.append(entry)
            let lensMatches = (entry.fixedLens && lenses.isEmpty) || (!lens.isEmpty && lenses.contains(lens))
            let focalMatches = entry.focalLength == nil || entry.fixedFocalLength || (metadata.focalLength.map { abs($0 / entry.focalLength! - 1) <= 0.015 } ?? false)
            let modeMatches = (entry.settings.isEmpty && ["", "normal", "default", "fullframe"].contains(mode)) || (!mode.isEmpty && entry.settings.map(normalized).contains(mode))
            let stabilization = normalized(metadata.stabilizationMode)
            // Unspecified calibration settings cannot establish compatibility with a known EIS crop.
            let stabilizationMatches = entry.stabilizationModes.isEmpty ? ["", "off", "false", "0", "noeis"].contains(stabilization) : entry.stabilizationModes.map(normalized).contains(stabilization)
            if entry.autoMatch && lensMatches && focalMatches && modeMatches && stabilizationMatches && !metadata.variableFocalLength && fps > 0 && width == entry.width && height == entry.height { exact.append(entry) }
        }
        let selected = exact.count == 1 ? exact[0] : nil
        let message = selected.map { "已匹配 " + $0.title } ?? (candidates.isEmpty ? "没有精确匹配的内置组合，可导入配置或查看查找方法。" : "找到候选，请确认镜头和拍摄模式。")
        return LensMatch(metadata: metadata, candidates: candidates, selected: selected, message: message)
    }

    public static func detect(video: URL, width: Int, height: Int, fps: Double, embedded: CameraMetadata? = nil, root: URL? = nil) throws -> LensMatch {
        var metadata = embedded
        if metadata == nil, let report = try? TelemetryIO.read(video, probe: true, timeout: 30) {
            metadata = CameraMetadata.fromTelemetry(report)
        }
        return try match(CameraMetadata.forVideo(video).merging(metadata), width: width, height: height, fps: fps, root: root)
    }
    public static func importXML(_ url: URL, width: Int? = nil, height: Int? = nil, fps: Double? = nil, root: URL? = nil) throws -> LensMatch {
        let metadata = try CameraMetadata.readSonyXML(url)
        guard let w = width ?? metadata.width, let h = height ?? metadata.height else { return LensMatch(metadata: metadata, candidates: [], message: "已读取索尼机身与镜头信息；请导入对应视频后选择配置。") }
        return try match(metadata, width: w, height: h, fps: fps ?? metadata.fps ?? 0, root: root)
    }
}
