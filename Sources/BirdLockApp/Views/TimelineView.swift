import SwiftUI
import BirdLockCore

struct TransportBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                Button { state.step(-1) } label: { Image(systemName: "backward.frame.fill").frame(width: 22) }.help("上一帧 ←")
                Button { state.togglePlay() } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 14)).frame(width: 28)
                }
                .help("播放 / 暂停（空格）")
                Button { state.step(1) } label: { Image(systemName: "forward.frame.fill").frame(width: 22) }.help("下一帧 →")
            }
            .buttonStyle(.borderless)
            Toggle(isOn: $state.loopPlayback) { Image(systemName: "repeat") }
                .toggleStyle(.button).buttonStyle(.borderless).help("循环播放")
            if (state.job?.mixedAudio(state.audio).isActive ?? state.audio.isActive) {
                Button { state.togglePreviewAudio() } label: {
                    Image(systemName: state.previewAudio ? "speaker.wave.2.fill" : "speaker.slash.fill").frame(width: 18)
                }
                .buttonStyle(.borderless).help(state.previewAudio ? "预览时静音" : "预览时播放音频")
            }

            if let a = state.analysis, a.frames.indices.contains(state.currentFrame) {
                Text("\(state.currentFrame + 1) / \(a.count)")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                Text(a.frames[state.currentFrame].fileName)
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let job = state.job {
                Text(String(format: "成片 %.1f 秒 · %d 帧 · 用 %d 张", job.duration, job.outputFrames.count, job.used.count))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider().frame(height: 16)
            HStack(spacing: 4) {
                Button { state.selection.trimStart = state.currentFrame } label: { Label("起点", systemImage: "arrow.right.to.line") }
                    .help("从当前帧开始（之前的帧不导出）")
                Button { state.selection.trimEnd = state.currentFrame } label: { Label("终点", systemImage: "arrow.left.to.line") }
                    .help("到当前帧结束")
                if state.selection.trimStart > 0 || state.selection.trimEnd != nil {
                    Button { state.selection.trimStart = 0; state.selection.trimEnd = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("清除起止点")
                }
                let excluded = state.analysis?.excluded.contains(state.currentFrame) == true
                Button { state.toggleExcluded() } label: {
                    Label(excluded ? "恢复" : "排除", systemImage: excluded ? "eye" : "eye.slash")
                }
                .help("排除 / 恢复当前帧（X）")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.bordered)
            .fixedSize()
            .layoutPriority(1)
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.panel)
    }
}

/// Bottom panel: the picture lane (frame status + curves) and the music lane, side by side in time.
struct TimelinePanel: View {
    @Environment(AppState.self) private var state
    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
          HStack(spacing: 0) {
            VStack(spacing: 0) {
                laneLabel("画面", "photo.on.rectangle").frame(height: 100)
                Divider()
                laneLabel("音乐", "music.note").frame(height: 48)
            }
            .frame(width: 52)
            Divider()
            VStack(spacing: 0) {
                FrameTimeline().frame(height: 100)
                Divider()
                AudioLane().frame(height: 48)
            }
          }.frame(height: 149)
          if !state.audio.tracks.isEmpty {
              ScrollView(.vertical) {
                  VStack(spacing: 1) {
                      ForEach($state.audio.tracks) { $track in
                          AudioTrackLane(track: $track, duration: state.job?.duration ?? 1,
                                         playhead: Double(state.playheadOutput) / state.exportSettings.outputFPS)
                              .frame(height: 32)
                      }
                  }
              }.frame(height: CGFloat(min(3, state.audio.tracks.count) * 33))
          }
        }
        // fixed height: the vertical divider would otherwise make the panel grow into the preview
        .frame(height: CGFloat(149 + min(3, state.audio.tracks.count) * 33))
        .background(Theme.panel.opacity(0.75))
    }

    private func laneLabel(_ t: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 12))
            Text(t).font(.caption2)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AudioTrackLane: View {
    @Binding var track: AudioTrack
    let duration: Double
    let playhead: Double
    @State private var dragStart: Double?

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: track.muted ? "speaker.slash" : "waveform").frame(width: 52)
            GeometryReader { geo in
                let width = max(1, geo.size.width - 24)
                let total = max(0.001, duration)
                let start = min(total, max(0, track.timelineStart))
                let span = track.duration > 0 ? min(track.duration, total - start) : total - start
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.12)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.accent.opacity(track.muted ? 0.12 : 0.35))
                        .frame(width: max(1, width * span / total), height: 26)
                        .overlay(alignment: .leading) {
                            Text(track.title).font(.caption2).lineLimit(1).padding(.horizontal, 5)
                        }
                        .offset(x: 12 + width * start / total, y: 3)
                        .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                            if dragStart == nil { dragStart = track.timelineStart }
                            track.timelineStart = max(0, min(total, (dragStart ?? 0) + value.translation.width / width * total))
                        }.onEnded { _ in dragStart = nil })
                    Rectangle().fill(Theme.accent).frame(width: 1, height: 32)
                        .offset(x: 12 + width * min(total, playhead) / total)
                        .allowsHitTesting(false)
                }.clipped()
            }
        }
    }
}

