import SwiftUI
import BirdLockCore

enum InspectorTab: String, CaseIterable, Identifiable {
    case compose, look, output
    var id: String { rawValue }
    var title: String { ["compose": "构图", "look": "画面", "output": "输出"][rawValue]! }
}

struct InspectorView: View {
    @Environment(AppState.self) private var state
    @AppStorage("inspector.tab") private var tab: InspectorTab = .compose

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch tab {
                    case .compose: ComposeSection()
                    case .look: LookSection()
                    case .output: OutputSection()
                    }
                }
                .padding(10)
            }
            Divider()
            SummaryFooter().padding(.horizontal, 12).padding(.vertical, 10)
        }
        .background(Theme.panel)
    }
}

/// Rounded card that groups one topic in the inspector.
struct InspectorCard<Content: View>: View {
    var title: String
    var icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.cardStroke))
    }
}

/// Label + control on one line, labels aligned.
struct FormRow<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
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
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(format(value)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            if let step { Slider(value: $value, in: range, step: step) } else { Slider(value: $value, in: range) }
        }
        .controlSize(.small)
        .help(help ?? title)
    }
}

struct StatusNote: View {
    var text: String
    var icon: String
    var color: Color
    var body: some View {
        Label(text, systemImage: icon).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Compose

struct ComposeSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        InspectorCard(title: "构图风格", icon: "sparkles.rectangle.stack") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(CompositionPreset.all) { p in
                    let on = state.isPresetActive(p)
                    Button { state.applyPreset(p) } label: {
                        Text(p.name).font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.accent.opacity(0.18) : Color.white.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? Theme.accent : Color.white.opacity(0.08)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(p.detail)
                }
            }
        }

