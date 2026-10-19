import Foundation

public enum ClipOrderError: Error, LocalizedError {
    case invalid, crossCut
    public var errorDescription: String? {
        switch self {
        case .invalid: return "片段顺序与当前分析不匹配，请等待分析完成后再试。"
        case .crossCut: return "特写跨越连拍组，请将特写范围调整到一组内再排序。"
        }
    }
}

public enum ClipOrder {
    /// Permute whole independent bursts and carry every photo edit with its source photo.
    public static func reorder(_ analysis: SequenceAnalysis, order: [Int]) throws -> (analysis: SequenceAnalysis, oldIndices: [Int]) {
        let clips = analysis.clips ?? []
        guard analysis.groupedDetection == true, order.count == clips.count,
              Set(order) == Set(clips.indices), analysis.perFrame.count == analysis.count else { throw ClipOrderError.invalid }
        var cursor = 0
        for c in clips {
            guard c.start == cursor, c.count > 0 else { throw ClipOrderError.invalid }; cursor += c.count
        }
        guard cursor == analysis.count else { throw ClipOrderError.invalid }
        for shot in analysis.closeups ?? [] {
            guard clips.contains(where: { $0.start <= shot.frame && shot.endFrame < $0.start + $0.count && shot.frame <= shot.endFrame }) else { throw ClipOrderError.crossCut }
        }
        let indices = order.flatMap { Array(clips[$0].start..<(clips[$0].start + clips[$0].count)) }
        let remap = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($0.element, $0.offset) })
        var a = analysis
        a.frames = indices.enumerated().map { i, old in var f = analysis.frames[old]; f.id = i; return f }
        a.perFrame = indices.enumerated().map { i, old in var p = analysis.perFrame[old]; p.index = i; return p }
        a.manualEye = Dictionary(uniqueKeysWithValues: analysis.manualEye.compactMap { i, value in remap[i].map { ($0,value) } })
        a.excluded = Set(analysis.excluded.compactMap { remap[$0] })
        a.closeups = (analysis.closeups ?? []).map { shot in
            var s = shot; s.frame = remap[shot.frame]!; s.endFrame = remap[shot.endFrame]!; return s
        }
        cursor = 0
        a.clips = order.map { i in defer { cursor += clips[i].count }; return BurstClip(start: cursor,count: clips[i].count,fps: clips[i].fps) }
        for clip in a.clips! { a.perFrame[clip.start].link = nil }
        a.fingerprint = Analyzer.fingerprint(a.frames, aircraftModelIdentity: a.analysisSubject == .aircraft ? a.modelIdentity : nil)
        a.track = TrackBuilder.build(a)
        return (a,indices)
    }
}
