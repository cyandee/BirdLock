import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import AVFoundation

/// Camera identity only. Sony sidecars generally do not contain an optical calibration or IMU samples.
public struct CameraMetadata: Codable, Hashable, Sendable {
    public var cameraBrand = ""
    public var cameraModel = ""
    public var lensModel = ""
    public var focalLength: Double?
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    public var captureFPS: Double?
    public var cameraSetting = ""
    public var stabilizationMode = ""
    public var variableFocalLength = false
    public var source = ""

    public init(cameraBrand: String = "", cameraModel: String = "", lensModel: String = "", focalLength: Double? = nil,
                width: Int? = nil, height: Int? = nil, fps: Double? = nil, captureFPS: Double? = nil,
                cameraSetting: String = "", stabilizationMode: String = "", variableFocalLength: Bool = false, source: String = "") {
        self.cameraBrand = cameraBrand; self.cameraModel = cameraModel; self.lensModel = lensModel
        self.focalLength = focalLength; self.width = width; self.height = height; self.fps = fps; self.captureFPS = captureFPS
        self.cameraSetting = cameraSetting; self.stabilizationMode = stabilizationMode
        self.variableFocalLength = variableFocalLength; self.source = source
    }
    public var displayName: String { [cameraModel, lensModel].filter { !$0.isEmpty }.joined(separator: " · ") }

    public static func fromTelemetry(_ report: TelemetryReport) -> CameraMetadata {
        var result = CameraMetadata(cameraBrand: report.cameraBrand, cameraModel: report.cameraModel ?? "", source: "embedded-telemetry")
        if let rate = report.video?["fps"]?.number, rate.isFinite, rate > 0 { result.fps = rate }
        var lenses = Set<String>(), modes = Set<String>(), focals: [Double] = []
        let fov = ["W":"Wide", "S":"Superview", "H":"Hyperview", "L":"Linear", "N":"Narrow", "M":"Medium", "X":"Max SuperView"]
        for frame in report.rawMetadataFrames {
            let name = frame["Lens"]?["DisplayName"]?.string ?? frame["Lens"]?["Data"]?["lens_model"]?.string ?? ""
            if !name.trimmingCharacters(in: .whitespaces).isEmpty { lenses.insert(String(name.trimmingCharacters(in: .whitespaces).prefix(512))) }
            if let focal = frame["Lens"]?["FocalLength"]?.number, focal.isFinite, focal > 0 { focals.append(focal) }
            if report.cameraBrand.lowercased() == "gopro" {
                let value = frame["Default"]?["0x56464f56"]?.string ?? frame["Default"]?["VFOV"]?.string ?? ""
                if let name = fov[value] { lenses.insert(name) }
                let eis = frame["Default"]?["0x45495341"]?.string ?? frame["Default"]?["EISA"]?.string
                if eis == "N" { modes.insert("off") }; if eis == "Y" { modes.insert("on") }
            }
        }
        if lenses.count == 1 { result.lensModel = lenses.first! }
        else if lenses.count > 1 { result.cameraSetting = "mixed-modes" }
        if modes.count == 1 { result.stabilizationMode = modes.first! }
        else if modes.count > 1 { result.stabilizationMode = "mixed" }
        if let low = focals.min(), let high = focals.max() {
            result.variableFocalLength = high > low * 1.002
            if !result.variableFocalLength { result.focalLength = focals.first }
        }
        return result
    }

    public func merging(_ preferred: CameraMetadata?) -> CameraMetadata {
        guard let p = preferred else { return self }
        var r = self
        if !p.cameraBrand.isEmpty { r.cameraBrand = p.cameraBrand }; if !p.cameraModel.isEmpty { r.cameraModel = p.cameraModel }
        if !p.lensModel.isEmpty { r.lensModel = p.lensModel }; if !p.cameraSetting.isEmpty { r.cameraSetting = p.cameraSetting }
        if !p.stabilizationMode.isEmpty { r.stabilizationMode = p.stabilizationMode }; if !p.source.isEmpty { r.source = p.source }
        r.focalLength = p.focalLength ?? focalLength; r.width = p.width ?? width; r.height = p.height ?? height
        r.fps = p.fps ?? fps; r.captureFPS = p.captureFPS ?? captureFPS
        r.variableFocalLength = variableFocalLength || p.variableFocalLength
        return r
    }

