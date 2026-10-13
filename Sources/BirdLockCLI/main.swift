import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import BirdLockCore

setvbuf(stdout, nil, _IOLBF, 0)

func arg(_ name: String, _ def: String? = nil) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--" + name), i + 1 < a.count { return a[i + 1] }
    return def
}
func flag(_ name: String) -> Bool { CommandLine.arguments.contains("--" + name) }
func positional(_ k: Int) -> String? {
    var out: [String] = []
    var skip = false
    for (i, s) in CommandLine.arguments.enumerated() where i > 0 {
        if skip { skip = false; continue }
        if s.hasPrefix("--") { skip = !["--proxy", "--noreg", "--fresh", "--exif", "--nodeflicker", "--dump-plan", "--focus"].contains(s); continue }
        out.append(s)
    }
    return k < out.count ? out[k] : nil
}

func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

// MARK: - selftest

func selftest() {
    print("== phase correlation")
    let n = 128
    var base = [Float](repeating: 0, count: n * n)
    var rng = SystemRandomNumberGenerator()
    // smooth random texture
    for _ in 0..<40 {
        let cx = Double.random(in: 0..<Double(n), using: &rng), cy = Double.random(in: 0..<Double(n), using: &rng)
        let r = Double.random(in: 3...14, using: &rng), a = Float.random(in: -1...1, using: &rng)
        for y in 0..<n { for x in 0..<n {
            let d = ((Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)) / (r * r)
            base[y * n + x] += a * Float(exp(-d))
        } }
    }
    func sample(_ dx: Double, _ dy: Double) -> GrayPatch {
        // b(x) = a(x - d) with bilinear interpolation
        var out = [Float](repeating: 0, count: n * n)
        for y in 0..<n { for x in 0..<n {
            let sx = Double(x) - dx, sy = Double(y) - dy
            let x0 = Int(floor(sx)), y0 = Int(floor(sy)); let fx = Float(sx - Double(x0)), fy = Float(sy - Double(y0))
            func g(_ xx: Int, _ yy: Int) -> Float { base[((yy % n + n) % n) * n + ((xx % n + n) % n)] }
            out[y * n + x] = (1 - fx) * (1 - fy) * g(x0, y0) + fx * (1 - fy) * g(x0 + 1, y0) + (1 - fx) * fy * g(x0, y0 + 1) + fx * fy * g(x0 + 1, y0 + 1)
        } }
        return GrayPatch(width: n, height: n, data: out)
    }
    let pc = PhaseCorrelator(size: n)
    let a = sample(0, 0)
    var maxErr = 0.0
    for (dx, dy) in [(0.0, 0.0), (1.3, -0.4), (-3.7, 2.25), (6.1, 5.5), (-10.4, -0.8), (0.25, 0.75)] {
        let b = sample(dx, dy)
        let r = pc.correlate(a, b)!
        let e = (r.shift - V2(dx, dy)).length
        maxErr = max(maxErr, e)
        print(String(format: "  true (%.2f, %.2f)  est (%.3f, %.3f)  err %.3f  q %.1f", dx, dy, r.shift.x, r.shift.y, e, r.quality))
    }
    // unrelated patches -> low quality
    var noise = [Float](repeating: 0, count: n * n); for i in noise.indices { noise[i] = Float.random(in: 0...1, using: &rng) }
    let rq = pc.correlate(a, GrayPatch(width: n, height: n, data: noise))!
    print(String(format: "  unrelated q %.1f", rq.quality))
    print(maxErr < 0.15 ? "  PASS" : "  FAIL max err \(maxErr)")

    print("== trajectory solver")
    var truth: [V2] = []; var p = V2(100, 100)
    for _ in 0..<200 { p += V2(Double.random(in: -5...5), Double.random(in: -5...5)); truth.append(p) }
    let meas = truth.map { TrajectorySolver.Measurement(value: $0 + V2(Double.random(in: -4...4), Double.random(in: -4...4)), sigma: 2.3) }
    var links = [TrajectorySolver.Link(delta: nil, sigma: 1)]
    for i in 1..<200 { links.append(.init(delta: truth[i] - truth[i - 1] + V2(Double.random(in: -0.1...0.1), Double.random(in: -0.1...0.1)), sigma: 0.06)) }
    // outliers
    var m2 = meas; m2[50].value! += V2(80, -60); m2[120].value! += V2(-50, 90)
    links[77].delta! += V2(30, 0)
    let sol = TrajectorySolver.solve(measurements: m2, links: links)
    let errs = (0..<200).map { (sol.positions[$0] - truth[$0]).length }
    let rawErr = (0..<200).map { (meas[$0].value! - truth[$0]).length }
    // jitter = frame-to-frame error change
    let jit = (1..<200).map { ((sol.positions[$0] - truth[$0]) - (sol.positions[$0 - 1] - truth[$0 - 1])).length }
    print(String(format: "  raw err mean %.2f  fused err mean %.2f max %.2f  frame-to-frame jitter mean %.3f",
                 rawErr.reduce(0, +) / 200, errs.reduce(0, +) / 200, errs.max()!, jit.reduce(0, +) / 199))
    print(jit.reduce(0, +) / 199 < 0.3 ? "  PASS" : "  FAIL")
}

