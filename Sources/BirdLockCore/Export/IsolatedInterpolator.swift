import Foundation
import CoreImage
import Darwin

/// Bound VideoToolbox working memory across a long export. Large frames get
/// shorter worker lifetimes; recycling never changes the video time mapping.
public struct OpticalFlowWorkBudget {
    public let requestLimit: Int
    private var requests = 0
    public init(width: Int, height: Int) {
        guard width > 0, height > 0, width <= 8192, height <= 4320 else { requestLimit = 1; return }
        requestLimit = max(4, min(64, 240_000_000 / (width * height)))
    }
    public mutating func beginRequest() -> Bool {
        let recycle = requests >= requestLimit
        if recycle { requests = 0 }
        requests += 1
        return recycle
    }
}

/// Fixed-size local pipe protocol. The worker never receives file paths or user metadata.
public enum FlowWorkerIO {
    public static func read(_ handle: FileHandle, count: Int) throws -> Data? {
        var data = Data(); data.reserveCapacity(count)
        while data.count < count {
            guard let next = try handle.read(upToCount: count-data.count), !next.isEmpty else { return nil }
            data.append(next)
        }
        return data
    }
}

/// Native VideoToolbox failures remain in this child. The parent can finish using frame blending.
public final class IsolatedInterpolator {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let context: CIContext
    private let width: Int, height: Int
    private let count: Int
    private let cancelled: () -> Bool
    private let timeout: TimeInterval
    private let clockLock = NSLock()
    private var operationStarted = Date()
    private var active = true
    private var launched = false
    private var watchdog: DispatchSourceTimer?
    public private(set) var failed = false

    public static var workerURL: URL {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("BirdLockInterpolation")
    }
    public init?(width: Int, height: Int, context: CIContext, cancelled: @escaping () -> Bool,
                 executable: URL? = nil, timeout: TimeInterval = 60) {
        guard width >= 16, height >= 16, width <= 8192, height <= 4320 else {
            Diagnostics.record("optical flow unsupported dimensions \(width)x\(height); frame blend fallback")
            return nil
        }
        self.width = width; self.height = height; self.count = width*height*4
        self.context = context; self.cancelled = cancelled
        self.timeout = max(0.1, timeout)
        process.executableURL = executable ?? Self.workerURL
        process.arguments = [String(width), String(height)]
        process.standardInput = input; process.standardOutput = output
        // The child redirects native stderr to its own log at startup.
        process.standardError = FileHandle.standardError
        var environment = ProcessInfo.processInfo.environment
        environment["BIRDLOCK_LOG_DIR"] = Diagnostics.directory.path
        process.environment = environment
        signal(SIGPIPE, SIG_IGN)
        do { try process.run(); launched = true } catch {
            Diagnostics.record("optical flow worker launch failed: \(error)"); return nil
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "birdlock.flow.watchdog"))
        watchdog = timer
        timer.schedule(deadline: .now()+0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.clockLock.lock()
            let expired = self.active && Date().timeIntervalSince(self.operationStarted) > self.timeout
            self.clockLock.unlock()
            if self.cancelled() || expired {
                if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
            }
        }
        timer.resume()
        do {
            guard let ready = try FlowWorkerIO.read(output.fileHandleForReading, count: 8), ready == Data("BLFLOW1\n".utf8) else {
                stop(); Diagnostics.record("optical flow worker unavailable; frame blend fallback"); return nil
            }
        } catch { stop(); return nil }
        clockLock.lock(); active = false; clockLock.unlock()
        Diagnostics.record("optical flow worker ready dimensions=\(width)x\(height)")
    }
    deinit { stop() }
    public func stop() {
        watchdog?.cancel(); watchdog = nil
        try? input.fileHandleForWriting.close()
        if launched {
            let deadline = Date().addingTimeInterval(0.3)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? output.fileHandleForReading.close()
    }
    public func interpolate(_ a: CIImage, _ b: CIImage, phase: Double) -> CIImage? {
        guard !failed, !cancelled(), phase.isFinite, phase > 0, phase < 1 else { return nil }
        clockLock.lock(); operationStarted = Date(); active = true; clockLock.unlock()
        defer { clockLock.lock(); active = false; clockLock.unlock() }
        do {
            var phase = phase
            try withUnsafeBytes(of: &phase) { try input.fileHandleForWriting.write(contentsOf: Data($0)) }
            let bounds = CGRect(x: 0,y: 0,width: width,height: height)
            for image in [a,b] {
                var pixels = Data(count: count)
                pixels.withUnsafeMutableBytes { bytes in
                    context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width*4, bounds: bounds,
                                   format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                }
                try input.fileHandleForWriting.write(contentsOf: pixels)
            }
            guard let status = try FlowWorkerIO.read(output.fileHandleForReading, count: 1), status.first == 1,
                  let pixels = try FlowWorkerIO.read(output.fileHandleForReading, count: count) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return CIImage(bitmapData: pixels, bytesPerRow: width*4, size: CGSize(width: width,height: height),
                           format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        } catch {
            failed = true
            stop()
            Diagnostics.record("optical flow worker failed status=\(process.terminationStatus); frame blend fallback: \(error)")
            return nil
        }
    }
}
