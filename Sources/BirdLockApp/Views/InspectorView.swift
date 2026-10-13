import SwiftUI
import BirdLockCore

enum InspectorTab: String, CaseIterable, Identifiable {
    case compose, look, output
    var id: String { rawValue }
    var title: String { ["compose": "构图", "look": "画面", "output": "输出"][rawValue]! }
}

struct InspectorView: View {
    @Environment(AppState.self) private var state
    @State private var tab: InspectorTab = .compose

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .compose: ComposeSection()
                    case .look: LookSection()
                    case .output: OutputSection()
                    }
                }
                .padding(14)
            }
            Divider()
            SummaryFooter().padding(12)
        }
        .background(Theme.panel)
    }
}

struct SectionHeader: View {
    var title: String
    var icon: String
    var body: some View {
        Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
    }
}

struct LabeledSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double? = nil
    var format: (Double) -> String
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(format(value)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            if let step { Slider(value: $value, in: range, step: step) } else { Slider(value: $value, in: range) }
        }
        .help(help ?? title)
    }
}

// MARK: - Compose

struct ComposeSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "构图风格", icon: "sparkles.rectangle.stack")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(CompositionPreset.all) { p in
                    Button { state.applyPreset(p) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.name).font(.callout.weight(.semibold))
                            Text(p.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(state.presetID == p.id && state.composition == p.composition ? Theme.accent.opacity(0.18) : Color.white.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(state.presetID == p.id && state.composition == p.composition ? Theme.accent : Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "锁定", icon: "scope")
            Picker("锁定点", selection: $state.composition.lockPoint) {
                ForEach(LockPoint.allCases) { Text($0.title).tag($0) }
            }
            LabeledSlider(title: "跟随方式", value: $state.composition.followSoftness, range: 0...1,
                          format: { $0 < 0.02 ? "硬锁定" : String(format: "柔和 %.0f%%", $0 * 100) },
                          help: "0 = 鸟眼钉死在画面一点；往右拉，镜头像摄像机一样柔和跟随，鸟在画面中轻微浮动")
        }

        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "画面位置", icon: "viewfinder")
            HStack(alignment: .top, spacing: 12) {
                AnchorPad(x: $state.composition.anchorX, y: $state.composition.anchorY,
                          aspect: state.exportSettings.aspect.value)
                    .frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 6) {
                    Text("拖动小圆点，设置鸟眼在成片中的位置").font(.caption).foregroundStyle(.secondary)
                    Toggle("飞行方向自动留白", isOn: $state.composition.autoLeadRoom)
                        .help("鸟朝左飞时自动镜像水平位置，让鸟的前方留出空间")
                    HStack {
                        Button("居中") { state.composition.anchorX = 0.5; state.composition.anchorY = 0.5 }
                        Button("三分") { state.composition.anchorX = 1.0 / 3; state.composition.anchorY = 1.0 / 3 }
                    }.controlSize(.small)
                }
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "取景", icon: "crop")
            LabeledSlider(title: "取景范围", value: Binding(get: { log(state.composition.framing) }, set: { state.composition.framing = exp($0) }),
                          range: log(3)...log(60), format: { String(format: "短边 = 头长 × %.1f", exp($0)) },
                          help: "数值越小鸟越大。画面短边等于鸟头长度的多少倍")
            Picker("大小", selection: $state.composition.sizeMode) {
                ForEach(SizeMode.allCases) { Text($0.title).tag($0) }
            }
            if state.composition.sizeMode == .lockSize {
                LabeledSlider(title: "大小平滑", value: $state.composition.sizeSmoothing, range: 2...60,
                              format: { String(format: "%.0f 帧", $0) }, help: "越大，鸟的大小变化越平缓")
            }
            Picker("越界时", selection: $state.composition.edgeFill) {
                ForEach(EdgeFill.allCases) { Text($0.title).tag($0) }
            }
            if let job = state.job, job.plan.outOfBoundsFrames > 0 {
                Label("\(job.plan.outOfBoundsFrames) 帧的取景超出原图边缘", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.warn)
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "旋转", icon: "rotate.right")
            Picker("旋转", selection: $state.composition.rotationMode) {
                ForEach(RotationMode.allCases) { Text($0.title).tag($0) }
            }
            LabeledSlider(title: "角度微调", value: $state.composition.rotationOffsetDeg, range: -30...30, step: 0.5,
                          format: { String(format: "%+.1f°", $0) })
        }
    }
}

/// A small aspect-correct pad with a draggable anchor point.
struct AnchorPad: View {
    @Binding var x: Double
    @Binding var y: Double
    var aspect: Double