// MARK: - helpers

func loadModels() -> BirdModels {
    do { return try BirdModels() } catch { fail("model load failed: \(error.localizedDescription)  searched: \(ModelStore.searchDirectories().map { $0.path })") }
}

func analyzeFolder(_ path: String, noReg: Bool = false) -> SequenceAnalysis {
    let url = URL(fileURLWithPath: path)
    let frames = FrameImporter.importFrames([url])
    guard !frames.isEmpty else { fail("no images in \(path)") }
    let fps = FrameImporter.estimateFPS(frames)
    print("frames: \(frames.count)  size: \(frames[0].pixelWidth)x\(frames[0].pixelHeight)  fps≈\(fps)  segments: \(FrameImporter.segments(frames).count)")
    let fp = Analyzer.fingerprint(frames)
    if !flag("fresh"), let cached = ProxyCache.shared.loadAnalysis(fingerprint: fp) {
        print("using cached analysis \(fp)")
        var a = cached
        a.track = TrackBuilder.build(a)
        return a
    }
    let models = loadModels()
    let az = Analyzer(models: models)
    let t0 = Date()
    var lastPrint = Date.distantPast
    let a = try! az.analyze(frames: frames, fps: fps, progress: { st, p in
        if Date().timeIntervalSince(lastPrint) > 1 || p >= 1 { lastPrint = Date(); print(String(format: "  %@ %3.0f%%", st.rawValue, p * 100)) }
    })
    print(String(format: "analysis took %.1fs", Date().timeIntervalSince(t0)))
    ProxyCache.shared.saveAnalysis(a)
    return a
}

func summarize(_ a: SequenceAnalysis) {
    let n = a.count
    guard let t = a.track else { return }
    let withBird = a.perFrame.filter { $0.target != nil }.count
    let eyeVis = t.frames.filter { $0.eyeVisible }.count
    let links = a.perFrame.compactMap { $0.link }
    let q = links.map { $0.quality }
    print("bird found: \(withBird)/\(n)   eye visible: \(eyeVis)/\(n)   links: \(links.count)  link quality median \(String(format: "%.1f", Stats.median(q) ?? 0)) p10 \(String(format: "%.1f", Stats.percentile(q, 0.1) ?? 0))")
    print(String(format: "median head length %.1f px  facingRight %@  reflect %@", t.medianHeadLength, t.facingRight ? "yes" : "no", t.reflectDominant ? "yes" : "no"))
    // Stability diagnostics: residual between solved eye and raw measured eye
    var res: [Double] = []
    for i in 0..<n { if let m = t.frames[i].measuredEye, t.frames[i].eyeVisible { res.append((m - t.frames[i].eye).length / t.frames[i].headLength) } }
    print(String(format: "eye keypoint vs solved: median %.3f HL, p90 %.3f HL", Stats.median(res) ?? 0, Stats.percentile(res, 0.9) ?? 0))
    // registration-vs-solution consistency
    var lr: [Double] = []
    for i in 1..<n { if let l = a.perFrame[i].link { lr.append(((t.frames[i].eye - t.frames[i - 1].eye) - l.delta).length) } }
    print(String(format: "link residual: median %.3f px  p90 %.3f px", Stats.median(lr) ?? 0, Stats.percentile(lr, 0.9) ?? 0))
    let sh = a.perFrame.compactMap { $0.sharpness }
    print(String(format: "sharpness median %.4f  min %.4f", Stats.median(sh) ?? 0, sh.min() ?? 0))
}

