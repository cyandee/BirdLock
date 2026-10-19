import SwiftUI
import AppKit

/// Documents bundled in the app (Contents/Resources/Docs), with the repo's docs/ as a fallback when run from source.
enum AppDocs {
    static let agreementVersion = "1.0"
    static let agreement = "用户协议.md"
    static let notices = "第三方许可.md"
    static let license = "LICENSE"
    static let manualHTML = "使用说明.html"
    static let manualPDF = "使用说明.pdf"

    static func url(_ name: String) -> URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("Docs/\(name)"), fm.fileExists(atPath: res.path) { return res }
        var u = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            for cand in [u.appendingPathComponent("docs/\(name)"), u.appendingPathComponent(name)] where fm.fileExists(atPath: cand.path) {
                return cand
            }
            u.deleteLastPathComponent()
        }
        return nil
    }

    static func text(_ name: String) -> String {
        url(name).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "（找不到 \(name)）"
    }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    @MainActor static func openManual() {
        if let u = url(manualPDF) ?? url(manualHTML) ?? url("使用说明.md") { NSWorkspace.shared.open(u) }
    }

    @MainActor static func showAbout() {
        let credits = NSMutableAttributedString(string: "飞鸟连拍对齐鸟眼，一键生成连拍视频。\n\nCopyright © 2026 cyanol\n依据 GNU AGPL-3.0 开源\n\(AppIdentity.contact)",
                                                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        let style = NSMutableParagraphStyle(); style.alignment = .center
        credits.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "BirdLock 鸟眼锁定",
            .applicationVersion: "\(appVersion) 测试版",
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Renders the subset of Markdown used by the bundled documents (headings, paragraphs, lists, quotes, rules,
/// inline **bold** / `code`).
struct MarkdownDocView: View {
    var text: String

    private enum Block: Hashable { case h(Int, String), p(String), li(String, String), quote(String), rule, mono(String) }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = []
        func flush() { if !para.isEmpty { out.append(.p(para.joined(separator: "\n"))); para = [] } }
        var inLicense = false
        for raw in text.components(separatedBy: .newlines) {
            if inLicense { out.append(.mono(raw)); continue }
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { flush(); continue }
            if s.hasPrefix("GNU AFFERO GENERAL PUBLIC LICENSE") { flush(); inLicense = true; out.append(.mono(raw)); continue }
            if let m = s.firstMatch(of: #/^(#{1,4})\s+(.*)$/#) { flush(); out.append(.h(m.1.count, String(m.2))); continue }
            if s.firstMatch(of: #/^-{3,}$/#) != nil { flush(); out.append(.rule); continue }
            if s.hasPrefix(">") { flush(); out.append(.quote(String(s.dropFirst()).trimmingCharacters(in: .whitespaces))); continue }
            if let m = s.firstMatch(of: #/^([-*]|\d+\.)\s+(.*)$/#) {
                flush(); out.append(.li(m.1 == "-" || m.1 == "*" ? "•" : String(m.1), String(m.2))); continue
            }
            para.append(s)
        }
        flush()
        return out
    }

    private func inline(_ s: String) -> Text {
        let a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return Text(a)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .h(let n, let t):
                    inline(t).font(n == 1 ? .title2.bold() : (n == 2 ? .headline : .subheadline.bold()))
                        .padding(.top, n == 1 ? 0 : 10)
                case .p(let t): inline(t).fixedSize(horizontal: false, vertical: true)
                case .li(let mark, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(mark).foregroundStyle(.secondary).frame(minWidth: 16, alignment: .trailing)
                        inline(t).fixedSize(horizontal: false, vertical: true)
                    }
                case .quote(let t):
                    inline(t).font(.callout).foregroundStyle(.secondary).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                case .rule: Divider().padding(.vertical, 4)
                case .mono(let t): Text(t.isEmpty ? " " : t).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
        .textSelection(.enabled)
    }
}

/// Shown on first launch (and after the agreement changes): the app is usable only after agreeing.
struct AgreementSheet: View {
    var onAccept: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "bird.fill").font(.title2).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("欢迎使用 BirdLock 鸟眼锁定").font(.headline)
                    Text("使用前请阅读用户协议，特别是加粗的免责条款").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            Divider()
            ScrollView {
                MarkdownDocView(text: AppDocs.text(AppDocs.agreement)).padding(20)
            }
            Divider()
            HStack {
                Button("查看开源许可") { LegalWindow.show(.notices) }.buttonStyle(.link)
                Spacer()
                Button("不同意") { NSApp.terminate(nil) }
                Button("同意并继续") { onAccept() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 640, height: 600)
        .interactiveDismissDisabled()
    }
}

/// Standalone window for reading the agreement or the licenses from the menu.
enum LegalWindow {
    enum Kind { case agreement, notices }
    @MainActor private static var windows: [String: NSWindow] = [:]

    @MainActor static func show(_ kind: Kind) {
        let key = kind == .agreement ? "agreement" : "notices"
        if let w = windows[key] { w.makeKeyAndOrderFront(nil); return }
        let text = kind == .agreement ? AppDocs.text(AppDocs.agreement)
                                      : AppDocs.text(AppDocs.notices) + "\n\n" + AppDocs.text(AppDocs.license)
        let view = ScrollView { MarkdownDocView(text: text).padding(24) }
            .frame(minWidth: 560, minHeight: 480)
            .preferredColorScheme(.dark)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = kind == .agreement ? "用户协议" : "许可与第三方组件"
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        windows[key] = w
        w.makeKeyAndOrderFront(nil)
    }
}
