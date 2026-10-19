import SwiftUI
import BirdLockCore

struct MusicCueCard: View {
    @Environment(AppState.self) private var state
    @State private var cueID = ""
    @State private var candidate = -1
    @State private var message: String?

    var body: some View {
        InspectorCard(title: "音乐卡点辅助", icon: "waveform.path") {
            Text("根据音乐能量变化提供节拍和高潮候选，需试听确认。画面候选综合清晰度与主体展开程度，不代表语义识别。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let included = state.job.map { Set($0.outputFrames.map(\.a)) }
            let visual = state.analysis.map { MusicCues.visualCandidates($0, included: included) } ?? []
            Picker("画面候选", selection: $candidate) {
                Text("选择画面").tag(-1)
                ForEach(visual, id: \.self) { Text("第 \($0 + 1) 帧").tag($0) }
            }
            Button("跳到画面候选") { if candidate >= 0 { state.seek(candidate) } }.disabled(candidate < 0)
            Picker("音乐候选", selection: $cueID) {
                Text("选择音乐位置").tag("")
                ForEach(state.musicCues.sorted { $0.climax && !$1.climax }) { cue in
                    Text("\(cue.climax ? "高潮候选" : "节拍候选") · \(formatTime(cue.time))").tag(cue.id)
                }
            }
            Button("音乐候选对齐当前画面") { align() }.disabled(cueID.isEmpty || state.job == nil)
            if state.musicCues.isEmpty {
                Text("请添加背景音乐，或音乐变化不足以产生候选。").font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.caption).foregroundStyle(Theme.warn) }
            Color.clear.frame(height: 0)
                .onChange(of: visual) { _, values in if !values.contains(candidate) { candidate = -1 } }
                .onChange(of: state.musicCues) { _, values in if !values.contains(where: { $0.id == cueID }) { cueID = "" } }
        }
    }

    private func align() {
        guard let cue = state.musicCues.first(where: { $0.id == cueID }), let job = state.job else { return }
        let position = state.isPlaying ? Double(state.playheadOutput) / job.export.outputFPS : ProjectTimeline.sourceTime(state.currentFrame, outputFrames: job.outputFrames, closeups: job.analysis.closeups ?? [])
        guard let time = position else { message = "当前照片未出现在成片中，请选择有效画面。"; return }
        guard cue.time >= time else { message = "该音乐候选早于当前画面，请选择更早的画面。"; return }
        state.audio.startOffset = cue.time - time
        message = nil
    }
}
