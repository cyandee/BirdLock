import Foundation

public enum CloseupAudio {
    public static func tracks(frames: [OutputFrame], closeups: [Closeup]) -> [AudioTrack] {
        var result: [AudioTrack] = []
        var previous: OutputFrame?
        for frame in frames {
            defer { previous = frame }
            guard closeups.indices.contains(frame.closeup), closeups[frame.closeup].shutterEnabled,
                  previous?.closeup != frame.closeup || previous?.audioCycle != frame.audioCycle else { continue }
            let shot = closeups[frame.closeup]
            var track = AudioTrack(); track.id = shot.id
            track.assetID = "single-canon-rebel"; track.timelineStart = frame.time
            track.duration = SoundLibrary.asset(for: "single-canon-rebel")?.duration ?? 0.232
            track.volume = clamp(shot.shutterVolume, 0, 1.5); track.loop = false
            result.append(track)
        }
        return result
    }
    /// Disjoint one-shots must not reduce music volume as if they all played together.
    public static func gain(tracks: [AudioTrack], duration: Double) -> Double {
        var events: [Double: Double] = [:]
        for t in tracks where t.isActive {
            let start = max(0, t.timelineStart), end = min(duration, t.duration > 0 ? start + t.duration : duration)
            guard start < end else { continue }
            events[start, default: 0] += clamp(t.volume, 0, 2)
            events[end, default: 0] -= clamp(t.volume, 0, 2)
        }
        var level = 0.0, peak = 1.0
        for time in events.keys.sorted() { level += events[time]!; peak = max(peak, level) }
        return 1 / peak
    }
}