/// Debug: draw detections & keypoints on proxies
func writeDebug(_ a: SequenceAnalysis, dir: URL, every: Int) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let t = a.track else { return }
    for i in stride(from: 0, to: a.count, by: max(1, every)) {
        guard let p = ProxyCache.shared.loadProxy(fingerprint: a.fingerprint, index: i) else { continue }
        let k = Double(p.width) / Double(a.frames[i].pixelWidth)
        let W = p.width, H = p.height
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
        ctx.draw(p, in: CGRect(x: 0, y: 0, width: W, height: H))
        func pt(_ v: V2) -> CGPoint { CGPoint(x: v.x * k, y: Double(H) - v.y * k) }
        ctx.setLineWidth(3)
        for (j, b) in a.perFrame[i].birds.enumerated() {
            ctx.setStrokeColor(j == a.perFrame[i].target ? CGColor(red: 0, green: 1, blue: 0, alpha: 1) : CGColor(red: 1, green: 1, blue: 0, alpha: 0.7))
            ctx.stroke(CGRect(x: b.x * k, y: Double(H) - (b.y + b.h) * k, width: b.w * k, height: b.h * k))
        }
        for kp in a.perFrame[i].keypoints {
            let c = pt(kp.p)
            ctx.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: kp.conf))
            ctx.fillEllipse(in: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
        }
        let e = pt(t.frames[i].eye)
        ctx.setStrokeColor(CGColor(red: 0, green: 0.8, blue: 1, alpha: 1))
        ctx.strokeEllipse(in: CGRect(x: e.x - 12, y: e.y - 12, width: 24, height: 24))
        let hc = pt(t.frames[i].headCenter)
        ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
        ctx.stroke(CGRect(x: hc.x - 8, y: hc.y - 8, width: 16, height: 16))
        if let img = ctx.makeImage() { _ = ImageLoader.writeJPEG(img, to: dir.appendingPathComponent(String(format: "dbg_%05d.jpg", i)), quality: 0.8) }
    }
}

// MARK: - synth

/// Make a synthetic burst from one image: random camera shake + slow drift + slight zoom/rotation.
/// Writes frames + truth.json (per-frame affine: out = M * src).
func synth(src: String, out: String, count: Int, seed: UInt64, upscale: Double = 1) {
    guard var img = ImageLoader.load(URL(fileURLWithPath: src)) else { fail("cannot load \(src)") }
    if upscale > 1 {
        let ci0 = CIImage(cgImage: img).applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: upscale, kCIInputAspectRatioKey: 1.0])
        img = CIContext().createCGImage(ci0, from: ci0.extent.integral)!
    }
    let outDir = URL(fileURLWithPath: out)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let W = img.width, H = img.height
    let ci = CIImage(cgImage: img).clampedToExtent()
    let ctx = CIContext()
    struct Truth: Codable { var tx: Double; var ty: Double; var s: Double; var r: Double }
    var truths: [Truth] = []
    var g = SplitMix(seed: seed)
    var shake = V2(0, 0), vel = V2(0, 0)
    for i in 0..<count {
        // random walk camera shake (hand-held 800mm) + jitter
        vel = vel * 0.85 + V2(g.normal() * 3, g.normal() * 3)
        shake += vel
        let drift = V2(Double(i) * 1.5, sin(Double(i) / 15) * 30)
        let t = (shake + drift + V2(g.normal() * 1.2, g.normal() * 1.2)) * max(1, upscale)
        let s = 1 + 0.08 * sin(Double(i) / 40)
        let r = 0.03 * sin(Double(i) / 25)
        truths.append(Truth(tx: t.x, ty: t.y, s: s, r: r))
        // top-left coords: out = c + s R (q - c) + t  (c = image centre)
        let c = V2(Double(W) / 2, Double(H) / 2)
        let xf = FrameXform(a: c, p: c + t, z: s, psi: r, valid: true)
        var T = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: Double(H))
        T = T.concatenating(xf.affine).concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: Double(H)))
        let o = ci.transformed(by: T).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        // noise-free; add slight exposure flicker
        let gain = 1 + 0.06 * g.normal()
        let o2 = o.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                                                                 "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                                                                 "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0)])
        guard let cg = ctx.createCGImage(o2, from: CGRect(x: 0, y: 0, width: W, height: H)) else { continue }
        _ = ImageLoader.writeJPEG(cg, to: outDir.appendingPathComponent(String(format: "SYN%05d.jpg", i)), quality: 0.92)
    }
    try! JSONEncoder().encode(truths).write(to: outDir.appendingPathComponent("truth.json"))
    print("wrote \(count) frames to \(out)")
}

