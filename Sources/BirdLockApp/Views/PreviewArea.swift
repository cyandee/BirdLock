import SwiftUI
import AppKit
import BirdLockCore

/// Fits an image of `size` into `bounds` (aspect fit) and returns the drawn rect.
func fitRect(_ size: CGSize, in bounds: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0 else { return .zero }
    let s = min(bounds.width / size.width, bounds.height / size.height)
    let w = size.width * s, h = size.height * s
    return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
}

/// Keeps one pushed NSCursor for hover feedback.
@MainActor
final class CursorKeeper {
    static let shared = CursorKeeper()
    private var current: NSCursor?
    func set(_ c: NSCursor?) {
        guard c !== current else { return }
        if current != nil { NSCursor.pop() }
        current = c
        c?.push()
    }
}

struct PreviewArea: View {
    @Environment(AppState.self) private var state

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size).insetBy(dx: 20, dy: 18)
            ZStack {
                if state.viewMode == .output {
                    OutputPreview(bounds: bounds)
                } else {
                    SourcePreview(bounds: bounds, viewSize: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .overlay(alignment: .topLeading) { SourceToolBar().padding(12) }
        .overlay(alignment: .topTrailing) { FrameBadges().padding(12) }
        .overlay(alignment: .bottom) { PreviewHint().padding(.bottom, 10) }
    }
}

// MARK: - Output preview (with draggable watermark)

struct OutputPreview: View {
    @Environment(AppState.self) private var state
    var bounds: CGRect
    @State private var wmDrag: (center: CGPoint, size: Double, resizing: Bool)? = nil
    @State private var wmHover = false

    var body: some View {
        let (W, H) = state.exportSettings.outputSize
        let r = fitRect(CGSize(width: W, height: H), in: bounds)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
            if let img = state.previewImage {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }
            // anchor crosshair
            if !state.isPlaying, !state.exportSettings.focusMark.enabled, let job = state.job, job.contains(state.currentFrame) {
                let p = job.plan.xforms[state.currentFrame].p
                let x = r.minX + p.x / Double(W) * r.width, y = r.minY + p.y / Double(H) * r.height
                Crosshair().stroke(Theme.eye.opacity(0.55), lineWidth: 1).frame(width: 26, height: 26).position(x: x, y: y)
                    .allowsHitTesting(false)
            }
            watermarkLayer(r)
        }
        .coordinateSpace(name: "output")
    }

    @ViewBuilder private func watermarkLayer(_ r: CGRect) -> some View {
        if state.watermark.isActive, let img = state.watermarkImage {
            let wm = state.watermark
            let size = wmDrag?.size ?? wm.size
            let cx = wmDrag.map { Double($0.center.x) } ?? wm.centerX
            let cy = wmDrag.map { Double($0.center.y) } ?? wm.centerY
            let rect = wm.moved(centerX: cx, centerY: cy, size: size).rect(imageSize: CGSize(width: img.width, height: img.height), outW: r.width, outH: r.height)
                .offsetBy(dx: r.minX, dy: r.minY)
            let editing = !state.isPlaying && (wmHover || wmDrag != nil)
            // hit area = the watermark itself (+ a small margin for the resize handle)
            Image(decorative: img, scale: 1).resizable().interpolation(.high)
                .opacity(wm.opacity)
                .frame(width: rect.width, height: rect.height)
                .overlay {
                    if editing {
                        Rectangle().strokeBorder(Theme.accent.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .padding(-4)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if editing {
                        Circle().fill(Theme.accent).frame(width: 10, height: 10).overlay(Circle().stroke(Color.black.opacity(0.5)))
                            .offset(x: 9, y: 9)
                    }
                }
                .padding(10)
                .contentShape(Rectangle())
                .onHover { wmHover = $0; CursorKeeper.shared.set($0 ? .openHand : nil) }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("output")).onChanged { g in
                    if wmDrag == nil {
                        let nearHandle = hypot(g.startLocation.x - (rect.maxX + 4), g.startLocation.y - (rect.maxY + 4)) < 14
                        wmDrag = (CGPoint(x: wm.centerX, y: wm.centerY), wm.size, nearHandle)
                    }
                    guard var d = wmDrag else { return }
                    if d.resizing {
                        // distance from the centre sets the size
                        let c = CGPoint(x: r.minX + wm.centerX * r.width, y: r.minY + wm.centerY * r.height)
                        let r0 = hypot(g.startLocation.x - c.x, g.startLocation.y - c.y)
                        let r1 = hypot(g.location.x - c.x, g.location.y - c.y)
                        d.size = clamp(wm.size * Double(r1 / max(1, r0)), 0.03, 1.5)
                    } else {
                        var x = wm.centerX + Double(g.translation.width / r.width)
                        var y = wm.centerY + Double(g.translation.height / r.height)
                        // snap to the centre lines
                        if abs(x - 0.5) < 0.012 { x = 0.5 }
                        if abs(y - 0.5) < 0.012 { y = 0.5 }
                        d.center = CGPoint(x: clamp(x, 0, 1), y: clamp(y, 0, 1))
                    }
                    wmDrag = d
                }.onEnded { _ in
                    if let d = wmDrag {
                        var w = state.watermark
                        w.centerX = Double(d.center.x); w.centerY = Double(d.center.y); w.size = d.size
                        state.watermark = w
                    }
                    wmDrag = nil
                })
                .position(x: rect.midX, y: rect.midY)
            .help("拖动水印调整位置，拖动右下角圆点调整大小")
        }
    }
}

