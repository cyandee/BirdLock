import Foundation
import CoreGraphics

/// Disk cache for proxies (downscaled JPEGs) and analysis results, keyed by sequence fingerprint.
public final class ProxyCache: @unchecked Sendable {
    public static let shared = ProxyCache()
    public let root: URL
    private let recordsLock=NSLock()
    private var records:[String:SequenceAnalysis]=[:]
    public var rememberedAnalyses: [SequenceAnalysis] {
        recordsLock.lock();defer { recordsLock.unlock() };return Array(records.values)
    }

    public func retainRecords(frames:[SourceFrame]) {
        let allowed=Set(frames.map(\.url))
        recordsLock.lock();records=records.filter { $0.value.frames.allSatisfy { allowed.contains($0.url) } };recordsLock.unlock()
    }

    public init(root: URL? = nil) {
        if let root { self.root = root }
        else if let path = ProcessInfo.processInfo.environment["BIRDLOCK_CACHE"] {
            self.root = URL(fileURLWithPath: path, isDirectory: true)
        } else {
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
        let url=proxyURL(fingerprint:fingerprint,index:index)
        if let image=ImageLoader.load(url) { return image }
        recordsLock.lock();let remembered=records[fingerprint];recordsLock.unlock()
        guard let analysis=remembered ?? loadAnalysis(fingerprint:fingerprint),analysis.frames.indices.contains(index),
              let image=ImageLoader.load(analysis.frames[index].url,maxPixel:analysis.proxyLongSide) else { return nil }
        let temporary=url.deletingLastPathComponent().appendingPathComponent(".proxy-"+UUID().uuidString+".jpg")
        if ImageLoader.writeJPEG(image,to:temporary,quality:0.95) {
            if let data=try? Data(contentsOf:temporary) { try? data.write(to:url,options:.atomic) }
            try? FileManager.default.removeItem(at:temporary)
        }
        return image
    }

    public func saveAnalysis(_ a: SequenceAnalysis) {
        recordsLock.lock();records[a.fingerprint]=a;recordsLock.unlock()
        let u = directory(for: a.fingerprint).appendingPathComponent("analysis.json")
        let enc = JSONEncoder()
        var raw=a;raw.track=nil
        if let d = try? enc.encode(raw) { try? d.write(to: u, options: .atomic) }
    }

    public func loadAnalysis(fingerprint: String) -> SequenceAnalysis? {
        let u = directory(for: fingerprint).appendingPathComponent("analysis.json")
        guard let d = try? Data(contentsOf: u), let a = try? JSONDecoder().decode(SequenceAnalysis.self, from: d),
              a.version == SequenceAnalysis.currentVersion else { return nil }
        let fm=FileManager.default
        for i in a.frames.indices where !fm.fileExists(atPath:proxyURL(fingerprint:fingerprint,index:i).path) {
            guard (try? a.frames[i].url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true else { return nil }
        }
        recordsLock.lock();records[fingerprint]=a;recordsLock.unlock()
        try? FileManager.default.setAttributes([.modificationDate:Date()],ofItemAtPath:u.path)
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
