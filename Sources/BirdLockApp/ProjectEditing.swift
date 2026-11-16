import AppKit
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
    func groupName(_ index: Int) -> String {
        let name = segments.indices.contains(index) ? segments[index].name : ""
        return name.isEmpty ? "第 \(index + 1) 组" : name
    }

    func renameGroup(_ index: Int) {
        guard phase == .ready, segments.indices.contains(index) else { return }
        let group = segments[index].groupID
        let entry = NSTextField(string: segments[index].name)
        entry.frame.size.width = 260
        let prompt = NSAlert()
        prompt.messageText = "重命名连拍组"
        prompt.informativeText = "留空时显示默认组名。"
        prompt.accessoryView = entry
        prompt.window.initialFirstResponder = entry
        prompt.addButton(withTitle: "确定")
        prompt.addButton(withTitle: "取消")
        guard prompt.runModal() == .alertFirstButtonReturn, phase == .ready,
              let index = segments.firstIndex(where: { $0.groupID == group }) else { return }
        let name = String(entry.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(256))
        guard segments[index].name != name else { return }
        segments[index].name = name
        projectDirty = true; projectCloseApproved = false
        recordEdit()
    }

    func revealOriginals(group: Int? = nil) {
        let list: [SourceFrame]
        if let group, segments.indices.contains(group) {
            list = Array(frames[segments[group].range])
        } else if let analysis, analysis.frames.indices.contains(currentFrame) {
            list = [analysis.frames[currentFrame]]
        } else { return }
        var seen = Set<URL>()
        let urls = list.compactMap { frame -> URL? in
            let isExtracted = FileManager.default.fileExists(atPath: frame.url.deletingLastPathComponent()
                .appendingPathComponent("video-source.json").path)
            guard let original = isExtracted ? VideoSource.originalURL(frames: [frame]) : frame.url else { return nil }
            guard seen.insert(original).inserted,
                  (try? original.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return original
        }
        guard !urls.isEmpty else { timelineMessage = "未找到可用的原片。"; return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

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
            let oldPhoto = old.frames.indices.contains(currentFrame) ? old.frames[currentFrame].url : nil
            mergeGroupIndices = order; analysis = result.analysis
            currentFrame = result.analysis.frames.firstIndex { $0.url == oldPhoto } ?? 0
            let trimmed = selection.trimStart > 0 || selection.trimEnd != nil
            resetTrimForGroupReorder()
            rememberGroupOrder()
            timelineMessage = trimmed ? "顺序已调整，裁剪范围恢复为全部；照片修正、排除和特写已跟随原照片。" : nil
            ProxyCache.shared.saveAnalysis(result.analysis)
            rebuildJob(immediate: true)
        } catch { timelineMessage = error.localizedDescription }
    }
}
