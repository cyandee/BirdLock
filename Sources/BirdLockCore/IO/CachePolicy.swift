import Foundation

public struct CacheCleanup: Sendable {
    public var before: Int
    public var after: Int
    public var removed: Int
    public var failures: Int
    public var overLimit: Bool
}
/// Only known, reproducible JPEG/PCM files are eligible. Documents and edit/IMU JSON are retained.
public enum CachePolicy {
    private struct Group { var root:URL;var files:[URL];var stamp:Date;var parents:Set<String> }
    private static let fm=FileManager.default
    private static let gate=NSRecursiveLock()
    private static var active:[String:Set<String>]=[:]
    private static var operations:[String:String]=[:]
    private static func canonical(_ path:String) -> String { URL(fileURLWithPath:path).resolvingSymlinksInPath().standardizedFileURL.path }
    public static func protect(owner:String,roots:Set<String>) {
        gate.lock();defer { gate.unlock() }
        if roots.isEmpty { active[owner]=nil } else { active[owner]=Set(roots.map(canonical)) }
    }
    public static func beginOperation(root:URL) -> String {
        gate.lock();defer { gate.unlock() };let token=UUID().uuidString;operations[token]=canonical(root.path);return token
    }
    public static func endOperation(_ token:String) { gate.lock();operations[token]=nil;gate.unlock() }

    private static func regular(_ url:URL) -> Bool {
        guard let info=try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]) else { return false }
        return info.isRegularFile==true && info.isSymbolicLink != true
    }
    public static func totalSize(_ root:URL) -> Int {
        guard let items=fm.enumerator(at:root,includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsPackageDescendants]) else { return 0 }
        var total=0
        for case let url as URL in items { if regular(url) { total += (try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0 } }
        return total
    }
    private static func matches(_ string:String,_ expression:String) -> Bool { string.range(of:expression,options:.regularExpression) != nil }
    private static func groups(_ root:URL) -> [Group] {
        var result:[Group]=[]
        for directory in (try? fm.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isSymbolicLinkKey])) ?? [] {
            if (try? directory.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink)==true { continue }
            if directory.lastPathComponent=="video-imports" {
                for video in (try? fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isSymbolicLinkKey])) ?? [] {
                    guard matches(video.lastPathComponent,"^[a-f0-9]{32}$"),(try? video.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true,
                          let raw=try? Data(contentsOf:video.appendingPathComponent("video-recipe.json")),let recipe=try? JSONDecoder().decode(VideoRecipe.self,from:raw),
                          (try? URL(fileURLWithPath:recipe.sourcePath).resourceValues(forKeys:[.fileSizeKey]).fileSize)==recipe.bytes else { continue }
                    let files=((try? fm.contentsOfDirectory(at:video,includingPropertiesForKeys:nil)) ?? []).filter { regular($0) && matches($0.lastPathComponent,"^(video-[0-9]{6}\\.jpg|original-audio\\.wav)$") }
                    let stamp=(try? video.appendingPathComponent("video-recipe.json").resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    result.append(Group(root:video,files:files,stamp:stamp,parents:[video.path]))
                }
            } else if matches(directory.lastPathComponent,"^[a-f0-9]{24}$"),
                      let data=try? Data(contentsOf:directory.appendingPathComponent("analysis.json")),let a=try? JSONDecoder().decode(SequenceAnalysis.self,from:data) {
                let available=a.frames.allSatisfy { frame in
                    if fm.fileExists(atPath:frame.url.path) { return true }
                    let parent=frame.url.deletingLastPathComponent()
                    guard let raw=try? Data(contentsOf:parent.appendingPathComponent("video-recipe.json")),let recipe=try? JSONDecoder().decode(VideoRecipe.self,from:raw) else { return false }
                    return fm.fileExists(atPath:recipe.sourcePath)
                }
                if available {
                    let files=((try? fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []).filter { regular($0) && matches($0.lastPathComponent,"^p[0-9]{5,}\\.jpg$") }
                    let stamp=(try? directory.appendingPathComponent("analysis.json").resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    result.append(Group(root:directory,files:files,stamp:stamp,parents:Set(a.frames.map { $0.url.deletingLastPathComponent().path })))
                }
            } else if directory.lastPathComponent=="video-audio" {
                for file in (try? fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [] where regular(file) && matches(file.lastPathComponent,"^[a-f0-9]{24,64}\\.wav$") {
                    result.append(Group(root:directory,files:[file],stamp:(try? file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast,parents:[]))
                }
            }
        }
        return result.sorted { $0.stamp < $1.stamp }
    }
    public static func clean(root:URL,limitBytes:Int=0,protected:Set<String>=[],onlyVideos:Set<String>?=nil) -> CacheCleanup {
        gate.lock();defer { gate.unlock() }
        let protected=Set(protected.map(canonical)).union(active.values.reduce(into:Set<String>()) { $0.formUnion($1) }),onlyVideos=onlyVideos.map { Set($0.map(canonical)) }
        let before=totalSize(root);var remaining=before,removed=0,failures=0
        if operations.values.contains(canonical(root.path)) || (onlyVideos == nil && before<=limitBytes) { return CacheCleanup(before:before,after:before,removed:0,failures:0,overLimit:before>limitBytes) }
        for group in groups(root) {
            if onlyVideos == nil && remaining<=limitBytes { break }
            if protected.contains(canonical(group.root.path)) || !Set(group.parents.map(canonical)).isDisjoint(with:protected) { continue }
            if let onlyVideos,group.root.lastPathComponent != "video-audio",Set(group.parents.map(canonical)).isDisjoint(with:onlyVideos) { continue }
            if group.root.deletingLastPathComponent().lastPathComponent=="video-imports" && !group.files.isEmpty {
                do { try Data("{\"schema\":1}".utf8).write(to:group.root.appendingPathComponent(".evicted.json"),options:.atomic) }
                catch { failures+=1;continue }
            }
            for file in group.files {
                do { let size=(try file.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0;try fm.removeItem(at:file);remaining-=size;removed+=size }
                catch { failures+=1 }
            }
        }
        let after=totalSize(root)
        return CacheCleanup(before:before,after:after,removed:removed,failures:failures,overLimit:onlyVideos == nil && after>limitBytes)
    }
}