/// Frame status strip + curves (bird motion, size, sharpness) with a draggable playhead.
struct FrameTimeline: View {
    @Environment(AppState.self) private var state
    static let pad = 12.0

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            Canvas { ctx, size in
                draw(ctx: ctx, size: size)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard let a = state.analysis, a.count > 0 else { return }
                let x = clamp((g.location.x - Self.pad) / max(1, W - 2 * Self.pad), 0, 1)
                state.stop()
                state.seek(Int((x * Double(a.count - 1)).rounded()))
            })
            .frame(width: W, height: H)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard let a = state.analysis, let t = a.track, a.count > 0, t.frames.count == a.count else { return }
        let n = a.count
        let pad = Self.pad
        let w = size.width - 2 * pad
        func x(_ i: Int) -> Double { pad + (n == 1 ? 0 : Double(i) / Double(n - 1)) * w }
        let cellW = max(1, w / Double(n))
        let job = state.job
        for clip in (a.clips ?? []).dropFirst() {
            let px = x(clip.start)
            ctx.stroke(Path { $0.move(to: CGPoint(x: px,y: 4)); $0.addLine(to: CGPoint(x: px,y: size.height-18)) }, with: .color(Theme.accent), lineWidth: 1)
        }
        for shot in a.closeups ?? [] {
            let left = x(shot.frame), right = x(max(shot.frame,shot.endFrame))
            ctx.fill(Path(CGRect(x: left-cellW/2,y: 22,width: max(cellW,right-left+cellW),height: 4)), with: .color(Theme.manual))
        }

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
        curve(t.frames.map { $0.eye.x }, color: Theme.eye.opacity(0.85), label: state.isAircraft ? "机头 X" : "鸟眼 X", labelX: pad)
        curve(t.frames.map { $0.eye.y }, color: Theme.eye.opacity(0.45), label: state.isAircraft ? "机头 Y" : "鸟眼 Y", labelX: pad + 52)
        curve(t.frames.map { $0.headLength }, color: Theme.accent.opacity(0.8), label: state.isAircraft ? "机头大小" : "鸟头大小", labelX: pad + 104)
        curve(a.perFrame.map { $0.sharpness ?? .nan }, color: Color.white.opacity(0.35), label: "清晰度", labelX: pad + 168)

        // trim shading
        if let job {
            let s = min(job.selection.trimStart, n - 1), e = min(n - 1, job.selection.trimEnd ?? n - 1)
            if s > 0 { ctx.fill(Path(CGRect(x: pad, y: 0, width: x(s) - pad, height: size.height)), with: .color(.black.opacity(0.45))) }
            if e < n - 1 { ctx.fill(Path(CGRect(x: x(e), y: 0, width: size.width - pad - x(e), height: size.height)), with: .color(.black.opacity(0.45))) }
        }
        // playhead
        let px = x(min(state.currentFrame, n - 1))
        ctx.fill(Path(CGRect(x: px - 0.75, y: 2, width: 1.5, height: size.height - 4)), with: .color(Theme.accent))
        ctx.fill(Path(ellipseIn: CGRect(x: px - 4, y: 2, width: 8, height: 8)), with: .color(Theme.accent))
        // legend right
        let legend = Text(state.isAircraft ? "" : "●").foregroundColor(Theme.ok) + Text(state.isAircraft ? "" : " 鸟眼   ").foregroundColor(.secondary)
            + Text("●").foregroundColor(Theme.warn) + Text(state.isAircraft ? " 机头定位   " : " 鸟头推算   ").foregroundColor(.secondary)
            + Text("●").foregroundColor(Theme.manual) + Text(" 手动修正   ").foregroundColor(.secondary)
            + Text("●").foregroundColor(Theme.bad) + Text(" 未识别/模糊").foregroundColor(.secondary)
        ctx.draw(legend.font(.system(size: 9)), at: CGPoint(x: size.width - pad, y: size.height - 8), anchor: .trailing)
    }
}

func formatTime(_ t: Double) -> String {
    let t = max(0, t)
    return String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
}