    var body: some View {
        GeometryReader { geo in
            let r = fitRect(CGSize(width: aspect, height: 1), in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.5))
                    .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                Path { p in
                    for f in [1.0 / 3, 2.0 / 3] {
                        p.move(to: CGPoint(x: r.minX + r.width * f, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + r.width * f, y: r.maxY))
                        p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * f)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * f))
                    }
                }.stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.3))
                    .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                Circle().fill(Theme.eye).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .position(x: r.minX + x * r.width, y: r.minY + y * r.height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                x = clamp((g.location.x - r.minX) / r.width, 0.05, 0.95)
                y = clamp((g.location.y - r.minY) / r.height, 0.05, 0.95)
            })
        }
    }
}

// MARK: - Look

struct LookSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "亮度一致性", icon: "sun.max")
            Toggle("去闪烁（统一相邻帧的曝光和白平衡）", isOn: $state.look.deflicker)
            if state.look.deflicker {
                LabeledSlider(title: "强度", value: $state.look.deflickerStrength, range: 0...1, format: { String(format: "%.0f%%", $0 * 100) })
                LabeledSlider(title: "平滑窗口", value: $state.look.deflickerWindow, range: 2...30, format: { String(format: "%.0f 帧", $0) })
            }
            LabeledSlider(title: "曝光", value: $state.look.exposureEV, range: -1.5...1.5, step: 0.05, format: { String(format: "%+.2f EV", $0) })
        }
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "选帧", icon: "film.stack")
            Toggle("跳过模糊帧", isOn: $state.selection.dropBlurry)
                .help("按鸟头区域的清晰度自动跳过失焦、拖影的帧")
            if state.selection.dropBlurry {
                LabeledSlider(title: "模糊判定", value: $state.selection.blurThreshold, range: 0.2...0.95,
                              format: { String(format: "低于中位数 %.0f%%", $0 * 100) })
                if let job = state.job {
                    Text("将跳过 \(job.status.filter { $0 == .blurry }.count) 帧").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("跳过未识别到鸟的帧", isOn: $state.selection.dropUntracked)
            if let a = state.analysis, !a.excluded.isEmpty {
                HStack {
                    Text("手动排除了 \(a.excluded.count) 帧").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("全部恢复") {
                        var b = a; b.excluded.removeAll(); state.analysis = b; state.rebuildJob(immediate: true)
                    }.controlSize(.small)
                }
            }
        }
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "识别", icon: "bird")
            if let a = state.analysis, let t = a.track {
                let eye = t.frames.filter { $0.eyeVisible }.count
                let has = t.frames.filter { $0.hasData }.count
                Text("识别到鸟：\(has)/\(a.count) 帧，其中鸟眼可见 \(eye) 帧").font(.caption).foregroundStyle(.secondary)
                if !a.manualEye.isEmpty {
                    HStack {
                        Text("手动修正 \(a.manualEye.count) 帧").font(.caption).foregroundStyle(Theme.manual)
                        Spacer()
                        Button("清除全部修正") { state.clearManualEye(all: true) }.controlSize(.small)
                    }
                }
            }
            Text("在「原图+识别」视图中可以点击修正鸟眼位置，或选择要跟踪的鸟。").font(.caption).foregroundStyle(.secondary)
            Button("重新识别") { state.startAnalysis(fresh: true) }.controlSize(.small)
        }
    }
}

// MARK: - Output

