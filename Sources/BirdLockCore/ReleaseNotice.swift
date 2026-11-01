import Foundation

/// Old installations predate the version marker. Existing accepted settings identify returning users,
/// while an empty installation is seeded silently. A pending notice survives an interrupted launch.
public final class ReleaseNotice {
    private let defaults: UserDefaults
    private let current: String
    private let legacy: Bool
    public init(defaults: UserDefaults, current: String) {
        self.defaults=defaults;self.current=current
        legacy = !(defaults.string(forKey:"agreement.accepted") ?? "").isEmpty
    }
    private func version(_ value:String) -> [Int]? {
        let parts=value.split(separator:".");guard parts.count==3 else { return nil }
        let numbers=parts.compactMap { Int($0) };return numbers.count==3 ? numbers : nil
    }
    @discardableResult public func start() -> Bool {
        guard let now=version(current) else { return false }
        let previous=defaults.string(forKey:"updates.lastStartedVersion")
        let newer=previous.flatMap(version).map { $0.lexicographicallyPrecedes(now) } ?? (previous == nil && legacy)
        if newer,defaults.string(forKey:"updates.notesSeenVersion") != current { defaults.set(current,forKey:"updates.pendingNotesVersion") }
        defaults.set(current,forKey:"updates.lastStartedVersion")
        return defaults.string(forKey:"updates.pendingNotesVersion")==current && defaults.string(forKey:"updates.notesSeenVersion") != current
    }
    public func acknowledge() {
        defaults.set(current,forKey:"updates.notesSeenVersion");defaults.removeObject(forKey:"updates.pendingNotesVersion")
    }
}
