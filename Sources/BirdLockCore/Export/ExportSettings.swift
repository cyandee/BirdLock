import Foundation
import AVFoundation
import CoreGraphics

public enum VideoCodec: String, Codable, CaseIterable, Sendable, Identifiable {
    case h264, hevc, proRes422HQ, proRes4444
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .h264: return "H.264（兼容性最好）"
        case .hevc: return "HEVC / H.265（体积小）"
        case .proRes422HQ: return "ProRes 422 HQ（后期剪辑）"
        case .proRes4444: return "ProRes 4444"
        }
    }
    public var avCodec: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        case .proRes422HQ: return .proRes422HQ
        case .proRes4444: return .proRes4444
        }
    }
    public var fileExtension: String { (self == .h264 || self == .hevc) ? "mp4" : "mov" }
    public var fileType: AVFileType { (self == .h264 || self == .hevc) ? .mp4 : .mov }
}

public enum VideoQuality: String, Codable, CaseIterable, Sendable, Identifiable {
    case standard, high, max
    public var id: String { rawValue }
    public var title: String { ["standard": "标准", "high": "高", "max": "极高"][rawValue]! }
    /// bits per pixel per frame (H.264); HEVC uses 60%
    public var bpp: Double { [VideoQuality.standard: 0.08, .high: 0.15, .max: 0.28][self]! }
}

public enum FrameInterpolation: String, Codable, CaseIterable, Sendable, Identifiable {
    case nearest, blend, ai
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .nearest: return "重复帧（清晰）"
        case .blend: return "帧混合（顺滑）"
        case .ai: return "AI 光流补帧（最顺滑，导出较慢）"
        }
    }
}

public enum LoopMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case forward, reverse, pingPong
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .forward: return "正放"
        case .reverse: return "倒放"
        case .pingPong: return "往返（正放+倒放）"
        }
    }
}

public enum OverlayCorner: String, Codable, CaseIterable, Sendable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    public var id: String { rawValue }
    public var title: String { ["topLeft": "左上", "topRight": "右上", "bottomLeft": "左下", "bottomRight": "右下"][rawValue]! }
}

public struct OverlaySettings: Codable, Hashable, Sendable {
    public var showExif = false
    public var exifPerFrame = false
    public var customText = ""
    public var corner: OverlayCorner = .bottomLeft
    public var textScale: Double = 1.0
    public var opacity: Double = 0.85
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OverlaySettings()
        showExif = c.value(.showExif, d.showExif)
        exifPerFrame = c.value(.exifPerFrame, d.exifPerFrame)
        customText = c.value(.customText, d.customText)
        corner = c.value(.corner, d.corner)
        textScale = c.value(.textScale, d.textScale)
        opacity = c.value(.opacity, d.opacity)
    }
}

/// Picture watermark (e.g. a signature PNG with transparency) placed freely on the output.
public struct WatermarkSettings: Codable, Hashable, Sendable {
    public var enabled = false
    /// PNG copied into the app's support folder
    public var imagePath: String? = nil
    /// Centre of the watermark, normalised to the output frame (0…1, top-left origin)
    public var centerX = 0.84
    public var centerY = 0.88
    /// Watermark width as a fraction of the output's short side
    public var size = 0.28
    public var opacity = 0.9
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WatermarkSettings()
        enabled = c.value(.enabled, d.enabled)
        imagePath = c.value(.imagePath, d.imagePath)
        centerX = c.value(.centerX, d.centerX)
        centerY = c.value(.centerY, d.centerY)
        size = c.value(.size, d.size)
        opacity = c.value(.opacity, d.opacity)
    }

    public var isActive: Bool { enabled && imagePath != nil }

    /// Watermark rectangle in output pixels (top-left origin) for an image of `imageSize`.
    public func rect(imageSize: CGSize, outW: Double, outH: Double) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let w = size * min(outW, outH)
        let h = w * Double(imageSize.height) / Double(imageSize.width)
        return CGRect(x: centerX * outW - w / 2, y: centerY * outH - h / 2, width: w, height: h)
    }
}

/// Background music muxed into exported videos.
public struct AudioSettings: Codable, Hashable, Sendable {
    public var url: URL? = nil
    /// Position in the music file (seconds) that lines up with the start of the video
    public var startOffset: Double = 0
    public var volume: Double = 1
    public var fadeIn: Double = 0.3
    public var fadeOut: Double = 1.0
    /// Repeat the music when it is shorter than the video
    public var loop = true
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AudioSettings()
        url = c.value(.url, d.url)
        startOffset = c.value(.startOffset, d.startOffset)
        volume = c.value(.volume, d.volume)
        fadeIn = c.value(.fadeIn, d.fadeIn)
        fadeOut = c.value(.fadeOut, d.fadeOut)
        loop = c.value(.loop, d.loop)
    }

    public var isActive: Bool { url != nil && volume > 0.001 }
}

