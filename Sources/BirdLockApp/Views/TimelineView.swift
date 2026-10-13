import SwiftUI
import BirdLockCore

struct TransportBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 12) {
            Button { state.step(-1) } label: { Image(systemName: "backward.frame.fill") }.help("上一帧 ←")
            Button { state.togglePlay() } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("播放 / 暂停（空格）")
            Button { state.step(1) } label: { Image(systemName: "forward.frame.fill") }.help("下一帧 →")
            Toggle(isOn: $state.loopPlayback) { Image(systemName: "repeat") }
                .toggleStyle(.button).help("循环播放")

            if let a = state.analysis {
                Text("帧 \(state.currentFrame + 1) / \(a.count)")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                Text(a.frames[state.currentFrame].fileName)
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if let job = state.job {
                Text(String(format: "成片 %.1f 秒 · %d 帧 · 使用 %d 张", job.duration, job.outputFrames.count, job.used.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider().frame(height: 16)
            Button("设为起点") { state.selection.trimStart = state.currentFrame }
                .help("从当前帧开始（之前的帧不导出）")
            Button("设为终点") { state.selection.trimEnd = state.currentFrame }
                .help("到当前帧结束")
            if state.selection.trimStart > 0 || state.selection.trimEnd != nil {
                Button { state.selection.trimStart = 0; state.selection.trimEnd = nil } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("清除起止点")
            }
            Button {
                state.toggleExcluded()
            } label: {
                Label(state.analysis?.excluded.contains(state.currentFrame) == true ? "恢复此帧" : "排除此帧", systemImage: "eye.slash")
            }
            .help("排除 / 恢复当前帧（X）")
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Theme.panel)
    }
}

/// Frame status strip + curves (bird motion, size, sharpness) with a draggable playhead.
struct TimelineView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            Canvas { ctx, size in
                draw(ctx: ctx, size: size)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard let a = state.analysis, a.count > 0 else { return }
                let pad = 14.0
                let x = clamp((g.location.x - pad) / max(1, W - 2 * pad), 0, 1)
                state.stop()
                state.seek(Int((x * Double(a.count - 1)).rounded()))
            })
            .frame(width: W, height: H)
        }
        .background(Theme.panel.opacity(0.7))
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard let a = state.analysis, let t = a.track, a.count > 0 else { return }
        let n = a.count
        let pad = 14.0
        let w = size.width - 2 * pad
        func x(_ i: Int) -> Double { pad + (n == 1 ? 0 : Double(i) / Double(n - 1)) * w }
        let cellW = max(1, w / Double(n))
        let job = state.job

        // Status strip
        let stripY = 8.0, stripH = 12.0
        for i in 0..<n {
            var c: Color
            let st = job?.status.indices.contains(i) == true ? job!.status[i] : .ok
            switch st {
            case .ok:
                if a.manualEye[i] != nil { c = Theme.manual }
                else if t.frames[i].eyeVisible { c = Theme.ok }
                else if t.frames[i].hasData { c = Theme.warn }
                else { c = Theme.bad }
            case .blurry: c = Theme.bad.opacity(0.55)
            case .untracked: c = Theme.bad
            case .excluded, .trimmed: c = Color.white.opacity(0.12)
            }
            ctx.fill(Path(CGRect(x: x(i) - cellW / 2, y: stripY, width: cellW + 0.5, height: stripH)), with: .color(c))
        }

        // Curves area
        let top = stripY + stripH + 8, bottom = size.height - 18
        let ch = bottom - top
        func curve(_ v: [Double], color: Color, label: String, labelX: Double) {
            let fin = v.filter { $0.isFinite }
            guard let lo = fin.min(), let hi = fin.max(), hi > lo else { return }
            var p = Path()
            var started = false
            for i in 0..<n where v[i].isFinite {
                let y = bottom - (v[i] - lo) / (hi - lo) * ch
                if !started { p.move(to: CGPoint(x: x(i), y: y)); started = true } else { p.addLine(to: CGPoint(x: x(i), y: y)) }
            }
            ctx.stroke(p, with: .color(color), lineWidth: 1.2)
            ctx.draw(Text(label).font(.system(size: 9)).foregroundColor(color), at: CGPoint(x: labelX, y: size.height - 8), anchor: .leading)
        }
        // Eye motion in the source frame (camera shake + flight) – horizontal & vertical
        curve(t.frames.map { $0.eye.x }, color: Theme.eye.opacity(0.85), label: "鸟眼 X", labelX: pad)
        curve(t.frames.map { $0.eye.y }, color: Theme.eye.opacity(0.45), label: "鸟眼 Y", labelX: pad + 52)
        curve(t.frames.map { $0.headLength }, color: Theme.accent.opacity(0.8), label: "鸟头大小", labelX: pad + 104)
        curve(a.perFrame.map { $0.sharpness ?? .nan }, color: Color.white.opacity(0.35), label: "清晰度", labelX: pad + 168)

        // trim shading
        if let job {
            let s = job.selection.trimStart, e = min(n - 1, job.selection.trimEnd ?? n - 1)
            if s > 0 { ctx.fill(Path(CGRect(x: pad, y: 0, width: x(s) - pad, height: size.height)), with: .color(.black.opacity(0.45))) }
            if e < n - 1 { ctx.fill(Path(CGRect(x: x(e), y: 0, width: size.width - pad - x(e), height: size.height)), with: .color(.black.opacity(0.45))) }
        }
        // playhead
        let px = x(state.currentFrame)
        ctx.fill(Path(CGRect(x: px - 0.75, y: 2, width: 1.5, height: size.height - 4)), with: .color(Theme.accent))
        ctx.fill(Path(ellipseIn: CGRect(x: px - 4, y: 2, width: 8, height: 8)), with: .color(Theme.accent))
        // legend right
        let legend = Text("●").foregroundColor(Theme.ok) + Text(" 鸟眼   ").foregroundColor(.secondary)
            + Text("●").foregroundColor(Theme.warn) + Text(" 鸟头推算   ").foregroundColor(.secondary)
            + Text("●").foregroundColor(Theme.manual) + Text(" 手动修正   ").foregroundColor(.secondary)
            + Text("●").foregroundColor(Theme.bad) + Text(" 未识别/模糊").foregroundColor(.secondary)
        ctx.draw(legend.font(.system(size: 9)), at: CGPoint(x: size.width - pad, y: size.height - 8), anchor: .trailing)
    }
}
