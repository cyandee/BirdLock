import Foundation
import Accelerate

/// Sub-pixel translation estimation between two equally sized square patches (power-of-two side).
///
/// Windowed phase correlation with a Gaussian-shaped correlation peak (frequency-domain low-pass),
/// log-parabolic peak interpolation and iterative re-centering (the second patch is Fourier-shifted by
/// the current estimate before windowing), which removes the window bias. Accuracy ≈ 0.05 px.
public final class PhaseCorrelator {
    public let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var lowpass: [Float]
    private var kx: [Float]   // signed frequency index per column/row

    public struct Result: Sendable {
        /// Shift such that b(x) ≈ a(x − shift)  (content moved by `shift` from a to b)
        public var shift: V2
        /// Peak-to-sidelobe ratio (higher = more reliable)
        public var quality: Double
    }

    public init(size: Int, peakSigma: Double = 1.1) {
        precondition(size > 0 && (size & (size - 1)) == 0, "size must be a power of two")
        n = size
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 1, count: size * size)
        lowpass = [Float](repeating: 1, count: size * size)
        kx = (0..<size).map { Float($0 <= size / 2 ? $0 : $0 - size) }
        let a = 2 * Double.pi * peakSigma / Double(size)
        for y in 0..<size { for x in 0..<size {
            let k2 = Double(kx[x] * kx[x] + kx[y] * kx[y])
            lowpass[y * size + x] = Float(exp(-0.5 * k2 * a * a))
        } }
        setGaussianWindow(sigma: Double(size) / 5)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Gaussian window (sigma in pixels) times a Hann border taper.
    public func setGaussianWindow(sigma: Double, center: V2? = nil) {
        let c = center ?? V2(Double(n - 1) / 2, Double(n - 1) / 2)
        for y in 0..<n {
            for x in 0..<n {
                let dx = Double(x) - c.x, dy = Double(y) - c.y
                var w = exp(-0.5 * (dx * dx + dy * dy) / (sigma * sigma))
                let hx = 0.5 - 0.5 * cos(2 * .pi * Double(x) / Double(n - 1))
                let hy = 0.5 - 0.5 * cos(2 * .pi * Double(y) / Double(n - 1))
                w *= (hx * hy).squareRoot()
                window[y * n + x] = Float(w)
            }
        }
    }

    private func fft(_ re: inout [Float], _ im: inout [Float], inverse: Bool) {
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft2d_zip(setup, &sc, 1, 0, log2n, log2n, FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward))
            }
        }
    }

    /// Windowed, mean-removed forward FFT.
    private func forward(_ img: [Float], mask: [Float]?) -> ([Float], [Float]) {
        let N = n * n
        var w = window
        if let mask { vDSP_vmul(w, 1, mask, 1, &w, 1, vDSP_Length(N)) }
        var sw: Float = 0, swx: Float = 0
        vDSP_sve(w, 1, &sw, vDSP_Length(N))
        var tmp = [Float](repeating: 0, count: N)
        vDSP_vmul(img, 1, w, 1, &tmp, 1, vDSP_Length(N))
        vDSP_sve(tmp, 1, &swx, vDSP_Length(N))
        var mean = sw > 0 ? -swx / sw : 0
        var re = [Float](repeating: 0, count: N)
        vDSP_vsadd(img, 1, &mean, &re, 1, vDSP_Length(N))
        vDSP_vmul(re, 1, w, 1, &re, 1, vDSP_Length(N))
        var im = [Float](repeating: 0, count: N)
        fft(&re, &im, inverse: false)
        return (re, im)
    }

    /// b'(x) = b(x + d)  (periodic, exact for band-limited content)
    private func fourierShift(_ img: [Float], by d: V2) -> [Float] {
        let N = n * n
        var re = img
        var im = [Float](repeating: 0, count: N)
        fft(&re, &im, inverse: false)
        let s = 2 * Double.pi / Double(n)
        for y in 0..<n {
            for x in 0..<n {
                let ph = s * (Double(kx[x]) * d.x + Double(kx[y]) * d.y)
                let c = Float(cos(ph)), si = Float(sin(ph))
                let i = y * n + x
                let r0 = re[i], i0 = im[i]
                re[i] = r0 * c - i0 * si
                im[i] = r0 * si + i0 * c
            }
        }
        fft(&re, &im, inverse: true)
        var scale = 1 / Float(N)
        vDSP_vsmul(re, 1, &scale, &re, 1, vDSP_Length(N))
        return re
    }

    private func peak(_ A: ([Float], [Float]), _ B: ([Float], [Float])) -> (V2, Double) {
        let N = n * n
        var rr = [Float](repeating: 0, count: N)
        var ri = [Float](repeating: 0, count: N)
        let (ar, ai) = A, (br, bi) = B
        for k in 0..<N {
            let xr = ar[k] * br[k] + ai[k] * bi[k]
            let xi = ar[k] * bi[k] - ai[k] * br[k]
            let m = lowpass[k] / ((xr * xr + xi * xi).squareRoot() + 1e-9)
            rr[k] = xr * m; ri[k] = xi * m
        }
        fft(&rr, &ri, inverse: true)
        var maxV: Float = -.infinity
        var maxI: vDSP_Length = 0
        vDSP_maxvi(rr, 1, &maxV, &maxI, vDSP_Length(N))
        let py = Int(maxI) / n, px = Int(maxI) % n
        func at(_ x: Int, _ y: Int) -> Double { Double(rr[((y + n) % n) * n + ((x + n) % n)]) }
        func sub(_ l: Double, _ c: Double, _ r: Double) -> Double {
            let L = log(max(l, 1e-9)), C = log(max(c, 1e-9)), R = log(max(r, 1e-9))
            let d = L - 2 * C + R
            return abs(d) < 1e-12 ? 0 : clamp(0.5 * (L - R) / d, -0.5, 0.5)
        }
        let c0 = at(px, py)
        var sx = Double(px) + sub(at(px - 1, py), c0, at(px + 1, py))
        var sy = Double(py) + sub(at(px, py - 1), c0, at(px, py + 1))
        if sx > Double(n) / 2 { sx -= Double(n) }
        if sy > Double(n) / 2 { sy -= Double(n) }
        // peak-to-sidelobe ratio outside a small neighbourhood
        var sum = 0.0, sum2 = 0.0, cnt = 0.0
        for y in 0..<n {
            var ddy = abs(y - py); ddy = min(ddy, n - ddy)
            for x in 0..<n {
                var ddx = abs(x - px); ddx = min(ddx, n - ddx)
                if ddx <= 4 && ddy <= 4 { continue }
                let v = Double(rr[y * n + x]); sum += v; sum2 += v * v; cnt += 1
            }
        }
        let mean = sum / cnt
        let sd = max(1e-12, (sum2 / cnt - mean * mean).squareRoot())
        return (V2(sx, sy), (c0 - mean) / sd)
    }

    public func correlate(_ a: GrayPatch, _ b: GrayPatch, mask: [Float]? = nil, iterations: Int = 3) -> Result? {
        guard a.width == n, a.height == n, b.width == n, b.height == n else { return nil }
        let A = forward(a.data, mask: mask)
        var d = V2(0, 0)
        var q = 0.0
        for it in 0...iterations {
            let bb = it == 0 ? b.data : fourierShift(b.data, by: d)
            let (s, qq) = peak(A, forward(bb, mask: mask))
            d += s
            if it == 0 { q = qq }
            if s.length < 0.005 { break }
            if d.length > Double(n) / 3 { break }   // runaway – give up refining
        }
        return Result(shift: d, quality: q)
    }
}
