import SwiftUI
import BirdLockCore

/// Fits an image of `size` into `bounds` (aspect fit) and returns the drawn rect.
func fitRect(_ size: CGSize, in bounds: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0 else { return .zero }
    let s = min(bounds.width / size.width, bounds.height / size.height)
    let w = size.width * s, h = size.height * s
    return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
}

struct PreviewArea: View {
    @Environment(AppState.self) private var state

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size).insetBy(dx: 24, dy: 20)
            ZStack {
                if state.viewMode == .output {
                    OutputPreview(bounds: bounds)
                } else {
                    SourcePreview(bounds: bounds)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .overlay(alignment: .topLeading) { SourceToolBar().padding(14) }
        .overlay(alignment: .topTrailing) { FrameBadges().padding(14) }
    }
}

struct OutputPreview: View {
    @Environment(AppState.self) private var state
    var bounds: CGRect

    var body: some View {
        let (W, H) = state.exportSettings.outputSize
        let r = fitRect(CGSize(width: W, height: H), in: bounds)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
            if let img = state.previewImage {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }
            // anchor crosshair
            if !state.isPlaying, let job = state.job, job.plan.xforms.indices.contains(state.currentFrame) {
                let p = job.plan.xforms[state.currentFrame].p
                let x = r.minX + p.x / Double(W) * r.width, y = r.minY + p.y / Double(H) * r.height
                Crosshair().stroke(Theme.eye.opacity(0.55), lineWidth: 1).frame(width: 26, height: 26).position(x: x, y: y)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
    }
}

struct Crosshair: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.midY - 4))
        p.move(to: CGPoint(x: r.midX, y: r.midY + 4)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.midX - 4, y: r.midY))
        p.move(to: CGPoint(x: r.midX + 4, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        return p
    }
}

struct SourcePreview: View {
    @Environment(AppState.self) private var state
    var bounds: CGRect
    @State private var hover: CGPoint? = nil

    var body: some View {
        if let a = state.analysis, a.frames.indices.contains(state.currentFrame) {
            let f = a.frames[state.currentFrame]
            let r = fitRect(CGSize(width: f.pixelWidth, height: f.pixelHeight), in: bounds)
            let k = r.width / Double(f.pixelWidth)   // view px per source px
            ZStack(alignment: .topLeading) {
                if let img = state.sourceImage {
                    Image(decorative: img, scale: 1).resizable().interpolation(.high)
                        .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                } else {
                    Rectangle().fill(Color.black).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                }
                Canvas { ctx, _ in
                    drawOverlay(ctx: ctx, a: a, i: state.currentFrame, origin: r.origin, k: k)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { g in
                    let p = g.location
                    guard r.contains(p) else { return }
                    let src = V2((p.x - r.minX) / k, (p.y - r.minY) / k)
                    switch state.sourceTool {
                    case .fixEye: state.setManualEye(src)
                    case .pickBird: state.pickBird(at: src)
                    case .none: break
                    }
                }
            )
            .onContinuousHover { ph in
                if case .active(let p) = ph { hover = p } else { hover = nil }
            }
            .overlay {
                if state.sourceTool != .none, let h = hover, r.contains(h) {
                    Circle().stroke(state.sourceTool == .fixEye ? Theme.manual : Theme.accent, lineWidth: 1.5)
                        .frame(width: 22, height: 22).position(h).allowsHitTesting(false)
                }
            }
        }
    }

    private func drawOverlay(ctx: GraphicsContext, a: SequenceAnalysis, i: Int, origin: CGPoint, k: Double) {
        func pt(_ v: V2) -> CGPoint { CGPoint(x: origin.x + v.x * k, y: origin.y + v.y * k) }
        let fa = a.perFrame[i]
        // birds
        for (j, b) in fa.birds.enumerated() {
            let rect = CGRect(x: origin.x + b.x * k, y: origin.y + b.y * k, width: b.w * k, height: b.h * k)
            let isT = j == fa.target
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(isT ? Theme.ok : .yellow.opacity(0.6)),
                       style: StrokeStyle(lineWidth: isT ? 1.5 : 1, dash: isT ? [] : [4, 3]))
        }
        // output crop
        if let job = state.job, job.plan.xforms.indices.contains(i) {
            let (W, H) = job.outputSize
            let q = job.plan.xforms[i].sourceQuad(outW: Double(W), outH: Double(H))
            var p = Path(); p.move(to: pt(q[0])); for v in q.dropFirst() { p.addLine(to: pt(v)) }; p.closeSubpath()
            ctx.stroke(p, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        }
        // keypoints
        for kp in fa.keypoints where kp.conf > 0.2 {
            let c = pt(kp.p)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)), with: .color(Theme.bad.opacity(min(1, kp.conf + 0.2))))
        }
        guard let t = a.track, t.frames.indices.contains(i) else { return }
        let tf = t.frames[i]
        let hc = pt(tf.headCenter)
        ctx.stroke(Path(CGRect(x: hc.x - 5, y: hc.y - 5, width: 10, height: 10)), with: .color(Theme.accent.opacity(0.8)), lineWidth: 1)
        let e = pt(tf.eye)
        let rr = max(7, tf.headLength * k * 0.12)
        let color = a.manualEye[i] != nil ? Theme.manual : Theme.eye
        ctx.stroke(Path(ellipseIn: CGRect(x: e.x - rr, y: e.y - rr, width: 2 * rr, height: 2 * rr)), with: .color(color), lineWidth: 1.6)
        // short trail of the solved eye (previous frames)
        var trail = Path()
        let lo = max(0, i - 20)
        if i > lo {
            trail.move(to: pt(t.frames[lo].eye))
            for j in (lo + 1)...i { trail.addLine(to: pt(t.frames[j].eye)) }
            ctx.stroke(trail, with: .color(Theme.eye.opacity(0.35)), lineWidth: 1)
        }
    }
}

