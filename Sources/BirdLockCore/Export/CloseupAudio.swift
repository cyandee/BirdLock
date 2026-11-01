import Foundation

public enum CloseupAudio {
    public static func muteBursts(_ audio: AudioSettings, frames: [OutputFrame], fps: Double) -> AudioSettings {
        var ranges: [[Double]] = []
        for frame in frames where frame.closeup >= 0 {
            let end = frame.time + 1 / fps
            if let last = ranges.last, abs(last[1] - frame.time) < 1e-7 {
                ranges[ranges.count - 1][1] = end
            } else { ranges.append([frame.time, end]) }
        }
        var result = audio
        for i in result.tracks.indices {
            if result.tracks[i].assetID.flatMap(SoundLibrary.asset)?.kind == "burst" {
                result.tracks[i].muteRanges += ranges
            }
        }
        return result
    }

    public static func audibleRanges(_ track: AudioTrack, start: Double, end: Double) -> [[Double]] {
        var spans = [[start, end]]
        for r in track.muteRanges where r.count == 2 && r[0].isFinite && r[1].isFinite && r[0] < r[1] {
            spans = spans.flatMap { s -> [[Double]] in
                if r[1] <= s[0] || r[0] >= s[1] { return [s] }
                return [[s[0], min(s[1], r[0])], [max(s[0], r[1]), s[1]]].filter { $0[0] < $0[1] }
            }
        }
        return spans
    }
    public static func tracks(frames: [OutputFrame], closeups: [Closeup], fps: Double = 30) -> [AudioTrack] {
        var result: [AudioTrack] = []
        var previous: OutputFrame?
        for (i, frame) in frames.enumerated() {
            defer { previous = frame }
            guard closeups.indices.contains(frame.closeup), closeups[frame.closeup].shutterEnabled,
                  previous?.closeup != frame.closeup || previous?.audioCycle != frame.audioCycle else { continue }
            let shot = closeups[frame.closeup]
            var track = AudioTrack(); track.id = shot.id
            track.assetID = "single-canon-rebel"; track.timelineStart = frame.time
            var end = i + 1
            while end < frames.count, frames[end].closeup == frame.closeup, frames[end].audioCycle == frame.audioCycle { end += 1 }
            track.duration = min(SoundLibrary.asset(for: "single-canon-rebel")?.duration ?? 0.232, Double(end - i) / fps)
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
            for span in audibleRanges(t, start: start, end: end) {
                events[span[0], default: 0] += clamp(t.volume, 0, 2)
                events[span[1], default: 0] -= clamp(t.volume, 0, 2)
            }
        }
        var level = 0.0, peak = 1.0
        for time in events.keys.sorted() { level += events[time]!; peak = max(peak, level) }
        return 1 / peak
    }
}