        InspectorCard(title: "锁定", icon: "scope") {
            FormRow(label: "锁定点") {
                Picker("", selection: $state.composition.lockPoint) {
                    ForEach(LockPoint.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            LabeledSlider(title: "跟随方式", value: $state.composition.followSoftness, range: 0...1,
                          format: { $0 < 0.02 ? "硬锁定" : String(format: "柔和 %.0f%%", $0 * 100) },
                          help: "0 = 鸟眼钉死在画面一点；往右拉，镜头像摄像机一样柔和跟随，鸟在画面中轻微浮动")
        }

        InspectorCard(title: "画面位置", icon: "viewfinder") {
            HStack(alignment: .top, spacing: 12) {
                AnchorPad(x: $state.composition.anchorX, y: $state.composition.anchorY,
                          aspect: state.exportSettings.aspect.value)
                    .frame(width: 104, height: 104)
                VStack(alignment: .leading, spacing: 7) {
                    Text("拖动小圆点，设置鸟眼在成片中的位置。也可以在「原图+识别」里直接拖动取景框。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("飞行方向自动留白", isOn: $state.composition.autoLeadRoom)
                        .help("鸟朝左飞时自动镜像水平位置，让鸟的前方留出空间")
                    HStack {
                        Button("居中") { state.composition.anchorX = 0.5; state.composition.anchorY = 0.5 }
                        Button("三分") { state.composition.anchorX = 1.0 / 3; state.composition.anchorY = 1.0 / 3 }
                    }
                }
                .controlSize(.small)
            }
        }

        InspectorCard(title: "取景", icon: "crop") {
            FramingControl()
            FormRow(label: "大小") {
                Picker("", selection: $state.composition.sizeMode) {
                    ForEach(SizeMode.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            if state.composition.sizeMode == .lockSize {
                LabeledSlider(title: "大小平滑", value: $state.composition.sizeSmoothing, range: 2...60,
                              format: { String(format: "%.0f 帧", $0) }, help: "越大，鸟的大小变化越平缓")
            }
        }

        InspectorCard(title: "画面边缘", icon: "rectangle.dashed") {
            FormRow(label: "越界时") {
                Picker("", selection: $state.composition.edgeFill) {
                    ForEach(EdgeFill.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            if state.composition.edgeFill == .shift {
                Text("鸟飞到原图边缘时，取景框在原图内平移，尽量用满原图像素；鸟会暂时离开锁定点，但不会贴边。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LabeledSlider(title: "鸟眼离画面边缘至少", value: $state.composition.edgeMargin, range: 0...0.3,
                              format: { String(format: "%.0f%%", $0 * 100) },
                              help: "取景框平移后，鸟眼与成片边缘保持的最小距离（画面宽/高的百分比）")
                LabeledSlider(title: "为此最多放大", value: $state.composition.maxEdgeZoom, range: 1...3,
                              format: { $0 < 1.01 ? "不放大" : String(format: "%.1f×", $0) },
                              help: "鸟太靠近原图边缘时，允许稍微放大来保持上面的距离。设为「不放大」则只平移")
            }
            edgeStatus
        }

        InspectorCard(title: "旋转", icon: "rotate.right") {
            FormRow(label: "旋转") {
                Picker("", selection: $state.composition.rotationMode) {
                    ForEach(RotationMode.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            LabeledSlider(title: "角度微调", value: $state.composition.rotationOffsetDeg, range: -30...30, step: 0.5,
                          format: { String(format: "%+.1f°", $0) })
        }
    }

    @ViewBuilder private var edgeStatus: some View {
        if let plan = state.job?.plan {
            switch state.composition.edgeFill {
            case .shift:
                if plan.shiftedFrames > 0 {
                    StatusNote(text: "\(plan.shiftedFrames) 帧鸟靠近原图边缘，已平移取景" + (plan.zoomedFrames > 0 ? "（\(plan.zoomedFrames) 帧略微放大）" : ""),
                               icon: "checkmark.circle", color: Theme.ok)
                }
            case .autoZoom:
                if plan.zoomedFrames > 0 { StatusNote(text: "\(plan.zoomedFrames) 帧放大以避免越界", icon: "plus.magnifyingglass", color: Theme.warn) }
            case .blurExtend, .black:
                if plan.outOfBoundsFrames > 0 {
                    StatusNote(text: "\(plan.outOfBoundsFrames) 帧的取景超出原图边缘", icon: "exclamationmark.triangle", color: Theme.warn)
                }
            }
        }
    }
}

/// Framing: log slider with a much wider range, typed value, ± steps and "use the whole photo".
struct FramingControl: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let range = Composition.framingRange
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("取景范围").font(.callout)
                Spacer()
                Text("短边 = 头长 ×").font(.caption).foregroundStyle(.secondary)
                TextField("", value: Binding(get: { state.composition.framing },
                                             set: { state.composition.framing = clamp($0, range.lowerBound, range.upperBound) }),
                          format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 54)
                    .help("直接输入数值（\(Int(range.lowerBound))–\(Int(range.upperBound))）")
            }
            HStack(spacing: 6) {
                Button { nudge(1 / 1.15) } label: { Image(systemName: "minus") }.help("收紧取景（鸟更大）")
                Slider(value: Binding(get: { log(state.composition.framing) }, set: { state.composition.framing = exp($0) }),
                       in: log(range.lowerBound)...log(range.upperBound))
                Button { nudge(1.15) } label: { Image(systemName: "plus") }.help("放宽取景（鸟更小）")
            }
            .buttonStyle(.borderless)
            HStack {
                Text("鸟更大").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("用满原图") { state.composition.framing = range.upperBound }
                    .buttonStyle(.link).font(.caption)
                    .help("取景框尽量大，直到原图边缘")
                Spacer()
                Text("鸟更小").font(.caption2).foregroundStyle(.tertiary)
            }
            if let plan = state.job?.plan, plan.imageLimitedFrames > 0, state.composition.edgeFill == .shift {
                StatusNote(text: "已到原图大小上限（\(plan.imageLimitedFrames) 帧），再放宽不会更广",
                           icon: "arrow.up.left.and.arrow.down.right", color: .secondary)
            }
        }
        .controlSize(.small)
    }

    private func nudge(_ f: Double) {
        let r = Composition.framingRange
        state.composition.framing = clamp(state.composition.framing * f, r.lowerBound, r.upperBound)
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
        InspectorCard(title: "亮度一致性", icon: "sun.max") {
            Toggle("去闪烁（统一相邻帧的曝光和白平衡）", isOn: $state.look.deflicker)
            if state.look.deflicker {
                LabeledSlider(title: "强度", value: $state.look.deflickerStrength, range: 0...1, format: { String(format: "%.0f%%", $0 * 100) })
                LabeledSlider(title: "平滑窗口", value: $state.look.deflickerWindow, range: 2...30, format: { String(format: "%.0f 帧", $0) })
            }
            LabeledSlider(title: "曝光", value: $state.look.exposureEV, range: -1.5...1.5, step: 0.05, format: { String(format: "%+.2f EV", $0) })
        }
        InspectorCard(title: "选帧", icon: "film.stack") {
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
                    Button("全部恢复") { state.restoreAllExcluded() }.controlSize(.small)
                }
            }
        }
        InspectorCard(title: "识别与修正", icon: "bird") {
            if let a = state.analysis, let t = a.track {
                let eye = t.frames.filter { $0.eyeVisible }.count
                let has = t.frames.filter { $0.hasData }.count
                let predicted = state.predictedFrames.count
                Text("识别到鸟：\(has)/\(a.count) 帧，其中鸟眼可见 \(eye) 帧").font(.caption).foregroundStyle(.secondary)
                if predicted > 0 {
                    HStack {
                        StatusNote(text: "\(predicted) 帧鸟眼被遮挡，位置为推算", icon: "eye.trianglebadge.exclamationmark", color: Theme.warn)
                        Spacer()
                        Button("逐帧检查") { state.startFixingEye(); state.jumpToPredicted(1) }.controlSize(.small)
                    }
                }
                if !a.manualEye.isEmpty {
                    HStack {
                        Text("手动修正 \(a.manualEye.count) 帧").font(.caption).foregroundStyle(Theme.manual)
                        Spacer()
                        Button("清除全部修正") { state.clearManualEye(all: true) }.controlSize(.small)
                    }
                }
            }
            Text("修正方法：切换到「原图+识别」，点「修正鸟眼」，在鸟眼的准确位置点击（或直接拖动青色圆圈）。前后帧会自动重新计算。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("修正鸟眼") { state.startFixingEye() }
                Button("重新识别") { state.startAnalysis(fresh: true) }
            }
            .controlSize(.small)
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
        InspectorCard(title: "画面比例", icon: "aspectratio") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(AspectRatio.presets) { ar in
                    let sel = state.exportSettings.aspect.label == ar.label
                    Button { state.exportSettings.aspect = ar } label: {
                        VStack(spacing: 3) {
                            let s = fitRect(CGSize(width: ar.w, height: ar.h), in: CGRect(x: 0, y: 0, width: 22, height: 16))
                            RoundedRectangle(cornerRadius: 2).stroke(sel ? Theme.accent : Color.secondary, lineWidth: 1.2)
                                .frame(width: s.width, height: s.height).frame(height: 16)
                            Text(ar.label.split(separator: " ").first.map(String.init) ?? ar.label).font(.caption2)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(sel ? Theme.accent.opacity(0.16) : Color.white.opacity(0.04)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(ar.label)
                }
            }
            HStack {
                Text("自定义").font(.callout).foregroundStyle(.secondary)
                TextField("宽", value: $customW, format: .number).frame(width: 40)
                Text(":")
                TextField("高", value: $customH, format: .number).frame(width: 40)
                Button("应用") {
                    guard customW > 0, customH > 0 else { return }
                    state.exportSettings.aspect = AspectRatio(w: customW, h: customH, label: "\(fmt(customW)):\(fmt(customH))")
                }
            }
            .controlSize(.small).textFieldStyle(.roundedBorder)
        }

        InspectorCard(title: "分辨率与帧率", icon: "4k.tv") {
            FormRow(label: "短边") {
                Picker("", selection: $state.exportSettings.shortSide) {
                    ForEach(ExportSettings.shortSidePresets, id: \.self) { Text("\($0) px").tag($0) }
                }.labelsHidden()
            }
            let (w, h) = state.exportSettings.outputSize
            Text("输出 \(w) × \(h)").font(.caption).foregroundStyle(.secondary)
            if let job = state.job {
                let up = job.plan.maxUpscale
                if up > 1.05 {
                    StatusNote(text: String(format: "最大放大 %.1f×：原图像素不足，画面会略软。可减小分辨率或放宽取景。", up),
                               icon: "exclamationmark.triangle", color: Theme.warn)
                } else {
                    StatusNote(text: String(format: "原图像素充足（最大使用 %.0f%%）", up * 100), icon: "checkmark.seal", color: Theme.ok)
                }
            }
            FormRow(label: "帧率") {
                Picker("", selection: $state.exportSettings.outputFPS) {
                    ForEach(ExportSettings.fpsPresets, id: \.self) { Text("\(fmt($0)) fps").tag($0) }
                }.labelsHidden()
            }
        }

        InspectorCard(title: "速度与循环", icon: "speedometer") {
            FormRow(label: "速度") {
                Picker("", selection: $state.exportSettings.speed) {
                    ForEach(ExportSettings.speedPresets, id: \.self) { s in Text(speedLabel(s)).tag(s) }
                }.labelsHidden()
            }
            if let a = state.analysis {
                Text(String(format: "连拍 %.0f 张/秒，%@", a.fps, speedHint(a.fps))).font(.caption).foregroundStyle(.secondary)
            }
            FormRow(label: "补帧") {
                Picker("", selection: $state.exportSettings.interpolation) {
                    ForEach(FrameInterpolation.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            FormRow(label: "顺序") {
                Picker("", selection: $state.exportSettings.loop) {
                    ForEach(LoopMode.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            Stepper("重复 \(state.exportSettings.repeatCount) 次", value: $state.exportSettings.repeatCount, in: 1...10)
            LabeledSlider(title: "淡入", value: $state.exportSettings.fadeInSeconds, range: 0...2, step: 0.1, format: { String(format: "%.1f 秒", $0) })
            LabeledSlider(title: "淡出", value: $state.exportSettings.fadeOutSeconds, range: 0...2, step: 0.1, format: { String(format: "%.1f 秒", $0) })
        }

        InspectorCard(title: "编码", icon: "film") {
            FormRow(label: "格式") {
                Picker("", selection: $state.exportSettings.codec) {
                    ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            if state.exportSettings.codec == .h264 || state.exportSettings.codec == .hevc {
                FormRow(label: "质量") {
                    Picker("", selection: $state.exportSettings.quality) {
                        ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
            }
        }

        FocusMarkCard()
        MusicCard()
        WatermarkCard()

        InspectorCard(title: "文字水印", icon: "text.alignleft") {
            Toggle("显示拍摄参数（机身/镜头/快门/光圈/ISO）", isOn: $state.exportSettings.overlay.showExif)
            if state.exportSettings.overlay.showExif {
                Toggle("逐帧显示参数", isOn: $state.exportSettings.overlay.exifPerFrame)
            }
            TextField("自定义文字（如署名、鸟种）", text: $state.exportSettings.overlay.customText)
                .textFieldStyle(.roundedBorder)
            Picker("位置", selection: $state.exportSettings.overlay.corner) {
                ForEach(OverlayCorner.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
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

/// Camera-style focus frame on the eye (or the head while the eye is hidden), baked into the output.
struct FocusMarkCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        InspectorCard(title: "对焦框", icon: "viewfinder.rectangular") {
            Toggle("在成片里显示对焦点", isOn: $state.exportSettings.focusMark.enabled)
                .help("像索尼相机的鸟眼对焦一样，在鸟眼上画一个对焦框，让观众始终看到焦点在哪里")
            if state.exportSettings.focusMark.enabled {
                FormRow(label: "样式") {
                    Picker("", selection: $state.exportSettings.focusMark.style) {
                        ForEach(FocusMarkStyle.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden()
                }
                FormRow(label: "颜色") {
                    Picker("", selection: $state.exportSettings.focusMark.color) {
                        ForEach(FocusMarkColor.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                LabeledSlider(title: "大小", value: $state.exportSettings.focusMark.size, range: 0.5...2.5,
                              format: { String(format: "%.1f×", $0) })
                LabeledSlider(title: "线宽", value: $state.exportSettings.focusMark.lineWidth, range: 0.5...3,
                              format: { String(format: "%.1f×", $0) })
                Toggle("鸟眼被遮挡时框住鸟头", isOn: $state.exportSettings.focusMark.headWhenHidden)
                    .help("关闭时，遮挡帧仍在推算的鸟眼位置显示小框")
            }
        }
    }
}

struct MusicCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        InspectorCard(title: "背景音乐", icon: "music.note") {
            if let url = state.audio.url {
                HStack {
                    Text(url.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("更换…") { state.chooseAudio() }
                    Button { state.removeAudio() } label: { Image(systemName: "trash") }.help("移除音乐")
                }
                .controlSize(.small)
                if let msg = state.audioMessage { StatusNote(text: msg, icon: "exclamationmark.triangle", color: Theme.warn) }
                let dur = state.audioOverview?.duration ?? 0
                let videoDur = state.job?.duration ?? 0
                LabeledSlider(title: "从音乐的", value: $state.audio.startOffset, range: 0...max(0.1, dur - min(videoDur, dur)),
                              format: { "\(formatTime($0)) 开始" }, help: "也可以在下方「音乐」轨道上拖动高亮区域")
                LabeledSlider(title: "音量", value: $state.audio.volume, range: 0...1.5, format: { String(format: "%.0f%%", $0 * 100) })
                LabeledSlider(title: "淡入", value: $state.audio.fadeIn, range: 0...3, step: 0.1, format: { String(format: "%.1f 秒", $0) })
                LabeledSlider(title: "淡出", value: $state.audio.fadeOut, range: 0...5, step: 0.1, format: { String(format: "%.1f 秒", $0) })
                Toggle("音乐比视频短时循环", isOn: $state.audio.loop)
                if videoDur > dur, dur > 0, !state.audio.loop {
                    StatusNote(text: "音乐比成片短，后面会没有声音", icon: "info.circle", color: .secondary)
                }
                Text("导出「视频」时会把音乐合成进去（AAC 256 kbps）。").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("选择音乐…") { state.chooseAudio() }.controlSize(.small)
                Text("支持 MP3 / M4A / WAV / AIFF，也可以把音频文件拖到下方的「音乐」轨道。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct WatermarkCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        InspectorCard(title: "图片水印", icon: "signature") {
            if let img = state.watermarkImage {
                HStack(spacing: 10) {
                    Image(decorative: img, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(width: 96, height: 44)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("导出时添加", isOn: $state.watermark.enabled)
                        Button("更换图片…") { state.chooseWatermark() }.controlSize(.small)
                    }
                }
                if state.watermark.enabled {
                    LabeledSlider(title: "大小", value: $state.watermark.size, range: 0.05...1.0,
                                  format: { String(format: "%.0f%%", $0 * 100) }, help: "水印宽度占成片短边的比例")
                    LabeledSlider(title: "不透明度", value: $state.watermark.opacity, range: 0.1...1, format: { String(format: "%.0f%%", $0 * 100) })
                    HStack(alignment: .top, spacing: 10) {
                        positionGrid(img)
                        Text("快速放到角落或居中；在「成片预览」里可以直接拖动水印到任意位置。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Button("导入 PNG…") { state.chooseWatermark() }.controlSize(.small)
                Text("例如你的签名或 Logo。建议用透明背景的 PNG。导入后可以在成片预览里拖动位置、调整大小。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func positionGrid(_ img: CGImage) -> some View {
        let (W, H) = state.exportSettings.outputSize
        let short = Double(min(W, H))
        let wN = state.watermark.size * short / Double(W)
        let hN = state.watermark.size * short * Double(img.height) / Double(max(1, img.width)) / Double(H)
        let mx = 0.035 * short / Double(W), my = 0.035 * short / Double(H)
        let xs = [mx + wN / 2, 0.5, 1 - mx - wN / 2], ys = [my + hN / 2, 0.5, 1 - my - hN / 2]
        return Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<3, id: \.self) { r in
                GridRow {
                    ForEach(0..<3, id: \.self) { c in
                        let on = abs(state.watermark.centerX - xs[c]) < 0.01 && abs(state.watermark.centerY - ys[r]) < 0.01
                        Button {
                            state.watermark.centerX = xs[c]; state.watermark.centerY = ys[r]
                        } label: {
                            RoundedRectangle(cornerRadius: 3).fill(on ? Theme.accent : Color.white.opacity(0.12))
                                .frame(width: 18, height: 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
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
                    HStack(spacing: 6) {
                        Text("\(job.export.codec.title.components(separatedBy: "（").first ?? "")")
                        if state.audio.isActive { Image(systemName: "music.note") }
                        if state.watermark.isActive { Image(systemName: "signature") }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("导出…") { state.showExportSheet = true }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(state.job == nil)
        }
    }
}
