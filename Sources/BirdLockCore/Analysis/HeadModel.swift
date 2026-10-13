import Foundation

/// Points used to describe the head. "eye" merges left/right eye (the visible one).
public enum HeadPoint: Int, CaseIterable, Codable, Sendable {
    case beak = 0, crown, forehead, eye, nape, throat
    public static let count = 6
}

/// Per-frame head observation extracted from pose keypoints.
public struct HeadObservation: Codable, Sendable {
    public var points: [V2?]      // indexed by HeadPoint
    public var conf: [Double]
    public init() { points = Array(repeating: nil, count: HeadPoint.count); conf = Array(repeating: 0, count: HeadPoint.count) }

    public subscript(_ p: HeadPoint) -> V2? { points[p.rawValue] }

    public var validCount: Int { points.compactMap { $0 }.count }

    /// - Parameter eyeSide: which labelled eye to use (.leftEye / .rightEye). nil = the more confident one.
    public static func from(keypoints: [Keypoint], schema: PoseSchema, minConf: Double, eyeSide: BirdPart? = nil) -> HeadObservation {
        var o = HeadObservation()
        func kp(_ part: BirdPart) -> Keypoint? {
            guard let i = schema.index(of: part), i < keypoints.count else { return nil }
            return keypoints[i]
        }
        func set(_ hp: HeadPoint, _ k: Keypoint?) {
            guard let k, k.conf >= minConf else { return }
            o.points[hp.rawValue] = k.p; o.conf[hp.rawValue] = k.conf
        }
        set(.beak, kp(.beak))
        set(.crown, kp(.crown) ?? kp(.headTop))
        set(.forehead, kp(.forehead))
        set(.nape, kp(.nape))
        set(.throat, kp(.throat))
        // Eye: use the requested side (keeps one physical eye through the sequence), else the more confident one
        let l = kp(.leftEye), r = kp(.rightEye)
        if let eyeSide {
            set(.eye, eyeSide == .leftEye ? l : r)
        } else {
            set(.eye, [l, r].compactMap { $0 }.max { $0.conf < $1.conf })
        }
        return o
    }
}

/// 2-D similarity transform (optionally with reflection): p = t + s * R(theta) * F * q, F = diag(1, ±1)
public struct Similarity: Codable, Sendable {
    public var t: V2
    public var s: Double
    public var theta: Double
    public var reflect: Bool

    public static let identity = Similarity(t: V2(0, 0), s: 1, theta: 0, reflect: false)

    public func apply(_ q: V2) -> V2 {
        let f = reflect ? V2(q.x, -q.y) : q
        return t + s * f.rotated(theta)
    }
    public func inverse(_ p: V2) -> V2 {
        let f = ((p - t) / s).rotated(-theta)
        return reflect ? V2(f.x, -f.y) : f
    }

    /// Weighted least-squares similarity mapping src -> dst (no reflection; reflect src beforehand).
    public static func fit(src: [V2], dst: [V2], w: [Double], reflect: Bool) -> (Similarity, Double)? {
        let n = src.count
        guard n >= 2 else { return nil }
        let srcF = reflect ? src.map { V2($0.x, -$0.y) } : src
        let W = w.reduce(0, +)
        guard W > 0 else { return nil }
        var ms = V2(0, 0), md = V2(0, 0)
        for i in 0..<n { ms += w[i] * srcF[i]; md += w[i] * dst[i] }
        ms /= W; md /= W
        var a = 0.0, b = 0.0, ss = 0.0
        for i in 0..<n {
            let q = srcF[i] - ms, p = dst[i] - md
            a += w[i] * (q.x * p.x + q.y * p.y)
            b += w[i] * (q.x * p.y - q.y * p.x)
            ss += w[i] * (q.x * q.x + q.y * q.y)
        }
        guard ss > 1e-12 else { return nil }
        let theta = atan2(b, a)
        let s = (a * a + b * b).squareRoot() / ss
        guard s > 1e-9 else { return nil }
        let t = md - s * ms.rotated(theta)
        let sim = Similarity(t: t, s: s, theta: theta, reflect: reflect)
        var err = 0.0
        for i in 0..<n { err += w[i] * (sim.apply(src[i]) - dst[i]).length.squared() }
        return (sim, (err / W).squareRoot() / s)   // RMS residual in template units
    }
}

extension Double { @inline(__always) func squared() -> Double { self * self } }

