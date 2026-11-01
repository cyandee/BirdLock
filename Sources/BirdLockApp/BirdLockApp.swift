import SwiftUI
import AppKit
import BirdLockCore

@main
struct BirdLockApp: App {
    init() { Diagnostics.start() }
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var state = AppState()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        // A single window: opening folders from Finder imports into it instead of spawning windows that share state
        Window("BirdLock 鸟眼锁定", id: "main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 1100, minHeight: 720)
                .onAppear {
                    updater.isBusy = { state.exportState.running || state.phase == .importing || { if case .analyzing = state.phase { return true }; return false }() }
                    updater.start()
                    AppDelegate.terminationCheck={ state.projectCloseApproved || state.confirmCanLeave() }
                    AppDelegate.terminationCleanup={ CachePolicy.protect(owner:state.cacheOwner,roots:[]);if state.cacheLimitGB>0 { _ = CachePolicy.clean(root:ProxyCache.shared.root,limitBytes:state.cacheLimitGB*(1<<30)) } }
                }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 BirdLock 鸟眼锁定") { AppDocs.showAbout() }
                Button("检查更新…") { updater.check() }
                    .disabled(updater.configured && !updater.canCheck)
                Toggle("自动检查更新", isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 }))
                    .disabled(!updater.configured)
                Toggle("接收测试版更新", isOn: Binding(get: { updater.includeBeta }, set: { updater.includeBeta = $0 }))
                Divider()
                Button("用户协议…") { LegalWindow.show(.agreement) }
                Button("许可与第三方组件…") { LegalWindow.show(.notices) }
            }
            CommandGroup(replacing: .help) {
                Button("本次更新说明…") { state.showReleaseNotes=true }
                Button("BirdLock 使用说明") { AppDocs.openManual() }
                Button("反馈与交流（邮箱）") { AppIdentity.showContact() }
                Button("打开日志文件夹…") { NSWorkspace.shared.open(Diagnostics.directory) }
                Button("导出诊断日志…") { AppIdentity.exportDiagnostics() }
            }
            CommandMenu("赞赏") {
                Button("请作者喝杯咖啡…") { AppIdentity.showSupport() }
            }
            CommandGroup(replacing: .newItem) {
                Button("打开工程…") { state.openProjectPanel() }.keyboardShortcut("o")
                Button("保存工程…") { _ = state.saveProjectPanel() }.keyboardShortcut("s").disabled(state.analysis == nil || state.workspaceBusy)
                Button("工程另存为…") { _ = state.saveProjectPanel(asCopy:true) }.keyboardShortcut("s",modifiers:[.command,.shift]).disabled(state.analysis == nil || state.workspaceBusy)
                Button("关闭工程") { if state.confirmCanLeave() { state.closeProject();state.trimCache() } }
                Divider()
                Button("导入连拍…") { openImportPanel(state) }.keyboardShortcut("o",modifiers:[.command,.option])
                Button("导入视频（实验）…") { openVideoPanel(state) }
            }
            CommandMenu("播放") {
                Button(state.isPlaying ? "暂停" : "播放") { state.togglePlay() }.keyboardShortcut(.space, modifiers: [])
                Button("上一帧") { state.step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("下一帧") { state.step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Divider()
                Button("切换 成片 / 原图") { state.viewMode = state.viewMode == .output ? .source : .output; state.refreshPreview() }
                    .keyboardShortcut("t")
                Button("排除/恢复当前帧") { state.toggleExcluded() }.keyboardShortcut("x", modifiers: [])
            }
            CommandMenu("修正") {
                Button("修正鸟眼") {
                    if state.viewMode == .source && state.sourceTool == .fixEye { state.sourceTool = .none } else { state.startFixingEye() }
                }
                .keyboardShortcut("e", modifiers: [])
                Button("上一个推算帧") { state.jumpToPredicted(-1) }.keyboardShortcut("[", modifiers: [])
                Button("下一个推算帧") { state.jumpToPredicted(1) }.keyboardShortcut("]", modifiers: [])
                Button("撤销本帧修正") { state.clearManualEye() }
                Divider()
                Button("原图放大 / 全图") {
                    if state.viewMode != .source { state.viewMode = .source; state.refreshPreview() }
                    state.sourceZoom = state.sourceZoom > 1.01 ? 1 : 4
                }
                .keyboardShortcut("z", modifiers: [])
            }
            CommandGroup(after: .saveItem) {
                Button("导出…") { state.showExportSheet = true }.keyboardShortcut("e").disabled(state.job == nil)
                Divider()
                Button("缓存管理…") { state.showCacheSheet=true }.disabled(state.workspaceBusy)
                Divider()
                Button("添加背景音乐…") { state.chooseAudio() }.disabled(state.analysis == nil)
                Button("导入图片水印…") { state.chooseWatermark() }
            }
        }
    }
}

@MainActor
func openVideoPanel(_ state: AppState) {
    guard state.confirmCanLeave() else { return }
    let p = NSOpenPanel()
    p.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
    p.message = "选择要锁定主体并裁切增稳的视频（实验功能，SDR）"
    if p.runModal() == .OK { state.videoImportURL = p.url }
}

@MainActor
func openImportPanel(_ state: AppState) {
    guard state.confirmCanLeave() else { return }
    let p = NSOpenPanel()
    p.allowsMultipleSelection = true
    p.canChooseDirectories = true
    p.canChooseFiles = true
    p.allowedContentTypes = [.jpeg, .heic, .heif, .png, .tiff]
    p.message = "选择连拍照片所在的文件夹，或直接选中多张照片"
    let grouping = NSButton(checkboxWithTitle: "归为一组，合成同一视频（不勾选则按拍摄间隔分组）", target: nil, action: nil)
    grouping.setButtonType(.switch)
    p.accessoryView = grouping
    p.isAccessoryViewDisclosed = true
    if p.runModal() == .OK { state.importURLs(p.urls, merge: grouping.state == .on) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var terminationCheck:(()->Bool)?
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { Self.terminationCheck?() == false ? .terminateCancel : .terminateNow }
    }
    @MainActor static var terminationCleanup:(()->Void)?
    func applicationWillTerminate(_ notification: Notification) { MainActor.assumeIsolated { Self.terminationCleanup?() };Diagnostics.finish() }
    /// Set by the UI: imports folders / photos opened from Finder ("Open With", Dock icon drop, `open -a`).
    @MainActor static var openHandler: (([URL]) -> Void)?
    @MainActor private static var pendingOpen: [URL] = []

    @MainActor static func setOpenHandler(_ h: @escaping ([URL]) -> Void) {
        openHandler = h
        if !pendingOpen.isEmpty { h(pendingOpen); pendingOpen = [] }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            if let h = Self.openHandler { h(urls) } else { Self.pendingOpen += urls }
        }
    }

    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-key shortcuts (space, E, X, Z, [ ]) must not steal keystrokes while typing in a text field:
        // hand plain key presses straight to the field being edited.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .control])
            guard mods.isEmpty, let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable else { return event }
            tv.keyDown(with: event)
            return nil
        }
        // Running as a bare executable (swift run): make it a regular foreground app
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
