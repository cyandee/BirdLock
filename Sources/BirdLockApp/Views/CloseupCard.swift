import SwiftUI
import BirdLockCore

struct CloseupCard: View {
    @Environment(AppState.self) private var state
    var body: some View {
        InspectorCard(title: "关键帧特写", icon: "crop") {
            if state.segments.count > 1 {
                Text("片段播放顺序").font(.callout.bold())
                ForEach(Array(state.mergeGroupIndices.enumerated()), id: \.element) { position, group in
                    HStack {
                        Text("\(position + 1). 第 \(group + 1) 组")
                        Spacer()
                        Button { state.moveGroup(group, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(position == 0 || state.phase != .ready).help("提前播放")
                        Button { state.moveGroup(group, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(position == state.mergeGroupIndices.count - 1 || state.phase != .ready).help("延后播放")
                    }.controlSize(.small)
                }
                Text("在合并模式下按此顺序成片；也可先排好顺序再合并。").font(.caption).foregroundStyle(.secondary)
                Divider()
            }
            Button("将当前照片设为特写") { state.addCloseup() }.disabled(state.analysis == nil)
            Text("替换所选照片时段，不叠加外部视频。选择结束帧可替换一段；展示时长独立设置。放大和移动只影响该特写。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = state.timelineMessage { Text(message).font(.caption).foregroundStyle(Theme.warn) }
            ForEach(state.analysis?.closeups ?? []) { shot in
                Divider()
                CloseupEditor(shot: Binding(get: { state.analysis?.closeups?.first(where: { $0.id == shot.id }) ?? shot },
                    set: { state.updateCloseup($0) }), count: state.analysis?.count ?? 1,
                    select: { state.seek(shot.frame) }, remove: { state.removeCloseup(shot.id) })
            }
        }
    }
}

private struct CloseupEditor: View {
    @Binding var shot: Closeup
    var count: Int
    var select: () -> Void
    var remove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("预览第 \(shot.frame + 1) 帧特写", action: select)
                Spacer()
                Button(action: remove) { Image(systemName: "trash") }
            }.controlSize(.small)
            Stepper("起始照片：\(shot.frame + 1)", value: $shot.frame, in: 0...max(0,count-1))
            Stepper("替换至照片：\(shot.endFrame + 1)", value: $shot.endFrame, in: shot.frame...max(shot.frame,count-1))
            FormRow(label: "展示时长") {
                TextField("秒", value: $shot.seconds, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder).frame(width: 80)
                Text("秒").font(.caption)
            }
            LabeledSlider(title: "照片放大", value: $shot.zoom, range: 1...8, format: { String(format:"%.2f×",$0) })
            LabeledSlider(title: "构图横向", value: $shot.centerX, range: 0...1, format: { String(format:"%.0f%%",$0*100) })
            LabeledSlider(title: "构图纵向", value: $shot.centerY, range: 0...1, format: { String(format:"%.0f%%",$0*100) })
            Toggle("单张快门声", isOn: $shot.shutterEnabled)
            if shot.shutterEnabled {
                LabeledSlider(title: "快门音量", value: $shot.shutterVolume, range: 0...1.5, format: { String(format:"%.0f%%",$0*100) })
            }
            Toggle("动态特写框", isOn: $shot.animatedFrame)
            Picker("特写框颜色", selection: $shot.color) {
                ForEach(FocusMarkColor.allCases) { Text($0.title).tag($0) }
            }
        }
    }
}