    public static func sonySidecar(for video: URL) -> URL? {
        let names = [video.deletingPathExtension().lastPathComponent + "M01.XML", video.deletingPathExtension().lastPathComponent + ".XML"].map { $0.lowercased() }
        let files = (try? FileManager.default.contentsOfDirectory(at: video.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return names.lazy.compactMap { name in files.first { $0.lastPathComponent.lowercased() == name } }.first
    }

    public static func readSonyXML(_ url: URL) throws -> CameraMetadata {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 2_097_152 else { throw VideoImportError.invalid("索尼 XML 文件过大（上限 2 MB）") }
        return try parseSonyXML(Data(contentsOf: url))
    }

    public static func parseSonyXML(_ data: Data, source: String = "sony-xml") throws -> CameraMetadata {
        guard data.count <= 2_097_152 else { throw VideoImportError.invalid("索尼 XML 文件过大（上限 2 MB）") }
        let content = (String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? "").uppercased()
        guard !content.contains("<!DOCTYPE"), !content.contains("<!ENTITY") else { throw VideoImportError.invalid("XML 不支持 DTD 或外部实体") }
        let delegate = SonyXMLReader(source: source), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.rootName == "NonRealTimeMeta" else { throw VideoImportError.invalid("无法读取索尼 XML，请选择相机生成的原始 XML 文件") }
        var result = delegate.value
        guard result.cameraBrand.isEmpty || result.cameraBrand.lowercased().contains("sony") else { throw VideoImportError.invalid("XML 的相机制造商不是 Sony") }
        guard !result.cameraModel.isEmpty else { throw VideoImportError.invalid("索尼 XML 中没有相机型号") }
        if result.cameraBrand.isEmpty { result.cameraBrand = "Sony" }
        if let low = delegate.focalLengths.min(), let high = delegate.focalLengths.max() {
            result.variableFocalLength = high > low * 1.002
            if !result.variableFocalLength { result.focalLength = delegate.focalLengths.first }
        }
        return result
    }

    public static func forVideo(_ video: URL) throws -> CameraMetadata {
        if let sidecar = sonySidecar(for: video) { return try readSonyXML(sidecar) }
        // Sony embeds the same complete XML document in an MP4 metadata box. Bound reads for large originals.
        if let file = try? FileHandle(forReadingFrom: video) {
            defer { try? file.close() }
            let size = (try? file.seekToEnd()) ?? 0
            try? file.seek(toOffset: 0)
            var chunks = [try file.read(upToCount: Int(min(size, 8_388_608))) ?? Data()]
            if size > 8_388_608 {
                try file.seek(toOffset: max(8_388_608, size - 8_388_608))
                chunks.append(try file.read(upToCount: 8_388_608) ?? Data())
            }
            let startTag = Data("<NonRealTimeMeta".utf8), endTag = Data("</NonRealTimeMeta>".utf8)
            for data in chunks {
                if let start = data.range(of: startTag), let end = data.range(of: endTag, in: start.lowerBound..<data.endIndex) {
                    return try parseSonyXML(data.subdata(in: start.lowerBound..<end.upperBound), source: "embedded-sony-xml")
                }
            }
        }
        let asset = AVURLAsset(url: video)
        return (try? awaitSync {
            let items = try await asset.load(.commonMetadata)
            var result = CameraMetadata(source: "embedded-tags")
            for item in items {
                let key = (item.commonKey?.rawValue ?? item.identifier?.rawValue ?? "").lowercased()
                guard let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
                if key.contains("lens") { result.lensModel = String(value.prefix(512)) }
                else if key.contains("model") { result.cameraModel = String(value.prefix(256)) }
                else if key.contains("make") { result.cameraBrand = String(value.prefix(256)) }
            }
            return result
        }) ?? CameraMetadata()
    }
}

private final class SonyXMLReader: NSObject, XMLParserDelegate {
    var value: CameraMetadata
    var rootName: String?
    var focalLengths: [Double] = []
    init(source: String) { value = CameraMetadata(source: source) }

    private func number(_ text: String?) -> Double? {
        guard let text, let range = text.range(of: #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#, options: .regularExpression),
              let result = Double(text[range]), result.isFinite, result > 0 else { return nil }
        return result
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String]) {
        if rootName == nil { rootName = name }
        switch name {
        case "Device": value.cameraBrand = String((a["manufacturer"] ?? "").prefix(256)); value.cameraModel = String((a["modelName"] ?? "").prefix(256))
        case "Lens":
            value.lensModel = String((a["modelName"] ?? "").prefix(512))
            if let n = number(a["focalLength"]) { focalLengths.append(n) }
        case "VideoLayout":
            if let w = number(a["pixel"]), let h = number(a["numOfVerticalLine"]), w <= 32768, h <= 32768 { value.width = Int(w); value.height = Int(h) }
        case "VideoFrame": value.fps = number(a["formatFps"]); value.captureFPS = number(a["captureFps"])
        case "Item":
            let key = (a["name"] ?? "").lowercased(), text = a["value"] ?? ""
            if ["lensmodel", "lensname", "lensmodelname"].contains(key), value.lensModel.isEmpty { value.lensModel = String(text.prefix(512)) }
            if ["focallength", "focallengthmm"].contains(key), let n = number(text) { focalLengths.append(n) }
            if ["shootingmode", "sensorcropmode", "videocapturemode"].contains(key) { value.cameraSetting = String(text.prefix(256)) }
            if ["imagestabilizer", "steadyshot", "stabilizationmode"].contains(key) { value.stabilizationMode = String(text.prefix(256)) }
        default: break
        }
    }
}
