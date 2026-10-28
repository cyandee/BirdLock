import AppKit
import Combine
import BirdLockCore
import Sparkle

/// Sparkle owns consent, scheduling, signature verification, delta fallback and installation.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    private var observation: NSKeyValueObservation?
    private var controller: SPUStandardUpdaterController!
    var isBusy: () -> Bool = { false }
    private var pendingInstall: (() -> Void)?
    private var timer: Timer?
    var configured: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme == "https" else { return false }
        return true
    }
    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            Task { @MainActor in self?.canCheck = change.newValue ?? false }
        }
    }
    func start() {
        Diagnostics.record("updater configured=\(configured)")
        if configured { controller.startUpdater() }
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
        controller.checkForUpdates(nil)
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
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        Diagnostics.record("update aborted domain=\(error.domain) code=\(error.code)")
    }
    nonisolated func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        (UserDefaults.standard.object(forKey: "updates.includeBeta") as? Bool ?? true) ? ["beta"] : []
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