extension WatermarkSettings {
    func moved(centerX: Double, centerY: Double, size: Double) -> WatermarkSettings {
        var w = self
        w.centerX = centerX; w.centerY = centerY; w.size = size
        return w
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

// MARK: - Source preview (detections, crop editing, eye correction)

/// Maps source pixels <-> view points for the (possibly zoomed) source view.
struct SourceMapping {
    var s: Double          // view pt per source px
    var origin: CGPoint    // view position of source (0, 0)
    var imageSize: CGSize
    func view(_ v: V2) -> CGPoint { CGPoint(x: origin.x + v.x * s, y: origin.y + v.y * s) }
    func src(_ p: CGPoint) -> V2 { V2((p.x - origin.x) / s, (p.y - origin.y) / s) }
    var imageRect: CGRect { CGRect(x: origin.x, y: origin.y, width: imageSize.width * s, height: imageSize.height * s) }
    func rect(_ r: CGRect) -> CGRect { CGRect(x: origin.x + r.minX * s, y: origin.y + r.minY * s, width: r.width * s, height: r.height * s) }
}

struct SourcePreview: View {
    @Environment(AppState.self) private var state
    var bounds: CGRect
    var viewSize: CGSize
    @State private var hover: CGPoint? = nil
    @State private var drag: DragKind? = nil
    @State private var ghostEye: V2? = nil
    @State private var ghostQuad: [V2]? = nil
    @State private var zoomCenter: (frame: Int, zoom: Double, c: V2)? = nil

    enum DragKind { case eye, place, pick, move(start: [V2]), scale(start: [V2], center: V2), none }

    var body: some View {
        if let a = state.analysis, a.frames.indices.contains(state.currentFrame) {
            let i = state.currentFrame
            let f = a.frames[i]
            let m = mapping(a, i)
            ZStack(alignment: .topLeading) {
                Color.clear
                if let img = state.sourceImage {
                    Image(decorative: img, scale: 1).resizable().interpolation(.high)
                        .frame(width: m.imageRect.width, height: m.imageRect.height)
                        .position(x: m.imageRect.midX, y: m.imageRect.midY)
                } else {
                    Rectangle().fill(Color.black).frame(width: m.imageRect.width, height: m.imageRect.height)
                        .position(x: m.imageRect.midX, y: m.imageRect.midY)
                }
                if let d = state.sourceDetail, d.frame == i {
                    let dr = m.rect(d.rect)
                    Image(decorative: d.image, scale: 1).resizable().interpolation(.high)
                        .frame(width: dr.width, height: dr.height).position(x: dr.midX, y: dr.midY)
                }
                Canvas { ctx, _ in drawOverlay(ctx: ctx, a: a, i: i, m: m) }
                    .allowsHitTesting(false)
                if state.sourceTool != .none, let h = hover, drag == nil, m.imageRect.contains(h) {
                    Circle().stroke(state.sourceTool == .fixEye ? Theme.manual : Theme.accent, lineWidth: 1.5)
                        .frame(width: 22, height: 22).position(h).allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(a: a, i: i, m: m))
            .simultaneousGesture(MagnifyGesture().onEnded { g in
                let z = state.sourceZoom * Double(g.magnification)
                state.sourceZoom = z < 1.3 ? 1 : clamp(z, 1, 12)
            })
            .onContinuousHover { ph in
                if case .active(let p) = ph { hover = p; updateCursor(at: p, a: a, i: i, m: m) } else { hover = nil; CursorKeeper.shared.set(nil) }
            }
            .onDisappear { CursorKeeper.shared.set(nil) }
            .task(id: "\(i)|\(state.sourceZoom)|\(Int(viewSize.width))x\(Int(viewSize.height))") {
                guard state.sourceZoom > 1.01 else { return }
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                let vis = CGRect(x: (bounds.minX - m.origin.x) / m.s, y: (bounds.minY - m.origin.y) / m.s,
                                 width: bounds.width / m.s, height: bounds.height / m.s).insetBy(dx: -bounds.width / m.s * 0.1, dy: -bounds.height / m.s * 0.1)
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                state.requestSourceDetail(region: vis.intersection(CGRect(x: 0, y: 0, width: f.pixelWidth, height: f.pixelHeight)),
                                          pixelsAcross: Double(vis.width) * m.s * scale)
            }
        }
    }

    private func mapping(_ a: SequenceAnalysis, _ i: Int) -> SourceMapping {
        let f = a.frames[i]
        let size = CGSize(width: f.pixelWidth, height: f.pixelHeight)
        let fit = fitRect(size, in: bounds)
        let k = fit.width / Double(f.pixelWidth)
        let z = max(1, state.sourceZoom)
        guard z > 1.01 else { return SourceMapping(s: k, origin: fit.origin, imageSize: size) }
        let s = k * z
        // follow the head (fixed per frame, so a correction does not move the view)
        var c: V2
        if let zc = zoomCenter, zc.frame == i, zc.zoom == z { c = zc.c }
        else {
            c = a.track.map { $0.frames[i].headCenter } ?? V2(size.width / 2, size.height / 2)
            DispatchQueue.main.async { zoomCenter = (i, z, c) }
        }
        let hw = bounds.width / (2 * s), hh = bounds.height / (2 * s)
        c.x = size.width > 2 * hw ? clamp(c.x, hw, size.width - hw) : size.width / 2
        c.y = size.height > 2 * hh ? clamp(c.y, hh, size.height - hh) : size.height / 2
        return SourceMapping(s: s, origin: CGPoint(x: bounds.midX - c.x * s, y: bounds.midY - c.y * s), imageSize: size)
    }

    private func cropQuad(_ i: Int) -> [V2]? {
        guard let job = state.job, job.contains(i) else { return nil }
        let (W, H) = job.outputSize
        return job.plan.xforms[i].sourceQuad(outW: Double(W), outH: Double(H))
    }

    private enum Hit { case eye, corner(Int), inside, nothing }

    private func hitTest(_ p: CGPoint, a: SequenceAnalysis, i: Int, m: SourceMapping) -> Hit {
        if let t = a.track, t.frames.indices.contains(i) {
            let e = m.view(t.frames[i].eye)
            if hypot(p.x - e.x, p.y - e.y) < max(10, eyeRadius(t.frames[i], m) + 3) { return .eye }
        }
        guard let q = cropQuad(i) else { return .nothing }
        let vq = q.map { m.view($0) }
        for (k, c) in vq.enumerated() where hypot(p.x - c.x, p.y - c.y) < 11 { return .corner(k) }
        return pointInQuad(p, vq) ? .inside : .nothing
    }

    private func updateCursor(at p: CGPoint, a: SequenceAnalysis, i: Int, m: SourceMapping) {
        guard drag == nil else { return }
        switch state.sourceTool {
        case .fixEye, .pickBird: CursorKeeper.shared.set(.crosshair)
        case .none:
            switch hitTest(p, a: a, i: i, m: m) {
            case .eye: CursorKeeper.shared.set(.pointingHand)
            case .corner: CursorKeeper.shared.set(.crosshair)
            case .inside: CursorKeeper.shared.set(.openHand)
            case .nothing: CursorKeeper.shared.set(nil)
            }
        }
    }

    private func dragGesture(a: SequenceAnalysis, i: Int, m: SourceMapping) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { g in
            if drag == nil {
                let hit = hitTest(g.startLocation, a: a, i: i, m: m)
                switch state.sourceTool {
                case .pickBird: drag = .pick
                case .fixEye:
                    drag = .place
                case .none:
                    switch hit {
                    case .eye: drag = .eye
                    case .corner:
                        if let q = cropQuad(i) {
                            let c = q.reduce(V2(0, 0), +) / Double(q.count)
                            drag = .scale(start: q, center: c); state.beginCropEdit()
                        }
                    case .inside:
                        if let q = cropQuad(i) { drag = .move(start: q); state.beginCropEdit(); CursorKeeper.shared.set(.closedHand) }
                    case .nothing: drag = DragKind.none
                    }
                }
            }
            let cur = m.src(g.location), start = m.src(g.startLocation)
            switch drag {
            case .eye?, .place?: ghostEye = cur
            case .move(let q)?:
                let d = cur - start
                ghostQuad = q.map { $0 + d }
                state.moveCrop(by: d)
            case .scale(let q, let c)?:
                let r = (cur - c).length / max(1, (start - c).length)
                ghostQuad = q.map { c + ($0 - c) * r }
                state.scaleCrop(by: r)
            default: break
            }
        }
        .onEnded { g in
            let p = m.src(g.location)
            switch drag {
            case .eye?, .place?:
                if m.imageRect.contains(g.location) { state.setManualEye(p, frame: i) }
            case .pick?:
                if m.imageRect.contains(g.location) { state.pickBird(at: p) }
            case .move?, .scale?: state.endCropEdit()
            default: break
            }
            drag = nil; ghostEye = nil; ghostQuad = nil
            if let h = hover { updateCursor(at: h, a: a, i: i, m: m) }
        }
    }

    private func eyeRadius(_ tf: TrackFrame, _ m: SourceMapping) -> Double { max(7, tf.headLength * m.s * 0.12) }

    private func drawOverlay(ctx: GraphicsContext, a: SequenceAnalysis, i: Int, m: SourceMapping) {
        let fa = a.perFrame[i]
        // birds
        for (j, b) in fa.birds.enumerated() {
            let rect = m.rect(b.rect)
            let isT = j == fa.target
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(isT ? Theme.ok.opacity(0.8) : .yellow.opacity(0.6)),
                       style: StrokeStyle(lineWidth: isT ? 1.2 : 1, dash: isT ? [] : [4, 3]))
        }
        // output crop (+ handles), or the ghost while dragging
        if let q = ghostQuad ?? cropQuad(i) {
            let vq = q.map { m.view($0) }
            var p = Path(); p.move(to: vq[0]); for v in vq.dropFirst() { p.addLine(to: v) }; p.closeSubpath()
            // dim everything outside the crop
            var outside = Path(m.imageRect); outside.addPath(p)
            ctx.fill(outside, with: .color(.black.opacity(0.35)), style: FillStyle(eoFill: true))
            ctx.stroke(p, with: .color(ghostQuad != nil ? Theme.accent : .white.opacity(0.85)), style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
            if state.sourceTool == .none {
                for c in vq {
                    let r = CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)
                    ctx.fill(Path(r), with: .color(.white))
                    ctx.stroke(Path(r), with: .color(.black.opacity(0.5)), lineWidth: 1)
                }
            }
        }
        // keypoints
        for kp in fa.keypoints where kp.conf > 0.2 {
            let c = m.view(kp.p)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)), with: .color(Theme.bad.opacity(min(1, kp.conf + 0.2))))
        }
        guard let t = a.track, t.frames.indices.contains(i) else { return }
        let tf = t.frames[i]
        let hc = m.view(tf.headCenter)
        ctx.stroke(Path(CGRect(x: hc.x - 5, y: hc.y - 5, width: 10, height: 10)), with: .color(Theme.accent.opacity(0.8)), lineWidth: 1)
        // short trail of the solved eye (previous frames)
        var trail = Path()
        let lo = max(0, i - 20)
        if i > lo {
            trail.move(to: m.view(t.frames[lo].eye))
            for j in (lo + 1)...i { trail.addLine(to: m.view(t.frames[j].eye)) }
            ctx.stroke(trail, with: .color(Theme.eye.opacity(0.35)), lineWidth: 1)
        }
        let rr = eyeRadius(tf, m)
        let manual = a.manualEye[i] != nil
        let color = manual ? Theme.manual : (tf.eyeVisible ? Theme.eye : Theme.warn)
        let e = m.view(tf.eye)
        if let g = ghostEye {
            // original position faded, new position live
            ctx.stroke(Path(ellipseIn: CGRect(x: e.x - rr, y: e.y - rr, width: 2 * rr, height: 2 * rr)), with: .color(color.opacity(0.3)), lineWidth: 1)
            let gp = m.view(g)
            ctx.stroke(Path(ellipseIn: CGRect(x: gp.x - rr, y: gp.y - rr, width: 2 * rr, height: 2 * rr)), with: .color(Theme.manual), lineWidth: 2)
            ctx.fill(Path(ellipseIn: CGRect(x: gp.x - 1.5, y: gp.y - 1.5, width: 3, height: 3)), with: .color(Theme.manual))
        } else {
            ctx.stroke(Path(ellipseIn: CGRect(x: e.x - rr, y: e.y - rr, width: 2 * rr, height: 2 * rr)), with: .color(color), lineWidth: 1.6)
            ctx.fill(Path(ellipseIn: CGRect(x: e.x - 1.5, y: e.y - 1.5, width: 3, height: 3)), with: .color(color))
        }
    }
}

