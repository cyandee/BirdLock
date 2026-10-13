import SwiftUI
import AppKit
import BirdLockCore

@main
struct BirdLockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("BirdLock 鸟眼锁定") {
            ContentView()
                .environment(state)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入连拍…") { openImportPanel(state) }.keyboardShortcut("o")
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
            CommandGroup(after: .saveItem) {
                Button("导出…") { state.showExportSheet = true }.keyboardShortcut("e").disabled(state.job == nil)
            }
        }
    }
}

@MainActor
func openImportPanel(_ state: AppState) {
    let p = NSOpenPanel()
    p.allowsMultipleSelection = true
    p.canChooseDirectories = true
    p.canChooseFiles = true
    p.allowedContentTypes = [.jpeg, .heic, .heif, .png, .tiff]
    p.message = "选择连拍照片所在的文件夹，或直接选中多张照片"
    if p.runModal() == .OK { state.importURLs(p.urls) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running as a bare executable (swift run): make it a regular foreground app
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
