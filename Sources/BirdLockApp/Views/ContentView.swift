import SwiftUI
import UniformTypeIdentifiers
import BirdLockCore

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var dropTargeted = false
    @AppStorage("agreement.accepted") private var acceptedAgreement = ""
    @State private var pendingOpen: [URL] = []

    private var agreed: Bool { acceptedAgreement == AppDocs.agreementVersion }

    /// Imports (or queues until the agreement is accepted) photos / music opened from the command line or Finder.
    private func open(_ urls: [URL]) {
        guard agreed else { pendingOpen += urls; return }
        let audio = urls.filter { isAudioFile($0) }
        if audio.count == urls.count, state.analysis != nil, let u = audio.first { state.setAudio(u) }
        else if state.frames.isEmpty || !urls.isEmpty { state.importURLs(urls.filter { !isAudioFile($0) }) }
    }

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack {
                    Theme.canvas
                    if state.frames.isEmpty && state.phase != .importing {
                        DropZoneView(targeted: dropTargeted)
                    } else if state.analysis != nil {
                        PreviewArea()
                    }
                    if case .analyzing(let stage, let p) = state.phase {
                        AnalyzingOverlay(stage: stage, progress: p)
                    }
                    if state.phase == .importing {
                        StatusCard {
                            HStack(spacing: 14) {
                                ProgressView().controlSize(.small)
                                Text("正在读取照片…").font(.headline)
                            }
                        }
                    }
                    if case .failed(let msg) = state.phase {
                        StatusCard {
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Theme.warn)
                                Text(msg).multilineTextAlignment(.center)
                                Button("重新导入…") { openImportPanel(state) }
                            }
                        }
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    loadDropped(providers)
                    return true
                }
                if state.analysis != nil {
                    Divider()
                    TransportBar()
                    Divider()
                    TimelinePanel()
                }
            }
            if state.analysis != nil {
                Divider()
                InspectorView()
                    .frame(width: 330)
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
            if state.frames.isEmpty, !urls.isEmpty { open(urls) }
            AppDelegate.setOpenHandler { urls in open(urls) }
        }
        .sheet(isPresented: Binding(get: { !agreed }, set: { _ in })) {
            AgreementSheet {
                acceptedAgreement = AppDocs.agreementVersion
                let queued = pendingOpen
                pendingOpen = []
                if !queued.isEmpty { open(queued) }
            }
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
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            // a dropped audio file (with a burst already loaded) becomes the background music
            let audio = urls.filter { isAudioFile($0) }
            if audio.count == urls.count, state.analysis != nil, let u = audio.first {
                state.setAudio(u)
            } else {
                state.importURLs(urls.filter { !isAudioFile($0) })
            }
        }
    }
}

func isAudioFile(_ u: URL) -> Bool {
    let ext = u.pathExtension.lowercased()
    return AudioMixer.fileExtensions.contains(ext) && !FrameImporter.supportedExtensions.contains(ext)
}

enum Theme {
    static let canvas = Color(red: 0.075, green: 0.078, blue: 0.086)
    static let panel = Color(red: 0.11, green: 0.115, blue: 0.125)
    static let card = Color.white.opacity(0.045)
    static let cardStroke = Color.white.opacity(0.07)
    static let accent = Color(red: 0.98, green: 0.72, blue: 0.24)     // warm amber, like a bird's eye ring
    static let eye = Color(red: 0.25, green: 0.85, blue: 1.0)
    static let ok = Color(red: 0.36, green: 0.78, blue: 0.47)
    static let warn = Color(red: 0.95, green: 0.68, blue: 0.25)
    static let bad = Color(red: 0.92, green: 0.36, blue: 0.33)
    static let manual = Color(red: 0.72, green: 0.52, blue: 1.0)
    static let music = Color(red: 0.45, green: 0.62, blue: 1.0)
}

struct MainToolbar: ToolbarContent {
    @Environment(AppState.self) private var state

