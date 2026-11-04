import SwiftUI
import BirdLockCore

struct TrackingCard: View {
    @Environment(AppState.self) private var state
    var body: some View {
        if state.subject != .aircraft {
            InspectorCard(title:state.isCustom ? "自定义目标跟踪" : "鸟眼选择",icon:"scope") {
                if state.isCustom {
                    Text("先框选稳定区域，再点选框内锁定位置。可从任意一张照片开始，失锁处补选关键帧。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("框选目标 / 添加关键帧") { state.beginCustomBox() }
                    if let a=state.analysis {
                        Text("本组 \((a.customSeeds ?? []).filter { a.clipRange(containing:state.currentFrame).contains($0.frame) }.count) 个参考关键帧").font(.caption)
                        if (a.customSeeds ?? []).contains(where: { $0.frame==state.currentFrame }) {
                            Button("移除当前参考关键帧") { state.removeCustomSeed() }
                        }
                    }
                } else {
                    Text(state.analysis?.selectedEye(at:state.currentFrame)==nil ? "自动：随可见性选择眼睛" : "本组已固定同一只眼睛")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("在原图点选要固定的眼睛") { state.beginPickingEye() }
                    HStack {
                        Button("恢复自动") { state.automaticEye() }
                        if state.eyeUndo?.fingerprint==state.analysis?.fingerprint { Button("撤销选眼") { state.undoEyeSelection() } }
                    }
                    Text("可先查看末尾照片再选眼；现有手动修正优先保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message=state.timelineMessage { Text(message).font(.caption).foregroundStyle(Theme.warn) }
            }
            .disabled(state.phase != .ready)
        }
    }
}
