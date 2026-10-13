import Foundation
import CoreGraphics

public typealias V2 = SIMD2<Double>

public extension SIMD2 where Scalar == Double {
    var length: Double { (x * x + y * y).squareRoot() }
    var cg: CGPoint { CGPoint(x: x, y: y) }
    init(_ p: CGPoint) { self.init(Double(p.x), Double(p.y)) }
    func rotated(_ a: Double) -> V2 {
        let c = cos(a), s = sin(a)
        return V2(c * x - s * y, s * x + c * y)
    }
    static func dot(_ a: V2, _ b: V2) -> Double { a.x * b.x + a.y * b.y }
}

@inline(__always) public func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }

/// Wrap an angle to (-pi, pi]
@inline(__always) public func wrapAngle(_ a: Double) -> Double {
    var r = a.truncatingRemainder(dividingBy: 2 * .pi)
    if r > .pi { r -= 2 * .pi }
    if r <= -.pi { r += 2 * .pi }
    return r
}

public enum Stats {
    public static func median(_ xs: [Double]) -> Double? {
        let v = xs.filter { $0.isFinite }.sorted()
        guard !v.isEmpty else { return nil }
        let n = v.count
        return n % 2 == 1 ? v[n / 2] : 0.5 * (v[n / 2 - 1] + v[n / 2])
    }

    public static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        let v = xs.filter { $0.isFinite }.sorted()
        guard !v.isEmpty else { return nil }
        let pos = clamp(p, 0, 1) * Double(v.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, v.count - 1)
        let t = pos - Double(lo)
        return v[lo] * (1 - t) + v[hi] * t
    }

    public static func mad(_ xs: [Double]) -> Double? {
        guard let m = median(xs) else { return nil }
        return median(xs.map { abs($0 - m) }).map { $0 * 1.4826 }
    }
}

/// 1-D signal helpers that tolerate missing values (NaN).
public enum Signal {
    /// Linear interpolation over NaN gaps; edges are held constant.
    public static func fillGaps(_ x: [Double]) -> [Double] {
        var out = x
        let n = x.count
        guard n > 0 else { return out }
        let valid = (0..<n).filter { x[$0].isFinite }
        guard let first = valid.first, let last = valid.last else { return out }
        for i in 0..<first { out[i] = x[first] }
        for i in (last + 1)..<n where last + 1 < n { out[i] = x[last] }
        var prev = first
        for v in valid.dropFirst() {
            if v - prev > 1 {
                for i in (prev + 1)..<v {
                    let t = Double(i - prev) / Double(v - prev)
                    out[i] = x[prev] * (1 - t) + x[v] * t
                }
            }
            prev = v
        }
        return out
    }

    /// Gaussian smoothing with NaN-aware normalised weights. sigma in samples.
    public static func gaussian(_ x: [Double], sigma: Double, weights: [Double]? = nil) -> [Double] {
        let n = x.count
        guard n > 0, sigma > 0.01 else { return x }
        let r = max(1, Int((sigma * 3).rounded(.up)))
        var k = [Double](repeating: 0, count: 2 * r + 1)
        for i in -r...r { k[i + r] = exp(-0.5 * Double(i * i) / (sigma * sigma)) }
        var out = [Double](repeating: .nan, count: n)
        for i in 0..<n {
            var s = 0.0, ws = 0.0
            let lo = max(0, i - r), hi = min(n - 1, i + r)
            for j in lo...hi where x[j].isFinite {
                let w = k[j - i + r] * (weights?[j] ?? 1)
                s += w * x[j]; ws += w
            }
            if ws > 1e-12 { out[i] = s / ws }
        }
        return out
    }

    /// Running median (NaN ignored), window = 2*r+1.
    public static func median(_ x: [Double], radius r: Int) -> [Double] {
        let n = x.count
        guard r > 0 else { return x }
        return (0..<n).map { i in
            let lo = max(0, i - r), hi = min(n - 1, i + r)
            return Stats.median(Array(x[lo...hi])) ?? .nan
        }
    }

    /// Unwrap a sequence of angles so it has no 2π jumps (NaN-aware).
    public static func unwrapAngles(_ a: [Double]) -> [Double] {
        var out = a
        var last: Double? = nil
        for i in 0..<a.count where a[i].isFinite {
            if let l = last {
                var v = a[i]
                while v - l > .pi { v -= 2 * .pi }
                while v - l < -.pi { v += 2 * .pi }
                out[i] = v
            }
            last = out[i]
        }
        return out
    }

    /// Running maximum, window = 2*r+1.
    public static func runningMax(_ x: [Double], radius r: Int) -> [Double] {
        let n = x.count
        return (0..<n).map { i in
            let lo = max(0, i - r), hi = min(n - 1, i + r)
            return x[lo...hi].max() ?? x[i]
        }
    }
}