public struct ExportSettings: Codable, Hashable, Sendable {
    public var aspect: AspectRatio = AspectRatio.presets[1]
    /// Short side of the output in pixels
    public var shortSide: Int = 1440
    public var outputFPS: Double = 30
    /// 1 = real time, 0.5 = half speed (slow motion)
    public var speed: Double = 1.0
    public var interpolation: FrameInterpolation = .nearest
    public var loop: LoopMode = .forward
    public var repeatCount: Int = 1
    public var codec: VideoCodec = .hevc
    public var quality: VideoQuality = .high
    public var fadeInSeconds: Double = 0
    public var fadeOutSeconds: Double = 0
    public var overlay = OverlaySettings()
    public var useFullResolution = true
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportSettings()
        aspect = c.value(.aspect, d.aspect)
        shortSide = c.value(.shortSide, d.shortSide)
        outputFPS = c.value(.outputFPS, d.outputFPS)
        speed = c.value(.speed, d.speed)
        interpolation = c.value(.interpolation, d.interpolation)
        loop = c.value(.loop, d.loop)
        repeatCount = c.value(.repeatCount, d.repeatCount)
        codec = c.value(.codec, d.codec)
        quality = c.value(.quality, d.quality)
        fadeInSeconds = c.value(.fadeInSeconds, d.fadeInSeconds)
        fadeOutSeconds = c.value(.fadeOutSeconds, d.fadeOutSeconds)
        overlay = c.value(.overlay, d.overlay)
        useFullResolution = c.value(.useFullResolution, d.useFullResolution)
    }

    public var outputSize: (w: Int, h: Int) {
        let r = aspect.value
        var w: Double, h: Double
        if r >= 1 { h = Double(shortSide); w = h * r } else { w = Double(shortSide); h = w / r }
        // even dimensions for codecs
        return (Int((w / 2).rounded()) * 2, Int((h / 2).rounded()) * 2)
    }

    public static let shortSidePresets: [Int] = [720, 1080, 1440, 2160, 2880, 4320]
    public static let fpsPresets: [Double] = [24, 25, 30, 48, 50, 60, 120]
    public static let speedPresets: [Double] = [0.1, 0.2, 0.25, 1.0 / 3, 0.5, 2.0 / 3, 1, 1.5, 2]
}

/// One output frame: show source frame `a`, optionally blended with `b` by `t`.
public struct OutputFrame: Sendable, Hashable {
    public var a: Int
    public var b: Int
    public var t: Double
    public var fade: Double   // 0...1 multiplier (fade in/out)
    public init(a: Int, b: Int, t: Double, fade: Double) { self.a = a; self.b = b; self.t = t; self.fade = fade }
}

public enum TimeMapper {
    /// - Parameters:
    ///   - used: frame indices (sorted) included in the clip
    ///   - sourceFPS: capture rate of the burst
    public static func outputFrames(used: [Int], sourceFPS: Double, settings s: ExportSettings) -> [OutputFrame] {
        guard !used.isEmpty else { return [] }
        var order: [Int]
        switch s.loop {
        case .forward: order = used
        case .reverse: order = used.reversed()
        case .pingPong: order = used + used.reversed().dropFirst()
        }
        if s.repeatCount > 1 {
            var o = order
            for _ in 1..<s.repeatCount { o += (s.loop == .pingPong ? Array(order.dropFirst()) : order) }
            order = o
        }
        let n = order.count
        if n == 1 { return [OutputFrame(a: order[0], b: order[0], t: 0, fade: 1)] }
        let step = s.speed * sourceFPS / s.outputFPS     // source frames advanced per output frame
        let count = Int(floor(Double(n - 1) / step)) + 1
        var out: [OutputFrame] = []
        out.reserveCapacity(count)
        let total = Double(count) / s.outputFPS
        for k in 0..<count {
            let pos = Double(k) * step
            let i0 = min(n - 1, Int(floor(pos)))
            let i1 = min(n - 1, i0 + 1)
            let fr = pos - Double(i0)
            let time = Double(k) / s.outputFPS
            var fade = 1.0
            if s.fadeInSeconds > 0 { fade = min(fade, time / s.fadeInSeconds) }
            if s.fadeOutSeconds > 0 { fade = min(fade, (total - time) / s.fadeOutSeconds) }
            fade = clamp(fade, 0, 1)
            switch s.interpolation {
            case .nearest:
                let idx = fr < 0.5 ? i0 : i1
                out.append(OutputFrame(a: order[idx], b: order[idx], t: 0, fade: fade))
            case .blend, .ai:
                out.append(OutputFrame(a: order[i0], b: order[i1], t: fr < 1e-6 ? 0 : fr, fade: fade))
            }
        }
        return out
    }
}
