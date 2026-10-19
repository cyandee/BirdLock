import Foundation

/// Picks one bird per frame and keeps its identity through the sequence.
public enum TargetTracker {
    /// - Parameters:
    ///   - birds: detections per frame
    ///   - hint: optional (frame, point) – the user clicked this bird
    /// - Returns: index of the chosen detection per frame (nil = not found)
    public static func track(_ birds: [[BoxD]], hint: (frame: Int, point: V2)? = nil, clips: [BurstClip] = []) -> [Int?] {
        if clips.count > 1 {
            return clips.flatMap { clip in
                let range = clip.start..<(clip.start + clip.count)
                let localHint = hint.flatMap { range.contains($0.frame) ? (frame: $0.frame - clip.start, point: $0.point) : nil }
                return track(Array(birds[range]), hint: localHint)
            }
        }
        let n = birds.count
        var out = [Int?](repeating: nil, count: n)
        guard n > 0 else { return out }

        // Seed
        var seedF = -1, seedI = -1
        if let hint, hint.frame >= 0, hint.frame < n, !birds[hint.frame].isEmpty {
            seedF = hint.frame
            seedI = birds[hint.frame].indices.min { a, b in
                (birds[hint.frame][a].center - hint.point).length < (birds[hint.frame][b].center - hint.point).length
            }!
        } else {
            // Most confident & large bird, preferring frames where it is the dominant one
            var best = -1.0
            for f in 0..<n {
                for (i, b) in birds[f].enumerated() {
                    let s = b.score * b.diag.squareRoot()
                    if s > best { best = s; seedF = f; seedI = i }
                }
            }
        }
        guard seedF >= 0 else { return out }
        out[seedF] = seedI
        propagate(birds, from: seedF, step: 1, into: &out)
        propagate(birds, from: seedF, step: -1, into: &out)
        return out
    }

    private static func propagate(_ birds: [[BoxD]], from seed: Int, step: Int, into out: inout [Int?]) {
        let n = birds.count
        guard let si = out[seed] else { return }
        var last = birds[seed][si]
        var vel = V2(0, 0)
        var missed = 0
        var f = seed + step
        while f >= 0 && f < n {
            let pred = last.center + vel * Double(missed + 1)
            let gate = last.diag * (0.8 + 0.25 * Double(missed))
            var bestI: Int? = nil, bestC = Double.infinity
            for (i, b) in birds[f].enumerated() {
                let d = (b.center - pred).length
                guard d < gate else { continue }
                let areaRatio = log(max(1e-6, (b.w * b.h) / max(1e-6, last.w * last.h)))
                let c = d / last.diag + 0.35 * abs(areaRatio) - 0.2 * b.score
                if c < bestC { bestC = c; bestI = i }
            }
            if let bi = bestI {
                let b = birds[f][bi]
                let v = (b.center - last.center) / Double(missed + 1)
                vel = missed == 0 ? vel * 0.5 + v * 0.5 : v
                last = b
                missed = 0
                out[f] = bi
            } else {
                missed += 1
                if missed > 20 { vel = V2(0, 0) }
            }
            f += step
        }
    }
}
