import SwiftUI
import AppKit
import BirdLockCore

/// Ordered update sources. Changes apply immediately and trigger a new reachability probe.
struct UpdateSourcesView: View {
    @ObservedObject var updater: AppUpdater
    @State private var selection: Int?
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        let sources = updater.sources
        VStack(alignment: .leading, spacing: 12) {
            Text("检查和下载更新时按顺序尝试这些源。所有源提供的内容都会用内置公钥验证签名。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                List(selection: $selection) {
                    ForEach(Array(sources.enumerated()), id: \.offset) { i, source in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(source.name)
                                if source.isGitHub { Text("官方").font(.caption).foregroundStyle(.secondary) }
                                if updater.activeSource == source { Text("当前可用").font(.caption).foregroundStyle(.green) }
                            }
                            if let url = source.url { Text(url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        .padding(.vertical, 2).tag(i)
                    }
                }
                .frame(minHeight: 180)
                VStack(alignment: .leading, spacing: 8) {
                    Button("上移") { move(-1) }.disabled((selection ?? 0) <= 0)
                    Button("下移") { move(1) }.disabled(selection.map { $0 >= sources.count - 1 } ?? true)
                    Button("删除") { remove() }.disabled(selection == nil || sources.count <= 1)
                    Divider()
                    Button("恢复默认") { updater.sources = updater.sourceList.defaults; selection = nil; error = nil }
                        .disabled(!updater.sourceList.isCustom)
                }
                .frame(width: 96)
            }
            HStack {
                TextField("https://", text: $draft).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("添加", action: add).disabled(draft.isEmpty || sources.count >= UpdateSourceList.maximum)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
    }

    private func move(_ step: Int) {
        guard let i = selection, updater.sources.indices.contains(i + step) else { return }
        var list = updater.sources; list.swapAt(i, i + step); updater.sources = list; selection = i + step
    }
    private func remove() {
        guard let i = selection, updater.sources.count > 1, updater.sources.indices.contains(i) else { return }
        var list = updater.sources; list.remove(at: i); updater.sources = list; selection = nil
    }
    private func add() {
        do {
            let source = try UpdateSource.custom(draft)
            guard !updater.sources.contains(where: { $0.url == source.url }) else { error = "更新源已存在"; return }
            guard updater.sources.count < UpdateSourceList.maximum else { return }
            updater.sources += [source]; draft = ""; error = nil; selection = updater.sources.count - 1
        } catch { self.error = error.localizedDescription }
    }
}

enum UpdateSourcesWindow {
    @MainActor private static var window: NSWindow?

    @MainActor static func show(_ updater: AppUpdater) {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "更新源"
        w.contentView = NSHostingView(rootView: UpdateSourcesView(updater: updater).preferredColorScheme(.dark))
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}