struct SplitMix {
    var s: UInt64
    init(seed: UInt64) { s = seed }
    mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func normal() -> Double { let u1 = max(1e-12, uniform()), u2 = uniform(); return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2) }
}

/// Evaluate stability on a synthetic burst: map the solved eye back through the inverse truth transform.
func evalSynth(_ a: SequenceAnalysis, dir: String) {
    let u = URL(fileURLWithPath: dir).appendingPathComponent("truth.json")
    struct Truth: Codable { var tx: Double; var ty: Double; var s: Double; var r: Double }
    guard let d = try? Data(contentsOf: u), let truths = try? JSONDecoder().decode([Truth].self, from: d), let t = a.track else { return }
    let W = Double(a.frames[0].pixelWidth), H = Double(a.frames[0].pixelHeight)
    let c = V2(W / 2, H / 2)
    func back(_ i: Int, _ p: V2) -> V2 {
        let tr = truths[i]
        let xf = FrameXform(a: c, p: c + V2(tr.tx, tr.ty), z: tr.s, psi: tr.r, valid: true)
        return xf.unmap(p)
    }
    for (name, get) in [("eye solved", { (i: Int) -> V2? in t.frames[i].eye }),
                        ("eye raw", { (i: Int) -> V2? in t.frames[i].eyeVisible ? t.frames[i].measuredEye : nil }),
                        ("head ctr", { (i: Int) -> V2? in t.frames[i].headCenter })] {
        var pts: [V2] = []
        var idx: [Int] = []
        for i in 0..<min(a.count, truths.count) { if let p = get(i) { pts.append(back(i, p)); idx.append(i) } }
        guard pts.count > 2 else { continue }
        let mean = pts.reduce(V2(0, 0), +) / Double(pts.count)
        let rms = (pts.map { ($0 - mean).length.squared }.reduce(0, +) / Double(pts.count)).squareRoot()
        var j: [Double] = []
        for k in 1..<pts.count where idx[k] == idx[k - 1] + 1 { j.append((pts[k] - pts[k - 1]).length) }
        print(String(format: "  %@: n=%d  RMS wobble %.2f px  frame-to-frame %.3f px (median)  [head length %.0f px]",
                     name, pts.count, rms, Stats.median(j) ?? 0, t.medianHeadLength))
    }
}

extension Double { var squared: Double { self * self } }

// MARK: - export