/// Music lane: the whole song as a waveform; the highlighted window is the part that plays under the video.
/// Drag the window (or click somewhere) to choose which part of the music to use.
struct AudioLane: View {
    @Environment(AppState.self) private var state
    @State private var dragStartOffset: Double? = nil
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if state.audio.url == nil {
                Button { state.chooseAudio() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                        Text("添加背景音乐 — 点击选择，或把音频文件拖到这里")
                    }
                    .font(.caption).foregroundStyle(dropTargeted ? Theme.music : .secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundStyle(dropTargeted ? Theme.music : Color.white.opacity(0.15)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, FrameTimeline.pad).padding(.vertical, 7)
            } else {
                waveform
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                guard let u, isAudioFile(u) else { return }
                DispatchQueue.main.async { state.setAudio(u) }
            }
            return true
        }
    }

    private var waveform: some View {
        GeometryReader { geo in
            let pad = FrameTimeline.pad
            let W = geo.size.width - 2 * pad, H = geo.size.height
            let ov = state.audioOverview
            let D = max(0.1, ov?.duration ?? 1)
            let videoDur = state.job?.duration ?? 0
            let maxOffset = max(0, D - min(videoDur, D))
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    guard let ov else { return }
                    let off = state.audio.startOffset
                    func x(_ t: Double) -> Double { pad + t / D * W }
                    let mid = H / 2
                    // window
                    let wx0 = x(off), wx1 = x(min(D, off + videoDur))
                    let win = CGRect(x: wx0, y: 4, width: max(2, wx1 - wx0), height: H - 8)
                    ctx.fill(Path(roundedRect: win, cornerRadius: 4), with: .color(Theme.music.opacity(0.16)))
                    // bars
                    let bars = max(1, Int(W / 2))
                    for b in 0..<bars {
                        let t0 = Double(b) / Double(bars) * D, t1 = Double(b + 1) / Double(bars) * D
                        let i0 = Int(t0 * ov.binsPerSecond), i1 = max(i0 + 1, Int(t1 * ov.binsPerSecond))
                        guard i0 < ov.peaks.count else { break }
                        let peak = Double(ov.peaks[i0..<min(i1, ov.peaks.count)].max() ?? 0)
                        let h = max(1, pow(peak, 0.7) * (H / 2 - 7))
                        let inside = t0 >= off - 1e-6 && t1 <= off + videoDur + 1e-6
                        ctx.fill(Path(CGRect(x: pad + Double(b) * 2, y: mid - h, width: 1.2, height: 2 * h)),
                                 with: .color(inside ? Theme.music : Color.white.opacity(0.22)))
                    }
                    ctx.stroke(Path(roundedRect: win, cornerRadius: 4), with: .color(Theme.music), lineWidth: 1.2)
                    // the part that repeats when the video is longer than the rest of the song
                    if state.audio.loop, off + videoDur > D {
                        let rest = min(D, off + videoDur - D)
                        let r2 = CGRect(x: pad, y: 4, width: rest / D * W, height: H - 8)
                        ctx.stroke(Path(roundedRect: r2, cornerRadius: 4), with: .color(Theme.music.opacity(0.6)),
                                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    // playhead (output time)
                    if let job = state.job {
                        let tOut = Double(state.isPlaying ? state.playheadOutput : (job.outputFrames.firstIndex { $0.a >= state.currentFrame } ?? 0)) / job.export.outputFPS
                        var tm = off + tOut
                        if state.audio.loop, tm >= D { tm = (tm - D).truncatingRemainder(dividingBy: D) }
                        if tm <= D {
                            ctx.fill(Path(CGRect(x: x(tm) - 0.75, y: 2, width: 1.5, height: H - 4)), with: .color(Theme.accent))
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    guard ov != nil else { return }
                    if dragStartOffset == nil {
                        let t = Double((g.startLocation.x - pad) / W) * D
                        let off = state.audio.startOffset
                        // grabbing outside the window first centres it on the click
                        dragStartOffset = (t >= off && t <= off + videoDur) ? off : clamp(t - videoDur / 2, 0, maxOffset)
                    }
                    let dt = Double(g.translation.width / W) * D
                    state.audio.startOffset = clamp(dragStartOffset! + dt, 0, maxOffset)
                }.onEnded { _ in dragStartOffset = nil })
                .help("拖动高亮区域，选择音乐里要用的片段")

                // info + controls
                HStack(spacing: 6) {
                    Image(systemName: "music.note").foregroundStyle(Theme.music)
                    Text(state.audio.url?.deletingPathExtension().lastPathComponent ?? "").lineLimit(1).truncationMode(.middle)
                    if let ov {
                        Text("从 \(formatTime(state.audio.startOffset)) 开始 · 全曲 \(formatTime(ov.duration))").foregroundStyle(.secondary)
                    } else if let msg = state.audioMessage {
                        Text(msg).foregroundStyle(Theme.warn)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    Button { state.removeAudio() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("移除音乐")
                }
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.panel.opacity(0.85), in: Capsule())
                .padding(.leading, pad + 4).padding(.top, 2)
            }
        }
    }
}
