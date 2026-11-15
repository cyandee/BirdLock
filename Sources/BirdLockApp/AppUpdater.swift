import AppKit
import Combine
import BirdLockCore
import Sparkle
import os

/// Sparkle owns consent, scheduling, signature verification, delta fallback and installation.
/// BirdLock only picks which source relays the signed feed and archives.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var activeSource: UpdateSource?
    private var observation: NSKeyValueObservation?
    private var controller: SPUStandardUpdaterController!
    var isBusy: () -> Bool = { false }
    private var pendingInstall: (() -> Void)?
    private var timer: Timer?
    let sourceList: UpdateSourceList
    private var probe: Task<Void, Never>?
    // Read from Sparkle callbacks; until a probe finishes the first listed source is used.
    private nonisolated let selected: OSAllocatedUnfairLock<UpdateSource?>
    private nonisolated let githubFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    private nonisolated let releasePrefix = Bundle.main.object(forInfoDictionaryKey: "BirdLockReleaseDownloadPrefix") as? String
    var configured: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme == "https" else { return false }
        return true
    }
    override init() {
        let list = UpdateSourceList(store: .standard, info: Bundle.main.infoDictionary)
        sourceList = list
        selected = OSAllocatedUnfairLock(initialState: list.sources.first)
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            Task { @MainActor in self?.canCheck = change.newValue ?? false }
        }
    }
    func start() {
        Diagnostics.record("updater configured=\(configured) sources=\(sources.count) custom=\(sourceList.isCustom)")
        if configured { refreshSource();controller.startUpdater() }
    }
    func check() {
        Diagnostics.record("update check requested beta=\(includeBeta)")
        guard configured else {
            let a = NSAlert(); a.messageText = "此测试包尚未启用在线更新"
            a.informativeText = "请从 BirdLock 下载页安装新版。"
            a.addButton(withTitle: "打开下载页"); a.addButton(withTitle: "关闭")
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "https://github.com/cyandee/BirdLock/releases")!) }
            return
        }
        let probe = refreshSource()
        Task { await probe.value;self.controller.checkForUpdates(nil) }
    }
    var automatic: Bool {
        get { configured && controller.updater.automaticallyChecksForUpdates }
        set { if configured { controller.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() } }
    }
    var includeBeta: Bool {
        get { UserDefaults.standard.object(forKey: "updates.includeBeta") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "updates.includeBeta"); objectWillChange.send()
            if configured { controller.updater.resetUpdateCycleAfterShortDelay() }
        }
    }
    var sources: [UpdateSource] {
        get { sourceList.sources }
        set {
            sourceList.sources = newValue; objectWillChange.send()
            Diagnostics.record("update sources changed count=\(sourceList.sources.count) custom=\(sourceList.isCustom)")
            let first = sourceList.sources.first
            selected.withLock { $0 = first }
            if configured { refreshSource() }
        }
    }

    /// Probes every source at once and keeps the first one, in the user's order, whose feed and newest archive answer.
    @discardableResult func refreshSource() -> Task<Void, Never> {
        probe?.cancel()
        let sources = sourceList.sources, feed = githubFeed, prefix = releasePrefix
        let agent = "BirdLock/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") UpdateSourceProbe"
        let task = Task { [weak self] in
            let chosen = await UpdateSourceProbe.firstReachable(sources) {
                await UpdateSourceProbe.reachable($0, githubFeed: feed, releasePrefix: prefix, userAgent: agent)
            }
            guard !Task.isCancelled, let self else { return }
            let source = chosen ?? sources.first
            self.selected.withLock { $0 = source }
            self.activeSource = chosen
            Diagnostics.record("update source=\(chosen?.name ?? "none reachable")")
        }
        probe = task
        return task
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        Diagnostics.record("update aborted domain=\(error.domain) code=\(error.code)")
        Task { @MainActor in if self.configured { self.refreshSource() } }
    }
    nonisolated func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        (UserDefaults.standard.object(forKey: "updates.includeBeta") as? Bool ?? true) ? ["beta"] : []
    }
    @objc(feedURLStringForUpdater:)
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        selected.withLock { $0 }?.feedURL(githubFeed: githubFeed)
    }
    @objc(updater:willScheduleUpdateCheckAfterDelay:)
    nonisolated func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        Task { @MainActor in self.refreshSource() }
    }
    /// The signed feed names GitHub release URLs; the archive signature makes any relaying source equivalent.
    @objc(updater:willDownloadUpdate:withRequest:)
    nonisolated func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        guard let source = selected.withLock({ $0 }), let url = request.url,
              let mapped = source.assetURL(url, releasePrefix: releasePrefix), mapped != url else { return }
        request.url = mapped
        Diagnostics.record("update download source=\(source.name)")
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if isBusy() { throw NSError(domain: "BirdLock.Update", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "正在分析或导出，请完成后再检查更新。"]) }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        pendingInstall = installHandler
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isBusy() else { return }
                self.timer?.invalidate(); self.timer = nil
                let install = self.pendingInstall; self.pendingInstall = nil; install?()
            }
        }
        return true
    }
}