    var body: some ToolbarContent {
        @Bindable var state = state
        ToolbarItemGroup(placement: .navigation) {
            Picker("识别主体", selection: Binding(get: { state.subject },set: { state.changeSubject($0) })) {
                Text("鸟类").tag(AnalysisSubject.bird)
                Text("飞机（试验）").tag(AnalysisSubject.aircraft)
            }
            .frame(width: 125)
            .disabled(state.exportState.running || state.phase == .importing)
            .help("飞机模式自动识别机头和机身；复杂视角请检查机头，可逐帧修正。首次分析较慢。")
            Button { openImportPanel(state) } label: { Label("导入", systemImage: "photo.stack") }
                .help("导入连拍照片（文件夹或多张 JPG / HEIF）")
            if state.segments.count > 1 {
                // Iterate over values (not indices): the list can shrink when another folder is loaded.
                let items = state.segments.enumerated().map { (index: $0.offset, count: $0.element.range.count) }
                Picker("连拍组", selection: Binding(get: { state.segmentIndex }, set: { state.selectSegment($0) })) {
                    Text("合并选中组 → 同一视频").tag(-1)
                    ForEach(items, id: \.index) { item in
                        Text("第 \(item.index + 1) 组 · \(item.count) 张").tag(item.index)
                    }
                }
                .frame(width: 160)
                .help("文件夹里检测到多组连拍，选择要处理的一组")
                Menu("选择合并组") {
                    ForEach(items, id: \.index) { item in
                        Toggle("第 \(item.index + 1) 组 · \(item.count) 张", isOn: Binding(
                            get: { state.mergeGroupIndices.contains(item.index) },
                            set: { state.includeGroup(item.index, enabled: $0) }))
                    }
                }
            }
        }
        ToolbarItemGroup(placement: .principal) {
            if state.analysis != nil {
                Picker("视图", selection: Binding(get: { state.viewMode }, set: { state.viewMode = $0; state.refreshPreview() })) {
                    ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .help("⌘T 切换")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { AppIdentity.showSupport() } label: { Label("赞赏", systemImage: "cup.and.saucer") }
                .help("请作者喝杯咖啡 · 完全自愿，所有功能免费")
            if state.analysis != nil {
                Button { state.showExportSheet = true } label: { Label("导出", systemImage: "square.and.arrow.up") }
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
            Text("支持 JPG / HEIF，整个文件夹或多选照片都可以。\n自动识别并锁定主体，一键生成连拍视频。")
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

/// Compact floating card used for import / analysis / error states.
struct StatusCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
            .fixedSize()
    }
}

struct AnalyzingOverlay: View {
    @Environment(AppState.self) private var state
    var stage: String
    var progress: Double

    private static let stages: [(stage: AnalysisStage, weight: Double, icon: String)] = [
        (.detecting, 0.35, "viewfinder"),
        (.keypoints, 0.30, "eye"),
        (.registering, 0.30, "scope"),
        (.solving, 0.05, "point.topleft.down.to.point.bottomright.curvepath"),
    ]

    private var stages: [(stage: AnalysisStage, weight: Double, icon: String)] {
        state.isAircraft ? [(.aircraftDetecting,0.15,"airplane"),(.background,0.05,"photo"),
                            (.aircraftParts,0.75,"scope"),(.sharpness,0.04,"sparkle"),(.solving,0.01,"point.topleft.down.to.point.bottomright.curvepath")] : Self.stages
    }
    private var stageIndex: Int { stages.firstIndex { $0.stage.rawValue == stage } ?? -1 }

    private var overall: Double {
        let k = stageIndex
        guard k >= 0 else { return 0 }
        let done = stages[..<k].reduce(0) { $0 + $1.weight }
        return min(1, done + stages[k].weight * progress)
    }

    var body: some View {
        let frames = state.currentFrames
        ZStack {
            Color.black.opacity(state.analysis == nil ? 0 : 0.45).ignoresSafeArea()
            StatusCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(Theme.accent.opacity(0.14)).frame(width: 46, height: 46)
                            Image(systemName: state.isAircraft ? "airplane" : "bird.fill").font(.system(size: 20)).foregroundStyle(Theme.accent)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("正在分析 \(frames.count) 张照片").font(.headline)
                            if let a = frames.first, let b = frames.last {
                                Text("\(a.url.deletingPathExtension().lastPathComponent) – \(b.url.deletingPathExtension().lastPathComponent)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(stages.enumerated()), id: \.offset) { k, s in
                            stageRow(k, s.stage.rawValue, s.icon)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: overall).progressViewStyle(.linear).tint(Theme.accent)
                        HStack {
                            Text(statusLine).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer()
                            Button("取消") { state.cancelAnalysis() }.controlSize(.small)
                        }
                    }
                }
                .frame(width: 330)
            }
        }
    }

    private var statusLine: String {
        let pct = String(format: "%.0f%%", overall * 100)
        guard stageIndex >= 0 else { return stage == AnalysisStage.queued.rawValue ? "等待上次分析结束…" : (stage == "加载识别模型" ? "加载识别模型…" : "准备中…") }
        let elapsed = Date().timeIntervalSince(state.analysisStarted)
        guard overall > 0.04, elapsed > 2 else { return pct }
        let remain = elapsed * (1 - overall) / overall
        return remain < 60 ? String(format: "%@ · 约剩 %.0f 秒", pct, max(1, remain)) : String(format: "%@ · 约剩 %.0f 分钟", pct, remain / 60)
    }

    @ViewBuilder private func stageRow(_ k: Int, _ title: String, _ icon: String) -> some View {
        let cur = stageIndex
        HStack(spacing: 10) {
            ZStack {
                if k < cur {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                } else if k == cur {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 16)
            Text(title).font(.callout).foregroundStyle(k <= cur ? .primary : .tertiary)
            Spacer()
            if k == cur {
                Text(String(format: "%.0f%%", progress * 100)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}
