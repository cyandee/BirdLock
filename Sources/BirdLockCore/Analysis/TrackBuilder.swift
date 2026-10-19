import Foundation

public struct TrackOptions: Sendable {
    public var linkMinQuality = 12.0
    public var eyeSigmaHL = 0.05        // eye keypoint noise, in head lengths
    public var predictedEyeSigmaHL = 0.12
    public var centerSigmaHL = 0.06
    public var linkSigmaPatchPx = 0.05  // registration noise floor in patch px
    public var useRegistration = true
    public init() {}
}

/// Converts raw per-frame analysis + user edits into a solved, smooth-but-faithful track.
public enum TrackBuilder {
    public static func build(_ a: SequenceAnalysis, options o: TrackOptions = TrackOptions()) -> Track {
        if let clips = a.clips, clips.count > 1 {
            let tracks = clips.map { clip -> Track in
                let range = clip.start..<(clip.start + clip.count)
                var sub = a
                sub.frames = Array(a.frames[range]); sub.perFrame = Array(a.perFrame[range]); sub.clips = nil; sub.track = nil
                sub.manualEye = Dictionary(uniqueKeysWithValues: a.manualEye.filter { range.contains($0.key) }.map { ($0.key - clip.start, $0.value) })
                sub.excluded = Set(a.excluded.filter(range.contains).map { $0 - clip.start })
                return build(sub, options: o)
            }
            let frames = tracks.flatMap(\.frames)
            return Track(frames: frames, template: tracks.first?.template, reflectDominant: tracks.first?.reflectDominant ?? false,
                         facingRight: tracks.first?.facingRight ?? true, medianHeadLength: Stats.median(frames.map(\.headLength)) ?? 100)
        }
        let n = a.count
        if a.analysisSubject == .aircraft { return AircraftTrackBuilder.build(a) }
        // Decide which labelled eye (left/right) is the visible one, smoothed over time so the anchor never
        // hops between the two eyes from frame to frame (the far eye is often also predicted).
        let schema = a.poseSchema
        let li = schema.index(of: .leftEye), ri = schema.index(of: .rightEye)
        var obs = a.perFrame.map { $0.head }
        if let li, let ri {
            let diff = a.perFrame.map { f -> Double in
                guard f.keypoints.count > max(li, ri) else { return .nan }
                return f.keypoints[li].conf - f.keypoints[ri].conf
            }
            let sm = Signal.gaussian(Signal.median(diff, radius: 7), sigma: 6)
            let globalSide = (diff.filter { $0.isFinite }.reduce(0, +)) >= 0
            for i in 0..<n where !a.perFrame[i].keypoints.isEmpty {
                let leftSide = sm[i].isFinite ? sm[i] >= 0 : globalSide
                obs[i] = HeadObservation.from(keypoints: a.perFrame[i].keypoints, schema: schema, minConf: 0.35,
                                              eyeSide: leftSide ? .leftEye : .rightEye)
            }
        }
        let template = HeadTemplate.estimate(obs)

        // Dominant handedness from well-constrained fits
        var refl = 0, prop = 0
        if let t = template {
            for ob in obs where ob.validCount >= 3 {
                if let (s, _) = t.fit(ob) { if s.reflect { refl += 1 } else { prop += 1 } }
            }
        }
        let reflectDominant = refl > prop
        var sims = [Similarity?](repeating: nil, count: n)
        var fitErr = [Double](repeating: .infinity, count: n)
        if let t = template {
            for i in 0..<n {
                if let (s, e) = t.fit(obs[i], preferReflect: reflectDominant), e < 0.6 { sims[i] = s; fitErr[i] = e }
            }
        }
        let tHL = template?.headLength ?? 2

        // --- head length (robust)
        var hlRaw = (0..<n).map { i -> Double in sims[i].map { $0.s * tHL } ?? .nan }
        // Fallback from the bird box using the sequence's typical ratio
        let ratios = (0..<n).compactMap { i -> Double? in
            guard hlRaw[i].isFinite, let b = a.perFrame[i].targetBox else { return nil }
            return hlRaw[i] / b.diag
        }
        let ratio = Stats.median(ratios) ?? 0.12
        for i in 0..<n where !hlRaw[i].isFinite {
            if let b = a.perFrame[i].targetBox { hlRaw[i] = b.diag * ratio }
        }
        var logHL = hlRaw.map { $0.isFinite && $0 > 0 ? log($0) : .nan }
        logHL = Signal.median(logHL, radius: 4)
        logHL = Signal.gaussian(logHL, sigma: 3)
        logHL = Signal.fillGaps(logHL)
        let hl = logHL.map { $0.isFinite ? exp($0) : 100 }
        let medianHL = Stats.median(hl) ?? 100

        // --- head angle
        var ang = (0..<n).map { i -> Double in sims[i]?.theta ?? .nan }
        ang = Signal.unwrapAngles(ang)
        ang = Signal.median(ang, radius: 3)
        ang = Signal.gaussian(ang, sigma: 2)
        ang = Signal.fillGaps(ang)
        let facingRight = (Stats.median(ang.map { cos($0) }) ?? 1) >= 0

        // --- absolute measurements
        var eyeM = [TrajectorySolver.Measurement](repeating: .init(value: nil, sigma: 1), count: n)
        var ctrM = eyeM
        var measuredEye = [V2?](repeating: nil, count: n)
        var eyeVisible = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let h = hl[i]
            let predEye = (sims[i] != nil && template?[.eye] != nil) ? sims[i]!.apply(template![.eye]!) : nil
            let predCtr = sims[i].map { $0.apply(template!.headCenter) }
            if let e = obs[i][.eye] {
                measuredEye[i] = e
                if let p = predEye, (p - e).length > 0.35 * h {
                    // eye keypoint disagrees with the rest of the head -> distrust it
                } else { eyeVisible[i] = true }
            }
            if let man = a.manualEye[i] {
                eyeM[i] = .init(value: man, sigma: 0.5)
                let off = (predCtr != nil && predEye != nil) ? predCtr! - predEye! : V2(0, 0)
                ctrM[i] = .init(value: man + off, sigma: predCtr != nil ? 1.0 : 0.3 * h)
                continue
            }
            if eyeVisible[i], let e = measuredEye[i] {
                eyeM[i] = .init(value: e, sigma: o.eyeSigmaHL * h + 0.7)
            } else if let p = predEye {
                eyeM[i] = .init(value: p, sigma: o.predictedEyeSigmaHL * h + 1.5)
            } else if let b = a.perFrame[i].targetBox {
                eyeM[i] = .init(value: b.center, sigma: 1.5 * h)
            }
            if let c = predCtr {
                ctrM[i] = .init(value: c, sigma: o.centerSigmaHL * h + 0.7)
            } else if let b = a.perFrame[i].targetBox {
                ctrM[i] = .init(value: b.center, sigma: 1.5 * h)
            }
        }