func runExport(_ a: SequenceAnalysis) {
    var comp = Composition()
    if let pid = arg("preset"), let p = CompositionPreset.all.first(where: { $0.id == pid }) { comp = p.composition }
    if let f = arg("framing"), let v = Double(f) { comp.framing = v }
    if let l = arg("lock") { comp.lockPoint = l == "head" ? .headCenter : .eye }
    if let e = arg("edge") { comp.edgeFill = ["shift": .shift, "zoom": .autoZoom, "blur": .blurExtend, "black": .black][e] ?? comp.edgeFill }
    if let m = arg("margin"), let v = Double(m) { comp.edgeMargin = v }
    if let f = arg("follow"), let v = Double(f) { comp.followSoftness = v }
    var ex = ExportSettings()
    if let r = arg("aspect") {
        let parts = r.split(separator: ":").compactMap { Double($0) }
        if parts.count == 2 { ex.aspect = AspectRatio(w: parts[0], h: parts[1], label: r) }
    }
    if let s = arg("short"), let v = Int(s) { ex.shortSide = v }
    if let s = arg("fps"), let v = Double(s) { ex.outputFPS = v }
    if let s = arg("speed"), let v = Double(s) { ex.speed = v }
    if let m = arg("interp"), let v = FrameInterpolation(rawValue: m) { ex.interpolation = v }
    if let c = arg("codec"), let v = VideoCodec(rawValue: c) { ex.codec = v }
    if flag("exif") { ex.overlay.showExif = true }
    if flag("focus") { ex.focusMark.enabled = true }
    if let st = arg("focus-style"), let v = FocusMarkStyle(rawValue: st) { ex.focusMark.enabled = true; ex.focusMark.style = v }
    ex.useFullResolution = !flag("proxy")
    var look = LookSettings()
    if flag("nodeflicker") { look.deflicker = false }
    let sel = FrameSelection()
    var wm = WatermarkSettings()
    if let w = arg("watermark") {
        wm.enabled = true; wm.imagePath = w
        if let v = arg("wm-x").flatMap(Double.init) { wm.centerX = v }
        if let v = arg("wm-y").flatMap(Double.init) { wm.centerY = v }
        if let v = arg("wm-size").flatMap(Double.init) { wm.size = v }
    }
    var audio: AudioSettings? = nil
    if let m = arg("audio") {
        var au = AudioSettings(); au.url = URL(fileURLWithPath: m)
        if let v = arg("audio-offset").flatMap(Double.init) { au.startOffset = v }
        audio = au
    }
    let job = RenderJob(analysis: a, composition: comp, look: look, export: ex, selection: sel, watermark: wm)
    let out = URL(fileURLWithPath: arg("out", "out.\(ex.codec.fileExtension)")!)
    print("export \(job.outputSize.w)x\(job.outputSize.h) \(job.outputFrames.count) frames, used \(job.used.count)/\(a.count), max upscale \(String(format: "%.2f", job.plan.maxUpscale)), decode scale \(job.exportDecodeScale), oob \(job.plan.outOfBoundsFrames) shifted \(job.plan.shiftedFrames) zoomed \(job.plan.zoomedFrames) image-limited \(job.plan.imageLimitedFrames)")
    if flag("dump-plan") {
        for i in job.used {
            let x = job.plan.xforms[i]
            let q = x.sourceQuad(outW: Double(job.outputSize.w), outH: Double(job.outputSize.h))
            print(String(format: "  %3d  p %7.1f %7.1f  z %.4f  quad x %.0f…%.0f y %.0f…%.0f", i, x.p.x, x.p.y, x.z,
                         q.map { $0.x }.min()!, q.map { $0.x }.max()!, q.map { $0.y }.min()!, q.map { $0.y }.max()!))
        }
    }
    let t0 = Date()
    do {
        try VideoExporter().export(job: job, to: out, audio: audio, progress: { p in
            if Int(p * 100) % 20 == 0 { print(String(format: "  %.0f%%", p * 100)) }
        }, isCancelled: { false })
    } catch { fail("export failed: \(error.localizedDescription)") }
    print(String(format: "wrote %@ in %.1fs", out.path, Date().timeIntervalSince(t0)))
    if let st = arg("stills") {
        // a few rendered stills for visual inspection
        let d = URL(fileURLWithPath: st)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let pre = job.used
        for k in stride(from: 0, to: pre.count, by: max(1, pre.count / 6)) {
            let i = pre[k]
            guard let img = job.renderOutput(OutputFrame(a: i, b: i, t: 0, fade: 1), scale: 0.5, fetch: { job.source($0, proxy: true) }) else { continue }
            if let cg = job.renderer.renderCGImage(img) { _ = ImageLoader.writeJPEG(cg, to: d.appendingPathComponent(String(format: "still_%05d.jpg", i))) }
        }
    }
}


// MARK: - icon

