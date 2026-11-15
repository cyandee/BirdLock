import Foundation

/// A source relays byte-identical copies of the signed feeds at `<base>/macos.xml` and of GitHub release assets at
/// `<base>/download/<tag>/<name>`. Sparkle verifies the feed and archive signatures, so the host never affects trust.
/// The built-in GitHub source keeps the configured feed and the URLs written in the signed feed.
public struct UpdateSource: Codable, Hashable, Sendable {
    public static let githubID = "github"
    public static let github = UpdateSource(id: githubID, name: "GitHub", url: nil)
    public var id: String?
    public var name: String
    public var url: String?
    public init(id: String? = nil, name: String, url: String?) { self.id=id;self.name=name;self.url=url }
    public var isGitHub: Bool { id == Self.githubID }

    public enum Invalid: LocalizedError {
        case url
        public var errorDescription: String? { "更新源必须是 HTTPS 地址，且不能带账号、查询参数或 #" }
    }
    /// Normalizes a base URL to lowercase host and a trailing slash.
    public static func base(_ value: String) throws -> String {
        guard var c = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              host.lowercased().range(of: #"^([a-z0-9.-]+|\[?[0-9a-f:.]+\]?)$"#, options: .regularExpression) != nil,
              c.port.map({ (1...65535).contains($0) }) ?? true else { throw Invalid.url }
        c.scheme = "https";c.host = host.lowercased()
        if !c.percentEncodedPath.hasSuffix("/") { c.percentEncodedPath += "/" }
        guard let s = c.string, URL(string: s) != nil else { throw Invalid.url }
        return s
    }
    public static func custom(_ value: String) throws -> UpdateSource {
        let url = try base(value)
        return UpdateSource(name: URL(string: url)?.host ?? url, url: url)
    }
    /// Feed for this source; the GitHub source returns `githubFeed`.
    public func feedURL(githubFeed: String?) -> String? { isGitHub ? githubFeed : url.map { $0 + "macos.xml" } }
    /// Maps a signed GitHub release URL onto this source. Other URLs are left alone.
    public func assetURL(_ canonical: URL, releasePrefix: String?) -> URL? {
        guard !isGitHub else { return canonical }
        guard let base = url, let prefix = releasePrefix, !prefix.isEmpty,
              canonical.absoluteString.hasPrefix(prefix) else { return nil }
        return URL(string: base + "download/" + String(canonical.absoluteString.dropFirst(prefix.count)))
    }
}

/// Ordered source list. Saving the shipped defaults clears the override so later versions can update them.
public final class UpdateSourceList {
    public static let maximum = 10
    static let key = "updates.sources"
    public let defaults: [UpdateSource]
    private let store: UserDefaults
    public init(store: UserDefaults, defaults: [UpdateSource]) {
        self.store=store
        let cleaned = Self.clean(defaults);self.defaults = cleaned.isEmpty ? [.github] : cleaned
    }
    /// Reads `BirdLockUpdateSources` entries written by `scripts/stage_updater.py`.
    public convenience init(store: UserDefaults, info: [String: Any]?) {
        let items = (info?["BirdLockUpdateSources"] as? [[String: String]] ?? []).map {
            UpdateSource(id: $0["id"], name: $0["name"] ?? "", url: $0["url"])
        }
        self.init(store: store, defaults: items)
    }
    public static func clean(_ items: [UpdateSource]) -> [UpdateSource] {
        var result: [UpdateSource] = []
        for item in items {
            var s: UpdateSource
            if item.isGitHub { s = UpdateSource(id: UpdateSource.githubID, name: item.name.isEmpty ? "GitHub" : item.name, url: nil) }
            else {
                guard let raw = item.url, let url = try? UpdateSource.base(raw) else { continue }
                s = UpdateSource(name: item.name.isEmpty ? (URL(string: url)?.host ?? url) : item.name, url: url)
            }
            if !result.contains(where: { $0.id == s.id && $0.url == s.url }) { result.append(s) }
        }
        return Array(result.prefix(maximum))
    }
    public var isCustom: Bool { store.data(forKey: Self.key) != nil }
    public var sources: [UpdateSource] {
        get {
            guard let data = store.data(forKey: Self.key),
                  let saved = try? JSONDecoder().decode([UpdateSource].self, from: data) else { return defaults }
            let cleaned = Self.clean(saved);return cleaned.isEmpty ? defaults : cleaned
        }
        set {
            let cleaned = Self.clean(newValue)
            if cleaned.isEmpty || cleaned == defaults { store.removeObject(forKey: Self.key) }
            else if let data = try? JSONEncoder().encode(cleaned) { store.set(data, forKey: Self.key) }
        }
    }
}
