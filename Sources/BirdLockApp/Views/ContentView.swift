import SwiftUI
import UniformTypeIdentifiers
import BirdLockCore

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack {
                    Theme.canvas
                    if state.frames.isEmpty && state.phase != .importing {
                        DropZoneView(targeted: dropTargeted)
                    } else {
                        PreviewArea()
                    }
                    if case .analyzing(let stage, let p) = state.phase {
                        AnalyzingOverlay(stage: stage, progress: p)
                    }
                    if state.phase == .importing {
                        ProgressView("正在读取照片…").padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if case .failed(let msg) = state.phase {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                            Text(msg).multilineTextAlignment(.center)
                            Button("重新导入…") { openImportPanel(state) }
                        }
                        .padding(28).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    loadDropped(providers)
                    return true
                }
                if state.analysis != nil {
                    TransportBar()
                    TimelineView()
                        .frame(height: 118)
                }
            }
            if state.analysis != nil {
                Divider()
                InspectorView()
                    .frame(width: 340)
            }
        }
        .background(Theme.canvas)
        .toolbar { MainToolbar() }
        .sheet(isPresented: $state.showExportSheet) { ExportSheet() }
        .preferredColorScheme(.dark)
        .onAppear {
            // `open BirdLock.app --args <folder>` imports a folder directly (handy for testing)
            let args = ProcessInfo.processInfo.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            let urls = args.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if state.frames.isEmpty, !urls.isEmpty { state.importURLs(urls) }
        }
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                if let u { lock.lock(); urls.append(u); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { state.importURLs(urls) } }
    }
}

enum Theme {
    static let canvas = Color(red: 0.075, green: 0.078, blue: 0.086)
    static let panel = Color(red: 0.11, green: 0.115, blue: 0.125)
    static let accent = Color(red: 0.98, green: 0.72, blue: 0.24)     // warm amber, like a bird's eye ring
    static let eye = Color(red: 0.25, green: 0.85, blue: 1.0)
    static let ok = Color(red: 0.36, green: 0.78, blue: 0.47)
    static let warn = Color(red: 0.95, green: 0.68, blue: 0.25)
    static let bad = Color(red: 0.92, green: 0.36, blue: 0.33)
    static let manual = Color(red: 0.72, green: 0.52, blue: 1.0)
}

struct MainToolbar: ToolbarContent {
    @Environment(AppState.self) private var state

    var body: some ToolbarContent {
        @Bindable var state = state
        ToolbarItemGroup(placement: .navigation) {
            Button { openImportPanel(state) } label: { Label("导入", systemImage: "photo.stack") }
                .help("导入连拍照片（文件夹或多张 JPG / HEIF）")
            if state.segments.count > 1 {
                Picker("连拍组", selection: Binding(get: { state.segmentIndex }, set: { state.selectSegment($0) })) {
                    ForEach(state.segments.indices, id: \.self) { i in
                        Text("第 \(i + 1) 组 · \(state.segments[i].range.count) 张").tag(i)
                    }
                }
                .frame(width: 160)
                .help("文件夹里检测到多组连拍，选择要处理的一组")
            }
        }
        ToolbarItemGroup(placement: .principal) {
            if state.analysis != nil {
                Picker("视图", selection: Binding(get: { state.viewMode }, set: { state.viewMode = $0; state.refreshPreview() })) {
                    ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if state.analysis != nil {
                Button { state.showExportSheet = true } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .help("导出视频 / 图片序列 / GIF（⌘E）")
            }
        }
    }
}

struct DropZoneView: View {
    @Environment(AppState.self) private var state
    var targeted: Bool

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.12)).frame(width: 110, height: 110)
                Image(systemName: "bird.fill").font(.system(size: 46)).foregroundStyle(Theme.accent)
            }
            Text("把连拍照片拖到这里").font(.title2.weight(.semibold))
            Text("支持 JPG / HEIF，整个文件夹或多选照片都可以。\n自动识别鸟眼并锁定，一键生成连拍视频。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("选择文件夹…") { openImportPanel(state) }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
        }
        .padding(60)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? Theme.accent : Color.white.opacity(0.18))
        )
        .padding(40)
    }
}

struct AnalyzingOverlay: View {
    @Environment(AppState.self) private var state
    var stage: String
    var progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "scope").foregroundStyle(Theme.accent)
                Text("正在分析 \(state.currentFrames.count) 张照片").font(.headline)
            }
            Text(stage).font(.callout).foregroundStyle(.secondary)
            ProgressView(value: progress).progressViewStyle(.linear).tint(Theme.accent).frame(width: 320)
            HStack {
                Spacer()
                Button("取消") { state.cancelAnalysis() }
            }
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
