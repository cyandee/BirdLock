import AppKit
import SwiftUI
import BirdLockCore

enum AppIdentity {
    @MainActor static func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "BirdLock-诊断日志.zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Diagnostics.export(to: url); NSWorkspace.shared.activateFileViewerSelecting([url]) }
        catch { let alert = NSAlert(error: error); alert.runModal() }
    }
    static let email = "cyanodee@gmail.com"
    static let contact = "邮箱：\(email)"
    @MainActor static var supportWindow: NSWindow?

    @MainActor static func showContact() {
        let alert = NSAlert()
        alert.messageText = "BirdLock 反馈与交流"
        alert.informativeText = contact
        alert.addButton(withTitle: "复制邮箱")
        alert.addButton(withTitle: "关闭")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(email, forType: .string)
        }
    }

    @MainActor static func showSupport() {
        if let window = supportWindow { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 620,height: 420),
            styleMask: [.titled,.closable], backing: .buffered, defer: false)
        window.title = "请作者喝杯咖啡"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CoffeeSupportView())
        window.center(); window.makeKeyAndOrderFront(nil); supportWindow = window
    }
    static func supportImage(_ file: String) -> URL? {
        var candidates = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("SharedResources/Support/\(file)")]
        if let resources = Bundle.main.resourceURL { candidates.insert(resources.appendingPathComponent("Support/\(file)"), at: 0) }
        var root = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<8 { candidates.append(root.appendingPathComponent("SharedResources/Support/\(file)")); root.deleteLastPathComponent() }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

private struct CoffeeSupportView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("如果 BirdLock 帮到了你，欢迎自愿赞赏。\n所有功能均可免费使用，是否赞赏不影响使用")
                .multilineTextAlignment(.center)
            HStack(spacing: 24) {
                code("支付宝", file: "alipay-coffee.jpg")
                code("微信", file: "wechat-coffee.png")
            }
            Button("关闭") { AppIdentity.supportWindow?.close() }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 620, height: 420)
    }

    private func code(_ title: String, file: String) -> some View {
        VStack {
            if let url = AppIdentity.supportImage(file), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 258, height: 258)
                    .accessibilityLabel(title + "二维码")
            } else {
                Text("暂时找不到二维码").frame(width: 258, height: 258)
            }
            Text(title + "扫码 · 自愿支持").foregroundStyle(.secondary)
        }
    }
}
