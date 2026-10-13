import Foundation
import CoreGraphics

/// Disk cache for proxies (downscaled JPEGs) and analysis results, keyed by sequence fingerprint.
public final class ProxyCache: @unchecked Sendable {
    public static let shared = ProxyCache()
    public let root: URL

    public init(root: URL? = nil) {
        if let root { self.root = root } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.root = base.appendingPathComponent("BirdLock", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public func directory(for fingerprint: String) -> URL {
        let d = root.appendingPathComponent(fingerprint, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    public func proxyURL(fingerprint: String, index: Int) -> URL {
        directory(for: fingerprint).appendingPathComponent(String(format: "p%05d.jpg", index))
    }

    public func loadProxy(fingerprint: String, index: Int) -> CGImage? {
        ImageLoader.load(proxyURL(fingerprint: fingerprint, index: index))
    }

    public func saveAnalysis(_ a: SequenceAnalysis) {
        let u = directory(for: a.fingerprint).appendingPathComponent("analysis.json")
        let enc = JSONEncoder()
        if let d = try? enc.encode(a) { try? d.write(to: u, options: .atomic) }
    }

    public func loadAnalysis(fingerprint: String) -> SequenceAnalysis? {
        let u = directory(for: fingerprint).appendingPathComponent("analysis.json")
        guard let d = try? Data(contentsOf: u), let a = try? JSONDecoder().decode(SequenceAnalysis.self, from: d),
              a.version == SequenceAnalysis.currentVersion else { return nil }
        // proxies must still exist
        let fm = FileManager.default
        for i in 0..<a.count where !fm.fileExists(atPath: proxyURL(fingerprint: fingerprint, index: i).path) { return nil }
        return a
    }

    /// Total size in bytes and removal helper
    public func totalSize() -> Int {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var s = 0
        for case let u as URL in e { s += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return s
    }

    public func clear() { try? FileManager.default.removeItem(at: root); try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
}
