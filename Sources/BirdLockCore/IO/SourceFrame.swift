import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ExifInfo: Codable, Hashable, Sendable {
    public var make: String?
    public var model: String?
    public var lens: String?
    public var focalLength: Double?
    public var exposureTime: Double?
    public var fNumber: Double?
    public var iso: Int?
    public var dateTimeOriginal: String?

    public var cameraName: String? {
        guard let model else { return make }
        if let make, !model.lowercased().hasPrefix(make.lowercased().split(separator: " ").first.map(String.init) ?? "") {
            return "\(make) \(model)"
        }
        return model
    }

    public var shutterText: String? {
        guard let t = exposureTime, t > 0 else { return nil }
        if t >= 0.5 { return String(format: "%.1fs", t) }
        return "1/\(Int((1 / t).rounded()))s"
    }

    /// e.g. "800mm  1/1600s  f/8  ISO 1000"
    public var exposureLine: String {
        var parts: [String] = []
        if let f = focalLength { parts.append("\(Int(f.rounded()))mm") }
        if let s = shutterText { parts.append(s) }
        if let n = fNumber { parts.append(n.truncatingRemainder(dividingBy: 1) == 0 ? "f/\(Int(n))" : String(format: "f/%.1f", n)) }
        if let iso { parts.append("ISO \(iso)") }
        return parts.joined(separator: "  ")
    }
}

public struct SourceFrame: Codable, Hashable, Identifiable, Sendable {
    public var id: Int            // index in the imported, time-sorted sequence
    public var url: URL
    public var pixelWidth: Int    // oriented (display) size
    public var pixelHeight: Int
    public var captureTime: Double?   // seconds since reference date, incl. sub-seconds
    public var fileSize: Int
    public var modified: Double
    public var exif: ExifInfo

    public var fileName: String { url.lastPathComponent }
    public var size: V2 { V2(Double(pixelWidth), Double(pixelHeight)) }
}

public struct BurstSegment: Hashable, Sendable {
    public var range: Range<Int>
    public var fps: Double
}

public enum FrameImporter {
    public static let supportedExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "hif", "png", "tif", "tiff"]

    /// Expand dropped URLs (files or folders, non-recursive into sub-folders) to image files.
    public static func collectImageURLs(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                out += items.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            } else if supportedExtensions.contains(u.pathExtension.lowercased()) {
                out.append(u)
            }
        }
        return out
    }

    public static func readFrame(url: URL, id: Int) -> SourceFrame? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        var w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        var h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        if orientation >= 5 { swap(&w, &h) }
        guard w > 0, h > 0 else { return nil }

        let exifD = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiffD = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let auxD = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        var exif = ExifInfo()
        exif.make = (tiffD[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        exif.model = (tiffD[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        exif.lens = (exifD[kCGImagePropertyExifLensModel] as? String) ?? (auxD[kCGImagePropertyExifAuxLensModel] as? String)
        exif.focalLength = exifD[kCGImagePropertyExifFocalLength] as? Double
        exif.exposureTime = exifD[kCGImagePropertyExifExposureTime] as? Double
        exif.fNumber = exifD[kCGImagePropertyExifFNumber] as? Double
        if let isos = exifD[kCGImagePropertyExifISOSpeedRatings] as? [Int] { exif.iso = isos.first }
        exif.dateTimeOriginal = exifD[kCGImagePropertyExifDateTimeOriginal] as? String

        var t: Double? = nil
        if let dto = exif.dateTimeOriginal ?? (tiffD[kCGImagePropertyTIFFDateTime] as? String) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let d = f.date(from: dto) {
                t = d.timeIntervalSinceReferenceDate
                if let sub = (exifD[kCGImagePropertyExifSubsecTimeOriginal] as? String) ?? (exifD[kCGImagePropertyExifSubsecTime] as? String) {
                    let digits = sub.trimmingCharacters(in: .whitespaces)
                    if let v = Double("0." + digits) { t! += v }
                }
            }
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let mod = (attrs?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return SourceFrame(id: id, url: url, pixelWidth: w, pixelHeight: h, captureTime: t,
                           fileSize: size, modified: mod, exif: exif)
    }

    /// Read metadata for all files (in parallel), sort by capture time then file name.
    public static func importFrames(_ urls: [URL]) -> [SourceFrame] {
        let files = collectImageURLs(urls)
        var frames = [SourceFrame?](repeating: nil, count: files.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let f = readFrame(url: files[i], id: i)
            lock.lock(); frames[i] = f; lock.unlock()
        }
        var list = frames.compactMap { $0 }
        list.sort { a, b in
            if let ta = a.captureTime, let tb = b.captureTime, abs(ta - tb) > 1e-4 { return ta < tb }
            return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
        }
        for i in list.indices { list[i].id = i }
        return list
    }

    /// Estimate the burst frame rate from capture timestamps (defaults to 30).
    public static func estimateFPS(_ frames: [SourceFrame]) -> Double {
        let t = frames.compactMap { $0.captureTime }
        guard t.count >= 3 else { return 30 }
        var dts: [Double] = []
        for i in 1..<t.count { let d = t[i] - t[i - 1]; if d > 0.001 && d < 1 { dts.append(d) } }
        guard let m = Stats.median(dts), m > 0 else { return 30 }
        let fps = 1 / m
        // snap to common burst rates
        for c in [10.0, 12, 15, 20, 24, 25, 30, 40, 50, 60, 120] where abs(fps - c) / c < 0.08 { return c }
        return fps
    }

    /// Split into bursts where the time gap is much larger than the typical frame interval.
    public static func segments(_ frames: [SourceFrame]) -> [BurstSegment] {
        guard !frames.isEmpty else { return [] }
        let fps = estimateFPS(frames)
        let gap = max(0.5, 6.0 / fps)
        var segs: [BurstSegment] = []
        var start = 0
        for i in 1..<max(1, frames.count) where i < frames.count {
            if let a = frames[i - 1].captureTime, let b = frames[i].captureTime, b - a > gap {
                segs.append(BurstSegment(range: start..<i, fps: estimateFPS(Array(frames[start..<i])))); start = i
            }
        }
        segs.append(BurstSegment(range: start..<frames.count, fps: estimateFPS(Array(frames[start..<frames.count]))))
        return segs
    }
}
