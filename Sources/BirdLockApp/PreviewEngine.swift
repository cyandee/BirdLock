import Foundation
import CoreImage
import CoreGraphics
import BirdLockCore

/// A serial queue that only keeps the most recent pending job (older pending work is dropped).
final class LatestOnlyQueue: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: (() -> Void)?
    private var busy = false

    init(label: String, qos: DispatchQoS) { queue = DispatchQueue(label: label, qos: qos) }

    func submit(_ work: @escaping () -> Void) {
        lock.lock()
        if busy { pending = work; lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async { [weak self] in self?.run(work) }
    }

    private func run(_ work: @escaping () -> Void) {
        autoreleasepool { work() }
        lock.lock()
        if let next = pending {
            pending = nil
            lock.unlock()
            queue.async { [weak self] in self?.run(next) }
        } else {
            busy = false
            lock.unlock()
        }
    }
}

/// Renders preview frames off the main thread from cached proxies. Only the latest request is honoured.
/// Sharper sources (decoded from the originals at just the resolution needed) are produced on a separate
/// queue so slow decodes never hold up scrubbing.
final class PreviewEngine: @unchecked Sendable {
    private let render = LatestOnlyQueue(label: "birdlock.preview", qos: .userInteractive)
    private let hiRes = LatestOnlyQueue(label: "birdlock.preview.hires", qos: .userInitiated)
    private let decodeQueue = DispatchQueue(label: "birdlock.preview.decode", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var proxies: [String: CGImage] = [:]
    private var order: [String] = []
    private let limit = 40
    // decoded originals at reduced scale, bounded by memory
    private var originals: [String: (image: CIImage, scale: Double, bytes: Int)] = [:]
    private var originalOrder: [String] = []
    private let originalBudget = 900 << 20

    private func key(_ job: RenderJob, _ i: Int) -> String { "\(job.analysis.fingerprint)#\(i)" }

    func proxy(job: RenderJob, index i: Int) -> CGImage? {
        guard i >= 0, i < job.analysis.count else { return nil }
        let k = key(job, i)
        lock.lock()
        if let p = proxies[k] { lock.unlock(); return p }
        lock.unlock()
        guard let p = job.cache.loadProxy(fingerprint: job.analysis.fingerprint, index: i) else { return nil }
        lock.lock()
        proxies[k] = p; order.append(k)
        while order.count > limit { let r = order.removeFirst(); proxies[r] = nil }
        lock.unlock()
        return p
    }

    /// Original decoded at `scale` (cached).
    func original(job: RenderJob, index i: Int, scale: Double) -> (CIImage, Double)? {
        let k = "\(key(job, i))@\(scale)"
        lock.lock()
        if let o = originals[k] {
            originalOrder.removeAll { $0 == k }; originalOrder.append(k)
            lock.unlock(); return (o.image, o.scale)
        }
        lock.unlock()
        guard let (img, s) = job.source(i, proxy: false, scale: scale) else { return nil }
        let bytes = Int(img.extent.width * img.extent.height) * 4
        lock.lock()
        originals[k] = (img, s, bytes); originalOrder.append(k)
        var total = originals.values.reduce(0) { $0 + $1.bytes }
        while total > originalBudget, originalOrder.count > 1 {
            let r = originalOrder.removeFirst()
            total -= originals[r]?.bytes ?? 0
            originals[r] = nil
        }
        lock.unlock()
        return (img, s)
    }

    func prefetch(job: RenderJob, frames: [Int]) {
        for i in frames {
            decodeQueue.async { [weak self] in _ = self?.proxy(job: job, index: i) }
        }
    }

    func requestSource(job: RenderJob, index: Int, completion: @escaping @MainActor (CGImage?) -> Void) {
        render.submit { [weak self] in
            let img = self?.proxy(job: job, index: index)
            DispatchQueue.main.async { completion(img) }
        }
    }

    /// Sharp crop of the original around `region` (source px) for the zoomed source view.
    /// - Parameter pixelsAcross: display pixels the region will cover (decides the decode scale)
    func requestSourceDetail(job: RenderJob, index: Int, region: CGRect, pixelsAcross: Double,
                             completion: @escaping @MainActor (CGImage?, CGRect) -> Void) {
        hiRes.submit { [weak self] in
            guard let self, index >= 0, index < job.analysis.count else { return }
            let f = job.analysis.frames[index]
            let full = CGRect(x: 0, y: 0, width: f.pixelWidth, height: f.pixelHeight)
            let r = region.intersection(full)
            guard !r.isNull, r.width > 4, r.height > 4 else { return }
            let needed = min(1, pixelsAcross / Double(r.width) * 1.1)
            let proxyScale = Double(job.analysis.proxyLongSide) / Double(max(f.pixelWidth, f.pixelHeight))
            guard needed > proxyScale * 1.05 else { return }   // the proxy is already sharp enough
            let s = decodeScale(needed: needed)
            guard let (img, k) = self.original(job: job, index: index, scale: s) else { return }
            // region (top-left source px) -> CI coords of the decoded image
            let H = img.extent.height
            let ci = CGRect(x: r.minX * k, y: H - r.maxY * k, width: r.width * k, height: r.height * k).integral
                .intersection(img.extent)
            let cg = job.renderer.context.createCGImage(img, from: ci, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let back = CGRect(x: ci.minX / k, y: (H - ci.maxY) / k, width: ci.width / k, height: ci.height / k)
            DispatchQueue.main.async { completion(cg, back) }
        }
    }

    /// - Parameter fullResolution: render from the originals (decoded at just the scale needed) instead of
    ///   the proxies – sharper, slower; used when paused. Skipped when the proxy already has enough pixels.
    func requestOutput(job: RenderJob, frame: OutputFrame, maxSide: Int, fullResolution: Bool = false,
                       completion: @escaping @MainActor (CGImage?) -> Void) {
        guard job.contains(frame.a), job.contains(frame.b) else { return }
        let (W, H) = job.outputSize
        let scale = min(1, Double(maxSide) / Double(max(W, H)))
        if fullResolution {
            let f = job.analysis.frames[frame.a]
            let proxyScale = Double(job.analysis.proxyLongSide) / Double(max(f.pixelWidth, f.pixelHeight))
            let needed = min(1, max(job.plan.xforms[frame.a].z, job.plan.xforms[frame.b].z) * scale * 1.2)
            guard needed > proxyScale * 1.05 else { return }
            let s = decodeScale(needed: needed)
            hiRes.submit { [weak self] in
                guard let self else { return }
                var src: [Int: (CIImage, Double)] = [:]
                for i in Set([frame.a, frame.b]) { src[i] = self.original(job: job, index: i, scale: s) }
                self.render.submit {
                    let img = job.renderOutput(frame, scale: scale, includeWatermark: false) { src[$0] }
                    let cg = img.flatMap { job.renderer.renderCGImage($0) }
                    DispatchQueue.main.async { completion(cg) }
                }
            }
            return
        }
        render.submit { [weak self] in
            guard let self else { return }
            let img = job.renderOutput(frame, scale: scale, includeWatermark: false) { i in
                guard let p = self.proxy(job: job, index: i) else { return nil }
                return (CIImage(cgImage: p), Double(p.width) / Double(job.analysis.frames[i].pixelWidth))
            }
            let cg = img.flatMap { job.renderer.renderCGImage($0) }
            DispatchQueue.main.async { completion(cg) }
        }
    }
}
