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
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 390,height: 650),
            styleMask: [.titled,.closable], backing: .buffered, defer: false)
        window.title = "请作者喝杯咖啡"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CoffeeSupportView())
        window.center(); window.makeKeyAndOrderFront(nil); supportWindow = window
    }
    static var supportImage: URL? {
        var candidates = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("SharedResources/Support/alipay-coffee.jpg")]
        if let resources = Bundle.main.resourceURL { candidates.insert(resources.appendingPathComponent("Support/alipay-coffee.jpg"), at: 0) }
        var root = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<8 { candidates.append(root.appendingPathComponent("SharedResources/Support/alipay-coffee.jpg")); root.deleteLastPathComponent() }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

private struct CoffeeSupportView: View {
    var body: some View {
        VStack(spacing: 14) {
            Text("请作者喝杯咖啡 ☕").font(.title2.bold())
            Text("如果 BirdLock 帮到了你，欢迎自愿赞赏。\n5 元、10 元、20 元或任意金额，心意随意。\n所有功能均可免费使用，赞赏不影响使用。")
                .multilineTextAlignment(.center).font(.callout)
            if let url = AppIdentity.supportImage, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 460)
            } else { Text("暂时找不到赞赏二维码，可通过邮箱联系作者。") }
            Text("支付宝扫码 · 自愿支持").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 390,height: 650).background(Color.white).preferredColorScheme(.light)
    }
}