/// Generalised Procrustes head template estimated from the whole sequence.
public struct HeadTemplate: Codable, Sendable {
    /// Template coordinates per HeadPoint (nil if never observed). Normalised: centroid 0, RMS radius 1,
    /// beak pointing to +x.
    public var points: [V2?]

    public subscript(_ p: HeadPoint) -> V2? { points[p.rawValue] }

    /// Point used for "head centre" lock: centroid of the non-beak points.
    public var headCenter: V2 {
        let ps = [HeadPoint.crown, .forehead, .eye, .nape, .throat].compactMap { self[$0] }
        guard !ps.isEmpty else { return V2(0, 0) }
        return ps.reduce(V2(0, 0), +) / Double(ps.count)
    }

    /// Head length (beak tip to nape) in template units, with fallback.
    public var headLength: Double {
        if let b = self[.beak], let n = self[.nape] { return (b - n).length }
        if let b = self[.beak], let e = self[.eye] { return (b - e).length * 1.8 }
        return 2.0
    }

    public static func estimate(_ obs: [HeadObservation], iterations: Int = 4) -> HeadTemplate? {
        // Initial template: frame with the most points (prefer ones containing beak + eye)
        let scored = obs.enumerated().map { (i, o) -> (Int, Double) in
            (i, Double(o.validCount) + (o[.beak] != nil ? 0.5 : 0) + (o[.eye] != nil ? 0.5 : 0) + o.conf.reduce(0, +) * 0.01)
        }
        guard let seed = scored.max(by: { $0.1 < $1.1 }), obs[seed.0].validCount >= 3 else { return nil }
        var tmpl = HeadTemplate(points: obs[seed.0].points)
        tmpl.normalise()
        for _ in 0..<iterations {
            var acc = Array(repeating: [V2](), count: HeadPoint.count)
            var accW = Array(repeating: [Double](), count: HeadPoint.count)
            for o in obs {
                guard let (sim, err) = tmpl.fit(o), err < 0.5 else { continue }
                for k in 0..<HeadPoint.count {
                    if let p = o.points[k] { acc[k].append(sim.inverse(p)); accW[k].append(o.conf[k]) }
                }
            }
            var newPts = [V2?](repeating: nil, count: HeadPoint.count)
            for k in 0..<HeadPoint.count where acc[k].count >= 2 {
                // weighted coordinate-wise median (robust)
                let xs = acc[k].map { $0.x }, ys = acc[k].map { $0.y }
                newPts[k] = V2(Stats.median(xs) ?? 0, Stats.median(ys) ?? 0)
            }
            guard newPts.compactMap({ $0 }).count >= 3 else { break }
            tmpl.points = newPts
            tmpl.normalise()
        }
        return tmpl
    }

    mutating func normalise() {
        let ps = points.compactMap { $0 }
        guard ps.count >= 2 else { return }
        let c = ps.reduce(V2(0, 0), +) / Double(ps.count)
        var r = 0.0
        for p in ps { r += (p - c).length.squared() }
        r = (r / Double(ps.count)).squareRoot()
        guard r > 1e-9 else { return }
        var ang = 0.0
        if let b = points[HeadPoint.beak.rawValue] {
            let d = b - c
            ang = atan2(d.y, d.x)
        }
        // Make the template "upright": for a right-facing head, crown should have negative y (image y-down).
        points = points.map { $0.map { (($0 - c) / r).rotated(-ang) } }
        if let cr = points[HeadPoint.crown.rawValue] ?? points[HeadPoint.forehead.rawValue], cr.y > 0 {
            points = points.map { $0.map { V2($0.x, -$0.y) } }
        }
    }

    /// Fit template -> observation; tries both handedness and returns the better one.
    public func fit(_ o: HeadObservation, preferReflect: Bool? = nil) -> (Similarity, Double)? {
        var src: [V2] = [], dst: [V2] = [], w: [Double] = []
        for k in 0..<HeadPoint.count {
            if let q = points[k], let p = o.points[k] { src.append(q); dst.append(p); w.append(max(0.05, o.conf[k])) }
        }
        guard src.count >= 2 else { return nil }
        // With only 2 points reflection is ambiguous; use the sequence's dominant handedness then.
        if src.count == 2 { return Similarity.fit(src: src, dst: dst, w: w, reflect: preferReflect ?? false) }
        let a = Similarity.fit(src: src, dst: dst, w: w, reflect: false)
        guard let b = Similarity.fit(src: src, dst: dst, w: w, reflect: true) else { return a }
        guard let aa = a else { return b }
        return b.1 < aa.1 * 0.8 ? b : aa
    }
}