struct SourceToolBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.viewMode == .source, state.analysis != nil {
            HStack(spacing: 6) {
                toolButton(.fixEye, "scope", "修正鸟眼", "打开后，在图上点击鸟眼的准确位置（本帧作为强约束，前后帧自动重新计算）")
                toolButton(.pickBird, "hand.tap", "选择目标鸟", "画面里有多只鸟时，点击要跟踪的那只（会重新识别）")
                if let a = state.analysis, a.manualEye[state.currentFrame] != nil {
                    Button { state.clearManualEye() } label: { Label("清除本帧修正", systemImage: "arrow.uturn.backward") }
                        .controlSize(.small)
                }
                if let a = state.analysis, !a.manualEye.isEmpty {
                    Text("已修正 \(a.manualEye.count) 帧").font(.caption).foregroundStyle(Theme.manual)
                }
            }
            .padding(6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func toolButton(_ t: SourceTool, _ icon: String, _ title: String, _ help: String) -> some View {
        Button {
            state.sourceTool = state.sourceTool == t ? .none : t
        } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(.bordered)
        .tint(state.sourceTool == t ? Theme.accent : nil)
        .help(help)
    }
}

struct FrameBadges: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let job = state.job, job.status.indices.contains(state.currentFrame) {
            let st = job.status[state.currentFrame]
            let tf = job.track.frames[state.currentFrame]
            HStack(spacing: 6) {
                if st != .ok { badge(label(st), Theme.bad) }
                if state.analysis?.manualEye[state.currentFrame] != nil { badge("手动修正", Theme.manual) }
                else if tf.eyeVisible { badge("鸟眼", Theme.ok) }
                else if tf.hasData { badge("鸟头推算", Theme.warn) }
            }
        }
    }

    private func label(_ s: FrameStatus) -> String {
        switch s {
        case .ok: return ""
        case .excluded: return "已排除"
        case .blurry: return "模糊帧"
        case .untracked: return "未识别"
        case .trimmed: return "已裁掉"
        }
    }

    private func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(c.opacity(0.22), in: Capsule()).foregroundStyle(c)
    }
}