struct OutputSection: View {
    @Environment(AppState.self) private var state
    @State private var customW = 4.0
    @State private var customH = 5.0

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "画面比例", icon: "aspectratio")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(AspectRatio.presets) { ar in
                    let sel = state.exportSettings.aspect.label == ar.label
                    Button { state.exportSettings.aspect = ar } label: {
                        VStack(spacing: 4) {
                            let s = fitRect(CGSize(width: ar.w, height: ar.h), in: CGRect(x: 0, y: 0, width: 26, height: 20))
                            RoundedRectangle(cornerRadius: 2).stroke(sel ? Theme.accent : Color.secondary, lineWidth: 1.2)
                                .frame(width: s.width, height: s.height).frame(height: 20)
                            Text(ar.label.split(separator: " ").first.map(String.init) ?? ar.label).font(.caption2)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(sel ? Theme.accent.opacity(0.16) : Color.white.opacity(0.04)))
                    }
                    .buttonStyle(.plain)
                    .help(ar.label)
                }
            }
            HStack {
                Text("自定义").font(.callout)
                TextField("宽", value: $customW, format: .number).frame(width: 44)
                Text(":")
                TextField("高", value: $customH, format: .number).frame(width: 44)
                Button("应用") {
                    guard customW > 0, customH > 0 else { return }
                    state.exportSettings.aspect = AspectRatio(w: customW, h: customH, label: "\(fmt(customW)):\(fmt(customH))")
                }.controlSize(.small)
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "分辨率与帧率", icon: "4k.tv")
            Picker("短边", selection: $state.exportSettings.shortSide) {
                ForEach(ExportSettings.shortSidePresets, id: \.self) { Text("\($0) px").tag($0) }
            }
            let (w, h) = state.exportSettings.outputSize
            Text("输出 \(w) × \(h)").font(.caption).foregroundStyle(.secondary)
            if let job = state.job {
                let up = job.plan.maxUpscale
                if up > 1.05 {
                    Label(String(format: "最大放大 %.1f×：原图像素不足，画面会略软。可减小分辨率或放宽取景。", up), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.warn)
                } else {
                    Label(String(format: "原图像素充足（最大使用 %.0f%%）", up * 100), systemImage: "checkmark.seal").font(.caption).foregroundStyle(Theme.ok)
                }
            }
            Picker("帧率", selection: $state.exportSettings.outputFPS) {
                ForEach(ExportSettings.fpsPresets, id: \.self) { Text("\(fmt($0)) fps").tag($0) }
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "速度与循环", icon: "speedometer")
            Picker("播放速度", selection: $state.exportSettings.speed) {
                ForEach(ExportSettings.speedPresets, id: \.self) { s in Text(speedLabel(s)).tag(s) }
            }
            if let a = state.analysis {
                Text(String(format: "连拍 %.0f 张/秒，%@", a.fps, speedHint(a.fps))).font(.caption).foregroundStyle(.secondary)
            }
            Picker("补帧", selection: $state.exportSettings.interpolation) {
                ForEach(FrameInterpolation.allCases) { Text($0.title).tag($0) }
            }
            Picker("顺序", selection: $state.exportSettings.loop) {
                ForEach(LoopMode.allCases) { Text($0.title).tag($0) }
            }
            Stepper("重复 \(state.exportSettings.repeatCount) 次", value: $state.exportSettings.repeatCount, in: 1...10)
            LabeledSlider(title: "淡入", value: $state.exportSettings.fadeInSeconds, range: 0...2, step: 0.1, format: { String(format: "%.1f 秒", $0) })
            LabeledSlider(title: "淡出", value: $state.exportSettings.fadeOutSeconds, range: 0...2, step: 0.1, format: { String(format: "%.1f 秒", $0) })
        }

        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "编码", icon: "film")
            Picker("格式", selection: $state.exportSettings.codec) {
                ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
            }
            if state.exportSettings.codec == .h264 || state.exportSettings.codec == .hevc {
                Picker("质量", selection: $state.exportSettings.quality) {
                    ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "文字水印", icon: "textformat")
            Toggle("显示拍摄参数（机身/镜头/快门/光圈/ISO）", isOn: $state.exportSettings.overlay.showExif)
            if state.exportSettings.overlay.showExif {
                Toggle("逐帧显示参数", isOn: $state.exportSettings.overlay.exifPerFrame)
            }
            TextField("自定义文字（如署名、鸟种）", text: $state.exportSettings.overlay.customText)
            Picker("位置", selection: $state.exportSettings.overlay.corner) {
                ForEach(OverlayCorner.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            LabeledSlider(title: "字号", value: $state.exportSettings.overlay.textScale, range: 0.5...2.5, format: { String(format: "%.1f×", $0) })
        }
    }

    private func fmt(_ v: Double) -> String { v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.2g", v) }
    private func speedLabel(_ s: Double) -> String {
        if abs(s - 1) < 1e-6 { return "原速 1×" }
        if s < 1 { return String(format: "慢放 %.2g×", s) }
        return String(format: "快放 %.2g×", s)
    }
    private func speedHint(_ fps: Double) -> String {
        let s = state.exportSettings.speed
        let eff = fps * s
        return String(format: "成片每秒展示 %.1f 张连拍", eff)
    }
}

struct SummaryFooter: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack {
            if let job = state.job {
                let (w, h) = job.outputSize
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(w)×\(h) · \(Int(job.export.outputFPS)) fps · \(String(format: "%.1f", job.duration)) 秒").font(.caption.weight(.medium))
                    Text("\(job.export.codec.title.components(separatedBy: "（").first ?? "")").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("导出…") { state.showExportSheet = true }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(state.job == nil)
        }
    }
}
