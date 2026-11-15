import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Picks which source relays the Mac feed. It never decides trust: Sparkle verifies whatever it downloads.
public enum UpdateSourceProbe {
    /// Runs every check at once and returns the first source, in list order, whose check passes.
    public static func firstReachable(_ sources: [UpdateSource], check: @escaping @Sendable (UpdateSource) async -> Bool) async -> UpdateSource? {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for (i, source) in sources.enumerated() { group.addTask { (i, await check(source)) } }
            var known: [Int: Bool] = [:]
            for await (i, ok) in group {
                known[i] = ok
                for j in sources.indices {
                    guard let result = known[j] else { break }
                    if result { group.cancelAll(); return sources[j] }
                }
            }
            return nil
        }
    }
    /// The feed must answer with a signed appcast and its first archive must answer a HEAD request on the same source.
    public static func reachable(_ source: UpdateSource, githubFeed: String?, releasePrefix: String?, userAgent: String,
                                 session: URLSession = .shared, timeout: TimeInterval = 10) async -> Bool {
        func request(_ url: URL, _ method: String) -> URLRequest {
            var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            r.httpMethod = method;r.setValue(userAgent, forHTTPHeaderField: "User-Agent");return r
        }
        func answered(_ response: URLResponse) -> Bool {
            (response as? HTTPURLResponse)?.statusCode == 200 && response.url?.scheme == "https"
        }
        guard let feed = source.feedURL(githubFeed: githubFeed).flatMap(URL.init(string:)),
              let reply = try? await session.data(for: request(feed, "GET")), answered(reply.1),
              let text = String(data: reply.0, encoding: .utf8), text.contains("sparkle-signatures"),
              let enclosure = firstEnclosure(text),
              let asset = source.assetURL(enclosure, releasePrefix: releasePrefix),
              let head = try? await session.data(for: request(asset, "HEAD")) else { return false }
        return answered(head.1)
    }
    static func firstEnclosure(_ appcast: String) -> URL? {
        guard let pattern = try? NSRegularExpression(pattern: #"<enclosure\b[^>]*\burl="([^"]+)""#),
              let match = pattern.firstMatch(in: appcast, range: NSRange(appcast.startIndex..., in: appcast)),
              let range = Range(match.range(at: 1), in: appcast) else { return nil }
        return URL(string: appcast[range].replacingOccurrences(of: "&amp;", with: "&"))
    }
}
