import Foundation

public struct BurstClip: Codable, Hashable, Sendable {
    public var start: Int
    public var count: Int
    public var fps: Double
    public init(start: Int, count: Int, fps: Double) { self.start = start; self.count = count; self.fps = fps }
}

public struct Closeup: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var frame = 0
    public var endFrame = 0
    public var seconds = 2.0
    public var zoom = 1.5
    public var centerX = 0.5
    public var centerY = 0.5
    public var animatedFrame = true
    public var color: FocusMarkColor = .white
    public var shutterEnabled = true
    public var shutterVolume = 0.7
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = Closeup()
        id = c.value(.id, d.id); frame = c.value(.frame, d.frame); endFrame = c.value(.endFrame, frame)
        seconds = c.value(.seconds, d.seconds); zoom = c.value(.zoom, d.zoom)
        centerX = c.value(.centerX, d.centerX); centerY = c.value(.centerY, d.centerY)
        animatedFrame = c.value(.animatedFrame, d.animatedFrame); color = c.value(.color, d.color)
        shutterEnabled = c.value(.shutterEnabled, false); shutterVolume = c.value(.shutterVolume, d.shutterVolume)
    }
}

public enum ProjectTimeline {
    /// First occurrence in the finished timeline, including a photo replaced by a closeup.
    /// Omitted photos have no timestamp; treating them as time zero misaligns the music.
    public static func sourceTime(_ frame: Int, outputFrames: [OutputFrame], closeups: [Closeup]) -> Double? {
        if let index = closeups.firstIndex(where: { $0.frame <= frame && frame <= max($0.frame, $0.endFrame) }),
           let match = outputFrames.first(where: { $0.closeup == index }) { return match.time }
        return outputFrames.first(where: { $0.a == frame })?.time
    }

    public static func plan(_ analysis: SequenceAnalysis, track: Track, composition: Composition,
                            width: Double, height: Double, used: [Int]) -> CompositionPlan {
        guard let clips = analysis.clips, clips.count > 1 else {
            return CompositionPlanner.plan(track: track, frames: analysis.frames, composition: composition, outW: width, outH: height, used: used)
        }
        let parts = clips.map { clip -> CompositionPlan in
            let range = clip.start..<(clip.start + clip.count)
            var sub = track
            sub.frames = Array(track.frames[range])
            sub.medianHeadLength = Stats.median(sub.frames.map(\.headLength)) ?? track.medianHeadLength
            sub.facingRight = (Stats.median(sub.frames.map { cos($0.angle) }) ?? 1) >= 0
            return CompositionPlanner.plan(track: sub, frames: Array(analysis.frames[range]), composition: composition,
                outW: width, outH: height, used: used.filter(range.contains).map { $0 - clip.start })
        }
        return CompositionPlan(xforms: parts.flatMap(\.xforms), outW: width, outH: height, maxUpscale: parts.map(\.maxUpscale).max() ?? 1,
            outOfBoundsFrames: parts.reduce(0) { $0 + $1.outOfBoundsFrames }, shiftedFrames: parts.reduce(0) { $0 + $1.shiftedFrames },
            zoomedFrames: parts.reduce(0) { $0 + $1.zoomedFrames }, imageLimitedFrames: parts.reduce(0) { $0 + $1.imageLimitedFrames }, mirrored: parts.first?.mirrored ?? false)
    }
    /// Map each burst separately so optical flow never blends across a shutter gap.
    public static func frames(used: [Int], clips: [BurstClip], closeups: [Closeup], fallbackFPS: Double,
                              settings: ExportSettings) -> [OutputFrame] {
        var base: [OutputFrame] = []
        var local = settings
        local.loop = .forward; local.repeatCount = 1; local.fadeInSeconds = 0; local.fadeOutSeconds = 0
        for clip in clips {
            let indices = used.filter { $0 >= clip.start && $0 < clip.start + clip.count }
            base += TimeMapper.outputFrames(used: indices, sourceFPS: clip.fps > 0 ? clip.fps : fallbackFPS, settings: local)
        }
        if clips.isEmpty { base = TimeMapper.outputFrames(used: used, sourceFPS: fallbackFPS, settings: local) }
        var arranged: [OutputFrame] = []
        let available = Set(used)
        var active: Int? = nil
        for frame in base {
            let match = closeups.firstIndex { available.contains($0.frame) && $0.frame <= frame.a && frame.a <= max($0.frame, $0.endFrame) }
            if let index = match {
                if active != index {
                    let shot = closeups[index]
                    let count = max(1, Int((min(3600, max(1 / settings.outputFPS, shot.seconds)) * settings.outputFPS).rounded()))
                    for k in 0..<count {
                        var of = OutputFrame(a: shot.frame, b: shot.frame, t: 0, fade: 1)
                        of.closeup = index; of.shotTime = Double(k) / settings.outputFPS
                        arranged.append(of)
                    }
                }
            } else { arranged.append(frame) }
            active = match
        }
        switch settings.loop {
        case .forward: break
        case .reverse: arranged.reverse()
        case .pingPong: arranged += arranged.reversed().dropFirst()
        }
        let cycle = arranged
        if settings.repeatCount > 1 { for repetition in 1..<settings.repeatCount {
            var part = settings.loop == .pingPong ? Array(cycle.dropFirst()) : cycle
            for i in part.indices { part[i].audioCycle = repetition }; arranged += part
        } }
        let duration = Double(arranged.count) / settings.outputFPS
        for i in arranged.indices {
            let time = Double(i) / settings.outputFPS
            arranged[i].time = time
            var fade = 1.0
            if settings.fadeInSeconds > 0 { fade = min(fade, time / settings.fadeInSeconds) }
            if settings.fadeOutSeconds > 0 { fade = min(fade, (duration - time) / settings.fadeOutSeconds) }
            arranged[i].fade = clamp(fade, 0, 1)
        }
        return arranged
    }
}
