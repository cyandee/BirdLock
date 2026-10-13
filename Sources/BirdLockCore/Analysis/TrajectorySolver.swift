import Foundation

/// Fuses absolute per-frame measurements (noisy keypoints) with relative inter-frame displacements
/// (precise sub-pixel registration) into one trajectory, by robust (IRLS / Huber) least squares:
///
///   minimise  Σ_i w_i |x_i − m_i|²  +  Σ_i λ_i |x_i − x_{i−1} − r_i|²
///
/// Solved per axis with a tridiagonal (Thomas) solver; weights are re-estimated jointly in 2-D
/// (Huber for measurements, redescending Cauchy for links).
public enum TrajectorySolver {
    public struct Measurement {
        public var value: V2?      // absolute position (nil = missing)
        public var sigma: Double   // std-dev in pixels
        public init(value: V2?, sigma: Double) { self.value = value; self.sigma = sigma }
    }
    public struct Link {
        public var delta: V2?      // x_i - x_{i-1}  (nil = no registration)
        public var sigma: Double
        public init(delta: V2?, sigma: Double) { self.delta = delta; self.sigma = sigma }
    }

    public struct Output {
        public var positions: [V2]
        public var measurementInlier: [Bool]
        public var linkInlier: [Bool]
    }

    /// `links[i]` connects frame i-1 -> i (links[0] ignored).
    public static func solve(measurements m: [Measurement], links: [Link], cauchyK: Double = 3.0, iterations: Int = 12) -> Output {
        let n = m.count
        guard n > 0 else { return Output(positions: [], measurementInlier: [], linkInlier: []) }
        var w0 = m.map { $0.value == nil ? 0 : 1 / max(1e-6, $0.sigma * $0.sigma) }
        let l0 = (0..<n).map { i -> Double in
            guard i > 0, i < links.count, links[i].delta != nil else { return 0 }
            return 1 / max(1e-6, links[i].sigma * links[i].sigma)
        }
        // If no absolute measurement at all we cannot solve.
        if w0.allSatisfy({ $0 == 0 }) {
            return Output(positions: Array(repeating: V2(0, 0), count: n), measurementInlier: Array(repeating: false, count: n),
                          linkInlier: Array(repeating: false, count: n))
        }
        // Tiny prior towards the gap-filled measurement keeps disconnected components well posed.
        let filledX = Signal.fillGaps(m.map { $0.value?.x ?? .nan })
        let filledY = Signal.fillGaps(m.map { $0.value?.y ?? .nan })
        let minW = (w0.filter { $0 > 0 }.min() ?? 1) * 1e-6
        for i in 0..<n where w0[i] == 0 { w0[i] = minW }
        let mx = (0..<n).map { m[$0].value?.x ?? filledX[$0] }
        let my = (0..<n).map { m[$0].value?.y ?? filledY[$0] }
        let rx = (0..<n).map { i in i < links.count ? (links[i].delta?.x ?? 0) : 0 }
        let ry = (0..<n).map { i in i < links.count ? (links[i].delta?.y ?? 0) : 0 }

        var w = w0, l = l0
        var x = mx, y = my
        var mIn = [Bool](repeating: true, count: n), lIn = [Bool](repeating: true, count: n)
        for _ in 0..<iterations {
            x = thomas(w: w, l: l, m: mx, r: rx)
            y = thomas(w: w, l: l, m: my, r: ry)
                // Measurements: Huber (bounded influence but never fully rejected, so a slowly drifting
            // registration chain is always pulled back towards the keypoints)
            for i in 0..<n where w0[i] > minW {
                let e = V2(x[i] - mx[i], y[i] - my[i]).length
                let s = m[i].sigma
                let k = 1.5 * s
                w[i] = e <= k ? w0[i] : w0[i] * k / e
                mIn[i] = e <= 3 * s
            }
            // Links: Cauchy (redescending) – a failed registration loses all influence
            for i in 1..<n where l0[i] > 0 {
                let e = V2(x[i] - x[i - 1] - rx[i], y[i] - y[i - 1] - ry[i]).length
                let s = links[i].sigma
                let u = e / (cauchyK * s)
                l[i] = l0[i] / (1 + u * u)
                lIn[i] = e <= 3 * s
            }
        }
        return Output(positions: (0..<n).map { V2(x[$0], y[$0]) }, measurementInlier: mIn, linkInlier: lIn)
    }

    /// Solve the tridiagonal normal equations for one axis.
    static func thomas(w: [Double], l: [Double], m: [Double], r: [Double]) -> [Double] {
        let n = w.count
        var a = [Double](repeating: 0, count: n)   // sub-diagonal (i, i-1)
        var b = [Double](repeating: 0, count: n)   // diagonal
        var c = [Double](repeating: 0, count: n)   // super-diagonal (i, i+1)
        var d = [Double](repeating: 0, count: n)
        for i in 0..<n {
            b[i] = w[i]
            d[i] = w[i] * m[i]
            if i > 0 { b[i] += l[i]; a[i] = -l[i]; d[i] += l[i] * r[i] }
            if i + 1 < n { b[i] += l[i + 1]; c[i] = -l[i + 1]; d[i] -= l[i + 1] * r[i + 1] }
        }
        // forward sweep
        var cp = [Double](repeating: 0, count: n), dp = [Double](repeating: 0, count: n)
        cp[0] = c[0] / b[0]; dp[0] = d[0] / b[0]
        if n > 1 {
            for i in 1..<n {
                let den = b[i] - a[i] * cp[i - 1]
                cp[i] = c[i] / den
                dp[i] = (d[i] - a[i] * dp[i - 1]) / den
            }
        }
        var x = [Double](repeating: 0, count: n)
        x[n - 1] = dp[n - 1]
        if n > 1 { for i in stride(from: n - 2, through: 0, by: -1) { x[i] = dp[i] - cp[i] * x[i + 1] } }
        return x
    }
}