        // --- registration links
        var links = [TrajectorySolver.Link](repeating: .init(delta: nil, sigma: 1), count: n)
        if o.useRegistration {
            for i in 1..<max(1, n) where i < n {
                guard let l = a.perFrame[i].link, l.quality >= o.linkMinQuality else { continue }
                let s = l.patchScale * (o.linkSigmaPatchPx + 12.0 / l.quality)
                links[i] = .init(delta: l.delta, sigma: s)
            }
        }
        // Excluded frames keep their links (they still constrain motion) but not used for output.
        let eyeSol = TrajectorySolver.solve(measurements: eyeM, links: links)
        let ctrSol = TrajectorySolver.solve(measurements: ctrM, links: links)

        // --- data coverage
        var hasData = [Bool](repeating: false, count: n)
        var lastSeen = -1000
        for i in 0..<n { if eyeM[i].value != nil && eyeM[i].sigma < h(hl, i) { lastSeen = i }; hasData[i] = i - lastSeen <= 8 }
        lastSeen = 100000
        for i in stride(from: n - 1, through: 0, by: -1) {
            if eyeM[i].value != nil && eyeM[i].sigma < h(hl, i) { lastSeen = i }
            hasData[i] = hasData[i] || lastSeen - i <= 8
        }

        var frames: [TrackFrame] = []
        for i in 0..<n {
            var conf = 0.0
            if a.manualEye[i] != nil { conf = 1 }
            else if eyeVisible[i] { conf = 0.9 } else if sims[i] != nil { conf = 0.6 } else if a.perFrame[i].targetBox != nil { conf = 0.25 }
            if !eyeSol.measurementInlier[i] { conf *= 0.5 }
            frames.append(TrackFrame(eye: eyeSol.positions[i], headCenter: ctrSol.positions[i], headLength: hl[i], angle: ang[i],
                                     measuredEye: measuredEye[i], eyeVisible: eyeVisible[i], hasData: hasData[i], confidence: conf))
        }
        return Track(frames: frames, template: template, reflectDominant: reflectDominant, facingRight: facingRight, medianHeadLength: medianHL)
    }

    @inline(__always) private static func h(_ hl: [Double], _ i: Int) -> Double { hl[i] }
}