func drawIcon(size S: Int) -> CGImage? {
    let s = CGFloat(S)
    guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    // macOS icon grid: rounded square inset ~10%
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(path); ctx.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
        CGColor(red: 0.16, green: 0.20, blue: 0.27, alpha: 1), CGColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    let c = CGPoint(x: rect.midX, y: rect.midY)
    // viewfinder corner brackets
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85)); ctx.setLineWidth(s * 0.022); ctx.setLineCap(.round)
    let b = rect.width * 0.30, L = rect.width * 0.09
    for (dx, dy) in [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)] {
        let px = c.x + CGFloat(dx) * b, py = c.y + CGFloat(dy) * b
        ctx.move(to: CGPoint(x: px, y: py - CGFloat(dy) * L)); ctx.addLine(to: CGPoint(x: px, y: py)); ctx.addLine(to: CGPoint(x: px - CGFloat(dx) * L, y: py))
    }
    ctx.strokePath()
    // the eye: amber iris ring, dark pupil, highlight
    let r = rect.width * 0.17
    ctx.setFillColor(CGColor(red: 0.98, green: 0.72, blue: 0.24, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.setFillColor(CGColor(red: 0.85, green: 0.35, blue: 0.12, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - r * 0.78, y: c.y - r * 0.78, width: 1.56 * r, height: 1.56 * r))
    ctx.setFillColor(CGColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - r * 0.55, y: c.y - r * 0.55, width: 1.1 * r, height: 1.1 * r))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.fillEllipse(in: CGRect(x: c.x + r * 0.12, y: c.y + r * 0.12, width: r * 0.32, height: r * 0.32))
    // crosshair ticks
    ctx.setStrokeColor(CGColor(red: 0.25, green: 0.85, blue: 1.0, alpha: 0.9)); ctx.setLineWidth(s * 0.012)
    let t0 = r * 1.25, t1 = r * 1.7
    for a in [0.0, .pi / 2, .pi, 3 * .pi / 2] {
        ctx.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * t0, y: c.y + CGFloat(sin(a)) * t0))
        ctx.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * t1, y: c.y + CGFloat(sin(a)) * t1))
    }
    ctx.strokePath()
    ctx.restoreGState()
    return ctx.makeImage()
}

func makeIconset(_ dir: String) {
    let d = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"),
                       (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
        if let img = drawIcon(size: px) { _ = ImageLoader.writePNG(img, to: d.appendingPathComponent("icon_\(name).png")) }
    }
    print("iconset -> \(dir)")
}


// MARK: - video frames (for testing with real flight footage)


func extractFrames(video: String, out: String, maxFrames: Int, start: Double) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: video))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let sem = DispatchSemaphore(value: 0)
    var fps = 30.0
    var dur = 0.0
    Task {
        if let t = try? await asset.loadTracks(withMediaType: .video).first {
            fps = Double((try? await t.load(.nominalFrameRate)) ?? 30)
        }
        dur = (try? await asset.load(.duration).seconds) ?? 0
        sem.signal()
    }
    sem.wait()
    let d = URL(fileURLWithPath: out)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    var k = 0
    var t = start
    while t < dur && k < maxFrames {
        let ct = CMTime(seconds: t, preferredTimescale: 60000)
        if let img = try? gen.copyCGImage(at: ct, actualTime: nil) {
            _ = ImageLoader.writeJPEG(img, to: d.appendingPathComponent(String(format: "VID%05d.jpg", k)), quality: 0.92)
            k += 1
        }
        t += 1 / fps
    }
    print("extracted \(k) frames (\(fps) fps, \(dur)s) -> \(out)")
}

// MARK: - main

