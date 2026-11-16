import SwiftUI
import AppKit
import UniformTypeIdentifiers
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
                    NSApp.appearance = state.appearance.native
                    AppDelegate.endEditGesture = { state.endEditGesture() }
                    AppDelegate.terminationCheck={ state.projectCloseApproved || state.confirmCanLeave() }
                    AppDelegate.terminationCleanup={ CachePolicy.protect(owner:state.cacheOwner,roots:[]);if state.cacheLimitGB>0 { _ = CachePolicy.clean(root:ProxyCache.shared.root,limitBytes:state.cacheLimitGB*(1<<30)) } }
                }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 BirdLock 鸟眼锁定") { AppDocs.showAbout() }
                Button("检查更新…") { updater.check() }
                    .disabled(updater.configured && (!updater.canCheck || updater.checkPending))
                Toggle("自动检查更新", isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 }))
                    .disabled(!updater.configured)
                Toggle("接收测试版更新", isOn: Binding(get: { updater.includeBeta }, set: { updater.includeBeta = $0 }))
                Button("更新源…") { UpdateSourcesWindow.show(updater) }
                    .disabled(!updater.configured)
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
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { state.undoEdit() }
                    .keyboardShortcut("z").disabled(!state.canUndoEdit)
                Button("重做") { state.redoEdit() }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!state.canRedoEdit)
            }
            CommandGroup(after: .toolbar) {
                Picker("外观", selection: Binding(get: { state.appearance }, set: { state.appearance = $0 })) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Button("在访达中显示当前原片") { state.revealOriginals() }.disabled(state.analysis == nil)
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
                Button("导出…") { state.showExportSheet = true }.keyboardShortcut("e").disabled(state.job == nil || state.phase == .importing)
                Divider()
                Button("缓存管理…") { state.showCacheSheet=true }.disabled(state.workspaceBusy)
                Divider()
                Button("添加背景音乐…") { state.chooseAudio() }.disabled(state.analysis == nil || state.phase == .importing)
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
    p.allowedContentTypes = FrameImporter.supportedExtensions.sorted().map {
        UTType(filenameExtension: $0) ?? UTType(tag: $0, tagClass: .filenameExtension, conformingTo: .data) ?? .image
    }
    p.message = "选择照片或包含多个连拍子文件夹的上级文件夹"
    let grouping = NSButton(checkboxWithTitle: "归为一组，合成同一视频（不勾选则按拍摄间隔分组）", target: nil, action: nil)
    grouping.setButtonType(.switch)
    let raw = NSPopUpButton()
    raw.addItems(withTitles: ["RAW 优先使用机内预览", "RAW 高分辨率解码"])
    raw.selectItem(at: state.rawMode == .camera ? 0 : 1)
    let pairs = NSPopUpButton()
    pairs.addItems(withTitles: ["RAW + JPEG：优先 JPEG", "RAW + JPEG：优先 RAW", "RAW + JPEG：两者都导入"])
    pairs.selectItem(at: RawPairPolicy.allCases.firstIndex(of: state.rawPairPolicy) ?? 0)
    let options = NSStackView(views: [grouping, raw, pairs])
    options.orientation = .vertical; options.alignment = .leading
    p.accessoryView = options
    p.isAccessoryViewDisclosed = true
    if p.runModal() == .OK {
        state.rawMode = raw.indexOfSelectedItem == 0 ? .camera : .raw
        state.rawPairPolicy = RawPairPolicy.allCases[max(0, pairs.indexOfSelectedItem)]
        state.importURLs(p.urls, merge: grouping.state == .on)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var endEditGesture: (() -> Void)?
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp]) { event in
            if event.type == .leftMouseUp {
                DispatchQueue.main.async { Self.endEditGesture?() }
                return event
            }
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable else { return event }
            if event.charactersIgnoringModifiers?.lowercased() == "z", mods == .command {
                tv.undoManager?.undo()
                return nil
            }
            if event.charactersIgnoringModifiers?.lowercased() == "z", mods == [.command, .shift] {
                tv.undoManager?.redo()
                return nil
            }
            guard !mods.contains(.command), !mods.contains(.control) else { return event }
            tv.keyDown(with: event)
            return nil
        }
        // Running as a bare executable (swift run): make it a regular foreground app
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