private func pointInQuad(_ p: CGPoint, _ q: [CGPoint]) -> Bool {
    var inside = false
    var j = q.count - 1
    for i in 0..<q.count {
        if (q[i].y > p.y) != (q[j].y > p.y),
           p.x < (q[j].x - q[i].x) * (p.y - q[i].y) / (q[j].y - q[i].y) + q[i].x { inside.toggle() }
        j = i
    }
    return inside
}

// MARK: - Overlays

struct SourceToolBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.viewMode == .source, let a = state.analysis {
            let predicted = state.predictedFrames
            HStack(spacing: 6) {
                toolButton(.fixEye, "scope", state.isAircraft ? "修正机头" : "修正鸟眼", state.isAircraft ? "点击当前帧机头的准确位置（E）" : "点击（或拖动）到鸟眼的准确位置。本帧作为强约束，前后帧自动重新计算（E）")
                toolButton(.pickBird, "hand.tap", state.isAircraft ? "选择飞机" : "选择目标鸟", "点击要跟踪的主体（会重新识别）")
                Divider().frame(height: 18)
                Picker("", selection: Binding(get: { zoomStep }, set: { state.sourceZoom = $0 })) {
                    Text("全图").tag(1.0)
                    Text("2×").tag(2.0)
                    Text("4×").tag(4.0)
                    Text("8×").tag(8.0)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("放大查看锁定区域（跟随锁定点，逐帧检查时很方便）。触控板可双指缩放（Z 切换）")
                if !predicted.isEmpty {
                    Divider().frame(height: 18)
                    Button { state.jumpToPredicted(-1) } label: { Image(systemName: "chevron.left") }.help("上一个推算帧 [")
                    Text("推算 \(predicted.count) 帧").font(.caption.monospacedDigit()).foregroundStyle(Theme.warn)
                    Button { state.jumpToPredicted(1) } label: { Image(systemName: "chevron.right") }.help("下一个推算帧 ]")
                }
                if a.manualEye[state.currentFrame] != nil {
                    Divider().frame(height: 18)
                    Button { state.clearManualEye() } label: { Label("撤销本帧修正", systemImage: "arrow.uturn.backward") }
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .padding(6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var zoomStep: Double {
        let z = state.sourceZoom
        return [1.0, 2, 4, 8].min { abs($0 - z) < abs($1 - z) }!
    }

    private func toolButton(_ t: SourceTool, _ icon: String, _ title: String, _ help: String) -> some View {
        Button {
            state.sourceTool = state.sourceTool == t ? .none : t
        } label: {
            Label(title, systemImage: icon)
        }
        .tint(state.sourceTool == t ? Theme.accent : nil)
        .help(help)
    }
}

struct PreviewHint: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let text = hint {
            Text(text).font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .allowsHitTesting(false)
        }
    }

    private var hint: String? {
        guard !state.isPlaying else { return nil }
        if state.viewMode == .source {
            switch state.sourceTool {
            case .fixEye: if state.isAircraft { return "点击当前帧机头的准确位置，可拖动微调" };return "在鸟眼的准确位置点击（可按住拖动微调）· 推算不准的帧逐一修正后，前后帧会自动跟着重算"
            case .pickBird: return state.isAircraft ? "点击要跟踪的飞机" : "点击要跟踪的鸟"
            case .none: return "拖动虚线框移动取景 · 拖动四角缩放取景范围 · 拖动圆圈修正锁定点"
            }
        }
        if state.watermark.isActive && state.watermarkImage != nil { return "拖动水印调整位置，拖动右下角圆点调整大小" }
        return nil
    }
}

struct FrameBadges: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let job = state.job, job.status.indices.contains(state.currentFrame), let a = state.analysis,
           let t = a.track, t.frames.indices.contains(state.currentFrame) {
            let i = state.currentFrame
            let st = job.status[i]
            let tf = t.frames[i]
            HStack(spacing: 6) {
                if st != .ok { badge(label(st), Theme.bad) }
                if a.manualEye[i] != nil { badge("手动修正", Theme.manual) }
                else if state.isAircraft {
                    badge(tf.hasData ? (a.perFrame[i].aircraft?.source == .tracked ? "机头跟踪" : "机头识别") : "未定位机头", tf.hasData ? Theme.ok : Theme.warn)
                    Button("修正机头") { state.startFixingEye() }.controlSize(.small)
                }
                else if tf.eyeVisible { badge("鸟眼", Theme.ok) }
                else if tf.hasData {
                    badge("鸟头推算", Theme.warn)
                        .help("这一帧鸟眼被遮挡，位置是根据鸟头其他部位推算的")
                    if !(state.viewMode == .source && state.sourceTool == .fixEye) {
                        Button { state.startFixingEye() } label: { Label("修正", systemImage: "scope") }
                            .controlSize(.small).buttonStyle(.borderedProminent).tint(Theme.manual)
                            .help("切换到原图并放大，点击鸟眼的准确位置（E）")
                    }
                } else if st == .untracked {
                    Button { state.startFixingEye() } label: { Label("手动标记鸟眼", systemImage: "scope") }
                        .controlSize(.small).buttonStyle(.bordered)
                        .help("这一帧没有识别到鸟。手动标记后这一帧也能用在成片里")
                }
            }
            .fixedSize()
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
            .background(c.opacity(0.22), in: Capsule())
            .background(Color.black.opacity(0.55), in: Capsule())
            .foregroundStyle(c)
    }
}
