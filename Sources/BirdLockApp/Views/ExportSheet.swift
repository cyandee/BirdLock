import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BirdLockCore

struct ExportSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var kind: AppState.ExportKind = .video
    @State private var choosingDestination = false

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 16) {
            Text("导出").font(.title2.weight(.semibold))
            Picker("类型", selection: $kind) {
                ForEach(AppState.ExportKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(state.exportState.running || choosingDestination)

            if let job = state.job {
                let (w, h) = job.outputSize
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow { Text("尺寸").foregroundStyle(.secondary); Text("\(w) × \(h)（\(job.export.aspect.label)）") }
                    switch kind {
                    case .video:
                        GridRow { Text("时长").foregroundStyle(.secondary); Text(String(format: "%.1f 秒，%d 帧 @ %.0f fps", job.duration, job.outputFrames.count, job.export.outputFPS)) }
                        GridRow { Text("编码").foregroundStyle(.secondary); Text(job.export.codec.title) }
                    case .images:
                        GridRow { Text("图片").foregroundStyle(.secondary); Text("\(job.used.count) 张 JPEG（对齐裁剪后）") }
                    case .gif:
                        GridRow { Text("GIF").foregroundStyle(.secondary); Text(String(format: "%d 帧，最长边 720 px", job.outputFrames.count)) }
                    }
                    GridRow { Text("来源").foregroundStyle(.secondary); Text("使用 \(job.used.count) / \(job.analysis.count) \(VideoSource.originalURL(frames:job.analysis.frames) == nil ? "张原图" : "帧画面")") }
                    if kind == .video {
                        GridRow {
                            Text("音频").foregroundStyle(.secondary)
                            let mix = job.mixedAudio(state.audio)
                            Text(mix.isActive ? "\(mix.arrangedTracks.count) 段音频（含启用的特写快门）" : "无")
                        }
                    }
                    GridRow {
                        Text("水印").foregroundStyle(.secondary)
                        Text(state.watermark.isActive ? "图片水印" : "无").foregroundStyle(state.watermark.isActive ? .primary : .tertiary)
                    }
                }
                .font(.callout)
                Toggle("以完整分辨率渲染（推荐，较慢）", isOn: $state.exportSettings.useFullResolution)
                    .disabled(state.exportState.running)
                if let job = state.job, job.used.contains(where: { job.analysis.frames[$0].hasRawPreviewLimit }) {
                    Text("所选画面含较小的 RAW 机内预览。关闭完整分辨率渲染可继续导出。")
                        .font(.caption).foregroundStyle(Theme.warn)
                }
            }

            if let directory = startDirectory {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("导出位置").foregroundStyle(.secondary)
                    Text(directory.path)
                        .lineLimit(2).truncationMode(.middle)
                        .help(directory.path)
                }
                .font(.callout)
            }

            if state.exportState.running || state.exportState.progress > 0 || !state.exportState.message.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: state.exportState.progress).tint(Theme.accent)
                    HStack {
                        Text(state.exportState.cancelling && state.exportState.running ? "正在取消导出…" : state.exportState.running ? String(format: "正在导出… %.0f%%", state.exportState.progress * 100) : state.exportState.message)
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if !state.exportState.running, let u = state.exportState.outputURL, state.exportState.progress >= 1 {
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([u]) }.controlSize(.small)
                            if kind != .images { Button("打开") { NSWorkspace.shared.open(u) }.controlSize(.small) }
                        }
                    }
                }
            }

            if state.job?.outputFrames.isEmpty != false { Text("没有可导出的画面，请检查裁剪范围和选帧设置。").font(.caption).foregroundStyle(Theme.warn) }

            HStack {
                Spacer()
                if state.exportState.running {
                    Button(state.exportState.cancelling ? "正在取消…" : "取消导出") { state.cancelExport() }.disabled(state.exportState.cancelling)
                } else {
                    Button("关闭") { state.exportState = ExportState(); dismiss() }.keyboardShortcut(.cancelAction)
                        .disabled(choosingDestination)
                    Button("选择位置并导出…") { choose() }
                        .buttonStyle(.borderedProminent).tint(Theme.accent).keyboardShortcut(.defaultAction)
                        .disabled(choosingDestination || state.job?.outputFrames.isEmpty != false)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private var sourceURL: URL? {
        guard let analysis = state.analysis else { return nil }
        return VideoSource.originalURL(frames:analysis.frames) ?? analysis.frames.first?.url
    }

    private var startDirectory: URL? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return [state.lastExportDirectory, sourceURL?.deletingLastPathComponent(), documents]
            .compactMap { $0 }
            .first { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func defaultName() -> String {
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "BirdLock"
        return "\(base)_\(state.isCustom ? "目标锁定" : (state.subject == .aircraft ? "机头锁定" : "鸟眼锁定"))"
    }

    private func choose() {
        guard !choosingDestination, !state.exportState.running, let job = state.job else { return }
        let kind = kind, name = defaultName()
        let panel: NSSavePanel
        switch kind {
        case .video, .gif:
            let save = NSSavePanel()
            let ext = kind == .gif ? "gif" : job.export.codec.fileExtension
            save.allowedContentTypes = [kind == .gif ? .gif : (ext == "mp4" ? .mpeg4Movie : .quickTimeMovie)]
            save.nameFieldStringValue = name + "." + ext
            panel = save
        case .images:
            let open = NSOpenPanel()
            open.canChooseDirectories = true
            open.canChooseFiles = false
            open.canCreateDirectories = true
            open.prompt = "导出到此文件夹"
            panel = open
        }
        panel.directoryURL = startDirectory
        choosingDestination = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            choosingDestination = false
            guard response == .OK, let selected = panel.url else { return }
            let output = kind == .images ? selected.appendingPathComponent(name, isDirectory: true) : selected
            state.lastExportDirectory = output.deletingLastPathComponent()
            state.export(kind: kind, to: output)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}
