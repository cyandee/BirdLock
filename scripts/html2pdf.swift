// Renders an HTML file to a paginated A4 PDF with WebKit (used for the bundled manual).
// Usage: swift scripts/html2pdf.swift input.html output.pdf
import AppKit
import WebKit

final class Renderer: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
    let out: URL
    init(out: URL) { self.out = out }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // light appearance for print
        webView.appearance = NSAppearance(named: .aqua)
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595.2, height: 841.8)   // A4
        info.topMargin = 42; info.bottomMargin = 42; info.leftMargin = 40; info.rightMargin = 40
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
        let op = webView.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = NSRect(x: 0, y: 0, width: 800, height: 1000)
        op.runModal(for: NSWindow(), delegate: self, didRun: #selector(done(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc func done(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        print(success ? "wrote \(out.path)" : "print failed")
        exit(success ? 0 : 1)
    }
}

let args = CommandLine.arguments
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let r = Renderer(out: URL(fileURLWithPath: args[2]))
r.web.appearance = NSAppearance(named: .aqua)
r.web.navigationDelegate = r
let input = URL(fileURLWithPath: args[1])
r.web.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("timeout"); exit(2) }
app.run()
