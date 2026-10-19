import Foundation
import BirdLockCore

extension AppState {
    func addCloseup() {
        guard var a = analysis, a.frames.indices.contains(currentFrame) else { return }
        var shots = a.closeups ?? []
        guard !shots.contains(where: { $0.frame <= currentFrame && currentFrame <= $0.endFrame }) else {
            timelineMessage = "当前帧已有特写，请调整已有特写。"; return
        }
        var shot = Closeup(); shot.frame = currentFrame; shot.endFrame = currentFrame
        if let job, let track = a.track {
            let point = job.plan.xforms[currentFrame].map(track.frames[currentFrame].headCenter)
            shot.centerX = point.x / Double(job.outputSize.w); shot.centerY = point.y / Double(job.outputSize.h)
        }
        shots.append(shot); shots.sort { $0.frame < $1.frame }
        a.closeups = shots; analysis = a; timelineMessage = nil
        scheduleSave(); rebuildJob(immediate: true)
    }

    func updateCloseup(_ value: Closeup) {
        guard var a = analysis, let i = a.closeups?.firstIndex(where: { $0.id == value.id }) else { return }
        var shot = value
        shot.frame = clamp(shot.frame, 0, a.count - 1); shot.endFrame = clamp(shot.endFrame, shot.frame, a.count - 1)
        shot.seconds = clamp(shot.seconds, 1 / exportSettings.outputFPS, 3600); shot.zoom = clamp(shot.zoom, 1, 8)
        shot.centerX = clamp(shot.centerX, 0, 1); shot.centerY = clamp(shot.centerY, 0, 1)
        if a.closeups!.enumerated().contains(where: { $0.offset != i && $0.element.frame <= shot.endFrame && shot.frame <= $0.element.endFrame }) {
            timelineMessage = "特写替换时段不能重叠。"; return
        }
        a.closeups![i] = shot; analysis = a; timelineMessage = nil
        scheduleSave(); rebuildJob(immediate: false)
    }

    func removeCloseup(_ id: UUID) {
        analysis?.closeups?.removeAll { $0.id == id }
        scheduleSave(); rebuildJob(immediate: true)
    }
}

extension AppState {
    func moveGroup(_ group: Int, by delta: Int) {
        guard phase == .ready, let index = mergeGroupIndices.firstIndex(of: group),
              mergeGroupIndices.indices.contains(index + delta) else { return }
        var order = mergeGroupIndices; order.swapAt(index,index + delta)
        guard segmentIndex == -1, let old = analysis else { mergeGroupIndices = order; rememberGroupOrder(); return }
        do {
            let permutation = order.compactMap { mergeGroupIndices.firstIndex(of: $0) }
            let result = try ClipOrder.reorder(old, order: permutation)
            stop()
            // Copy to a different fingerprint; never rename/delete the old cache or original photos.
            for (new, previous) in result.oldIndices.enumerated() {
                let from = ProxyCache.shared.proxyURL(fingerprint: old.fingerprint,index: previous)
                let to = ProxyCache.shared.proxyURL(fingerprint: result.analysis.fingerprint,index: new)
                if !FileManager.default.fileExists(atPath: to.path), FileManager.default.fileExists(atPath: from.path) {
                    try FileManager.default.copyItem(at: from,to: to)
                }
            }
            ProxyCache.shared.saveAnalysis(old)
            let oldPhoto = old.frames[currentFrame].url
            mergeGroupIndices = order; rememberGroupOrder(); analysis = result.analysis
            currentFrame = result.analysis.frames.firstIndex { $0.url == oldPhoto } ?? 0
            let trimmed = selection.trimStart > 0 || selection.trimEnd != nil
            selection.trimStart = 0; selection.trimEnd = nil
            timelineMessage = trimmed ? "顺序已调整，裁剪范围恢复为全部；照片修正、排除和特写已跟随原照片。" : nil
            ProxyCache.shared.saveAnalysis(result.analysis)
            rebuildJob(immediate: true)
        } catch { timelineMessage = error.localizedDescription }
    }
}
