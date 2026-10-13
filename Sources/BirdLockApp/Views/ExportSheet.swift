import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BirdLockCore

struct ExportSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var kind: AppState.ExportKind = .video

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 16) {
            Text("导出").font(.title2.weight(.semibold))
            Picker("类型", selection: $kind) {
                ForEach(AppState.ExportKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(state.exportState.running)

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
                    GridRow { Text("来源").foregroundStyle(.secondary); Text("使用 \(job.used.count) / \(job.analysis.count) 张原图") }
                    if kind == .video {
                        GridRow {
                            Text("音乐").foregroundStyle(.secondary)
                            if let u = state.audio.url, state.audio.isActive {
                                Text("\(u.deletingPathExtension().lastPathComponent)（从 \(formatTime(state.audio.startOffset)) 开始）").lineLimit(1)
                            } else {
                                Text("无").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    GridRow {
                        Text("水印").foregroundStyle(.secondary)
                        Text(state.watermark.isActive ? "图片水印" : "无").foregroundStyle(state.watermark.isActive ? .primary : .tertiary)
                    }
                }
                .font(.callout)
                Toggle("使用原图全分辨率渲染（推荐，较慢）", isOn: $state.exportSettings.useFullResolution)
                    .disabled(state.exportState.running)
            }

            if state.exportState.running || state.exportState.progress > 0 || !state.exportState.message.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: state.exportState.progress).tint(Theme.accent)
                    HStack {
                        Text(state.exportState.running ? String(format: "正在导出… %.0f%%", state.exportState.progress * 100) : state.exportState.message)
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if !state.exportState.running, let u = state.exportState.outputURL, state.exportState.progress >= 1 {
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([u]) }.controlSize(.small)
                            if kind != .images { Button("打开") { NSWorkspace.shared.open(u) }.controlSize(.small) }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                if state.exportState.running {
                    Button("取消导出") { state.cancelExport() }
                } else {
                    Button("关闭") { state.exportState = ExportState(); dismiss() }.keyboardShortcut(.cancelAction)
                    Button("选择位置并导出…") { choose() }
                        .buttonStyle(.borderedProminent).tint(Theme.accent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func defaultName() -> String {
        let base = state.analysis?.frames.first?.url.deletingPathExtension().lastPathComponent ?? "BirdLock"
        return "\(base)_鸟眼锁定"
    }

    private func choose() {
        guard let job = state.job else { return }
        switch kind {
        case .video, .gif:
            let p = NSSavePanel()
            let ext = kind == .gif ? "gif" : job.export.codec.fileExtension
            p.allowedContentTypes = [kind == .gif ? .gif : (ext == "mp4" ? .mpeg4Movie : .quickTimeMovie)]
            p.nameFieldStringValue = defaultName() + "." + ext
            if let dir = state.analysis?.frames.first?.url.deletingLastPathComponent() { p.directoryURL = dir }
            if p.runModal() == .OK, let u = p.url { state.export(kind: kind, to: u) }
        case .images:
            let p = NSOpenPanel()
            p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
            p.prompt = "导出到此文件夹"
            if let dir = state.analysis?.frames.first?.url.deletingLastPathComponent() { p.directoryURL = dir }
            if p.runModal() == .OK, let u = p.url { state.export(kind: .images, to: u.appendingPathComponent(defaultName())) }
        }
    }
}