let cmd = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "help"
switch cmd {
case "selftest":
    selftest()
case "models":
    let m = loadModels()
    print("detector input \(m.detector.inputSize) classes \(m.detector.numClasses) bird idx \(m.detector.birdClassIndex) out \(m.detector.outputName)")
    print("pose input \(m.pose.inputSize) kps \(m.pose.numKeypoints) schema \(m.schema.keypoints)")
case "detect":
    // quick single-image test: detect + pose, prints results
    guard let p = positional(1), let img = ImageLoader.load(URL(fileURLWithPath: p), maxPixel: 2560) else { fail("usage: detect <image>") }
    let m = loadModels()
    let t0 = Date()
    let d = try! m.detector.detect(image: img, scoreThreshold: 0.15)
    print(String(format: "detector %.0f ms", Date().timeIntervalSince(t0) * 1000))
    for b in d { print(String(format: "  bird %.2f  box %.0f,%.0f %.0fx%.0f", b.score, b.x, b.y, b.w, b.h)) }
    if let b = d.first {
        let side = max(b.w, b.h) * 1.25
        let crop = CGRect(x: b.center.x - side / 2, y: b.center.y - side / 2, width: side, height: side)
        let t1 = Date()
        let ps = try! m.pose.detect(image: img, crop: crop, classIndex: 0, scoreThreshold: 0.1)
        print(String(format: "pose %.0f ms", Date().timeIntervalSince(t1) * 1000))
        if let q = ps.first {
            print(String(format: "  pose box %.2f  %.0f,%.0f %.0fx%.0f", q.score, q.x, q.y, q.w, q.h))
            for (i, k) in q.keypoints.enumerated() { print(String(format: "   %-14@ %.1f, %.1f  conf %.2f", m.schema.keypoints[i], k.x, k.y, k.conf)) }
        }
    }
case "analyze":
    guard let dir = positional(1) else { fail("usage: analyze <folder> [--debug dir] [--every n] [--fresh]") }
    let a = analyzeFolder(dir)
    summarize(a)
    if let d = arg("debug") { writeDebug(a, dir: URL(fileURLWithPath: d), every: Int(arg("every", "10")!) ?? 10) }
    if FileManager.default.fileExists(atPath: URL(fileURLWithPath: dir).appendingPathComponent("truth.json").path) { evalSynth(a, dir: dir) }
    if let o = arg("json") { try! JSONEncoder().encode(a).write(to: URL(fileURLWithPath: o)) }
    if let o = arg("csv"), let t = a.track {
        var lines = ["i,vis,mx,my,ex,ey,cx,cy,hl,ang,ldx,ldy,lq,bx,by,bw,bh,kconf"]
        for i in 0..<a.count {
            let f = t.frames[i]; let pf = a.perFrame[i]
            let m = f.measuredEye; let l = pf.link; let b = pf.targetBox
            let ec = pf.head.conf[HeadPoint.eye.rawValue]
            func o(_ v: Double?) -> String { v.map { String($0) } ?? "" }
            var cols: [String] = [String(i), f.eyeVisible ? "1" : "0", o(m?.x), o(m?.y)]
            cols += [o(f.eye.x), o(f.eye.y), o(f.headCenter.x), o(f.headCenter.y), o(f.headLength), o(f.angle)]
            cols += [o(l?.delta.x), o(l?.delta.y), o(l?.quality)]
            cols += [o(b?.x), o(b?.y), o(b?.w), o(b?.h), o(ec)]
            lines.append(cols.joined(separator: ","))
        }
        try! lines.joined(separator: "\n").write(toFile: o, atomically: true, encoding: .utf8)
    }
case "export":
    guard let dir = positional(1) else { fail("usage: export <folder> --out x.mp4 [--preset id] [--aspect 9:16] [--short 1080] [--fps 30] [--speed 1] [--proxy]") }
    let a = analyzeFolder(dir)
    runExport(a)
case "frames":
    guard let v = positional(1), let o = positional(2) else { fail("usage: frames <video> <outdir> [--max 300] [--start 0]") }
    extractFrames(video: v, out: o, maxFrames: Int(arg("max", "300")!) ?? 300, start: Double(arg("start", "0")!) ?? 0)
case "icon":
    makeIconset(positional(1) ?? "AppIcon.iconset")
case "synth":
    guard let s = positional(1), let o = positional(2) else { fail("usage: synth <image> <outdir> [--count 90]") }
    synth(src: s, out: o, count: Int(arg("count", "90")!) ?? 90, seed: UInt64(arg("seed", "7")!) ?? 7, upscale: Double(arg("upscale", "1")!) ?? 1)
default:
    print("birdlock-cli selftest | models | detect <img> | analyze <dir> | export <dir> | synth <img> <dir>")
}
