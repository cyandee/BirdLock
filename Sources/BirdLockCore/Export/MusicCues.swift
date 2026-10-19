import Foundation

public struct MusicCue: Sendable, Hashable, Identifiable {
    public var time: Double
    public var climax: Bool
    public var id: String { "\(climax)-\(time)" }
}

/// Local energy/onset candidates, intended for user-reviewed alignment rather than a musical judgement.
public enum MusicCues {
    public static func analyze(peaks: [Float], binsPerSecond rate: Double = 40) -> [MusicCue] {
        guard peaks.count > 8, rate > 0 else { return [] }
        let p = peaks.map { $0.isFinite ? Double(max(0, $0)) : 0 }
        let mean = p.reduce(0,+) / Double(p.count)
        guard p.max()! - p.min()! > 0.025 else { return [] }
        let onset = p.indices.map { i -> Double in
            let start = max(0,i-4)
            let previous = i > start ? p[start..<i].reduce(0,+) / Double(i-start) : 0
            return max(0,p[i]-previous)
        }
        var beats: [Int] = []
        for i in onset.indices.sorted(by: { onset[$0] > onset[$1] }) where onset[i] > max(0.035,mean * 0.15) {
            if beats.allSatisfy({ abs($0-i) >= Int(rate * 0.25) }) { beats.append(i) }
            if beats.count >= 160 { break }
        }
        let radius = max(1,Int(rate))
        var prefix = [0.0]
        for value in p { prefix.append(prefix.last! + value * value) }
        let energy = p.indices.map { i -> Double in
            let lo = max(0,i-radius), hi = min(p.count,i+radius+1)
            return (prefix[hi]-prefix[lo])/Double(hi-lo)
        }
        var highlights: [Int] = []
        let averageEnergy = prefix.last! / Double(p.count)
        for i in energy.indices.sorted(by: { energy[$0] > energy[$1] }) where energy[i] > averageEnergy * 1.15 {
            if highlights.allSatisfy({ abs($0-i) >= Int(rate * 5) }) { highlights.append(i) }
            if highlights.count == 3 { break }
        }
        return (beats.map { MusicCue(time: Double($0)/rate, climax: false) } + highlights.map { MusicCue(time: Double($0)/rate, climax: true) })
            .sorted { $0.time < $1.time }
    }

    public static func visualCandidates(_ a: SequenceAnalysis, included: Set<Int>? = nil) -> [Int] {
        guard let track = a.track, a.count > 0 else { return [] }
        let sharp = Stats.median(a.perFrame.compactMap(\.sharpness)) ?? 1
        let scores = a.perFrame.enumerated().map { i,f -> Double in
            guard included?.contains(i) != false, !a.excluded.contains(i), let box = f.targetBox, track.frames[i].hasData else { return 0 }
            let spread = sqrt(max(1,box.w*box.h)) / max(1,track.frames[i].headLength)
            return clamp((f.sharpness ?? sharp)/max(1,sharp),0.1,2) * clamp(spread,1,12) * track.frames[i].confidence
        }
        var chosen: [Int] = []
        for i in scores.indices.sorted(by: { scores[$0] > scores[$1] }) where scores[i] > 0 {
            if chosen.allSatisfy({ abs($0-i) >= max(1,a.count/8) }) { chosen.append(i) }
            if chosen.count == 3 { break }
        }
        return chosen.sorted()
    }
}
