import Foundation
import CoreImage
import CoreGraphics
import BirdLockCore

/// Renders preview frames off the main thread from cached proxies. Only the latest request is honoured.
final class PreviewEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "birdlock.preview", qos: .userInteractive)
    private let decodeQueue = DispatchQueue(label: "birdlock.preview.decode", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var proxies: [String: CGImage] = [:]
    private var order: [String] = []
    private var pending: (() -> Void)?
    private var busy = false
    private let limit = 48

    private func key(_ job: RenderJob, _ i: Int) -> String { "\(job.analysis.fingerprint)#\(i)" }

    func proxy(job: RenderJob, index i: Int) -> CGImage? {
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

    func prefetch(job: RenderJob, frames: [Int]) {
        for i in frames {
            decodeQueue.async { [weak self] in _ = self?.proxy(job: job, index: i) }
        }
    }

    private func submit(_ work: @escaping () -> Void) {
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

    func requestSource(job: RenderJob, index: Int, completion: @escaping @MainActor (CGImage?) -> Void) {
        submit { [weak self] in
            let img = self?.proxy(job: job, index: index)
            DispatchQueue.main.async { completion(img) }
        }
    }

    /// - Parameter fullResolution: decode the original file instead of the proxy (sharper, slower – used when paused)
    func requestOutput(job: RenderJob, frame: OutputFrame, maxSide: Int, fullResolution: Bool = false,
                       completion: @escaping @MainActor (CGImage?) -> Void) {
        submit { [weak self] in
            guard let self else { return }
            let (W, H) = job.outputSize
            let scale = min(1, Double(maxSide) / Double(max(W, H)))
            let img = job.renderOutput(frame, scale: scale) { i in
                if fullResolution { return job.source(i, proxy: false) }
                guard let p = self.proxy(job: job, index: i) else { return nil }
                return (CIImage(cgImage: p), Double(p.width) / Double(job.analysis.frames[i].pixelWidth))
            }
            let cg = img.flatMap { job.renderer.renderCGImage($0) }
            DispatchQueue.main.async { completion(cg) }
        }
    }
}
