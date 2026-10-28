import Foundation
import CoreImage
import CoreVideo
import CoreMedia
import VideoToolbox

/// Machine-learning frame interpolation using Apple's VideoToolbox frame processor
/// (VTFrameRateConversion, macOS 15.4+, runs on the Neural Engine / GPU).
@available(macOS 15.4, *)
public final class AIInterpolator {
    private let processor = VTFrameProcessor()
    private let width: Int
    private let height: Int
    private var srcPool: CVPixelBufferPool?
    private var dstPool: CVPixelBufferPool?
    private let context: CIContext
    private var sequence: Int64 = 0

    public init?(width: Int, height: Int, context: CIContext) {
        self.width = width
        self.height = height
        self.context = context
        guard let cfg = VTFrameRateConversionConfiguration(frameWidth: width, frameHeight: height, usePrecomputedFlow: false,
                                                           qualityPrioritization: .quality, revision: .revision1) else { return nil }
        do { try processor.startSession(configuration: cfg) } catch { return nil }
        var sp: CVPixelBufferPool?, dp: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, cfg.sourcePixelBufferAttributes as CFDictionary, &sp)
        CVPixelBufferPoolCreate(nil, nil, cfg.destinationPixelBufferAttributes as CFDictionary, &dp)
        guard let sp, let dp else { return nil }
        srcPool = sp; dstPool = dp
    }

    deinit { processor.endSession() }

    static func tag709(_ p: CVPixelBuffer) {
        CVBufferSetAttachment(p, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(p, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(p, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    public static var isSupported: Bool {
        // Keep older Xcode SDKs usable (the property was renamed in Xcode 26).
        #if compiler(>=6.2)
        if #available(macOS 26, *) { return VTFrameRateConversionConfiguration.isSupported }
        return VTFrameRateConversionConfiguration.processorSupported
        #else
        return VTFrameRateConversionConfiguration.processorSupported
        #endif
    }

    private func buffer(_ pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    /// Returns the frame at `phase` (0…1) between `a` and `b` (both already composed at output size).
    public func interpolate(_ a: CIImage, _ b: CIImage, phase: Double) -> CIImage? {
        guard phase.isFinite, phase > 0, phase < 1 else { return nil }
        let base = sequence * 2000; sequence += 1
        guard let pa = buffer(srcPool), let pb = buffer(srcPool), let pd = buffer(dstPool) else { return nil }
        let r = CGRect(x: 0, y: 0, width: width, height: height)
        let cs = CGColorSpace(name: CGColorSpace.itur_709)!
        for p in [pa, pb, pd] { Self.tag709(p) }
        context.render(a, to: pa, bounds: r, colorSpace: cs)
        context.render(b, to: pb, bounds: r, colorSpace: cs)
        guard let fa = VTFrameProcessorFrame(buffer: pa, presentationTimeStamp: CMTime(value: base, timescale: 1000)),
              let fb = VTFrameProcessorFrame(buffer: pb, presentationTimeStamp: CMTime(value: base+1000, timescale: 1000)),
              let fd = VTFrameProcessorFrame(buffer: pd, presentationTimeStamp: CMTime(value: base+CMTimeValue(phase * 1000), timescale: 1000)),
              let params = VTFrameRateConversionParameters(sourceFrame: fa, nextFrame: fb, opticalFlow: nil,
                                                           interpolationPhase: [Float(phase)], submissionMode: .random,
                                                           destinationFrames: [fd]) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let proc = processor
        Task.detached {
            do { try await proc.process(parameters: params); ok = true } catch { ok = false }
            sem.signal()
        }
        sem.wait()
        guard ok else { return nil }
        // Read back in the same explicit space used to render the source buffers.
        // Inferring it from the 709 attachments applies a different transfer curve
        // and lifts interpolated frames relative to the original frames.
        return CIImage(cvPixelBuffer: pd, options: [.colorSpace: cs])
    }
}
