import CoreImage
import Foundation
import ImageIO

public enum RawMode: String, Codable, Sendable, CaseIterable {
    case camera, raw
}

public enum RawPairPolicy: String, Sendable, CaseIterable {
    case jpeg, raw, both
}

public struct RawFrame: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case embedded, decoded }
    public var mode: RawMode
    public var source: Source
    public var fullWidth: Int
    public var fullHeight: Int
}

enum RawPhoto {
    static let extensions: Set<String> = ["arw", "nef", "nrw", "cr2", "cr3", "raf", "dng", "rw2", "orf", "pef", "srw"]
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let color = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let slots = DispatchSemaphore(value: 2)

    static func inspect(_ url: URL, source: CGImageSource, mode: RawMode, orientation: CGImagePropertyOrientation)
        -> (raw: RawFrame, width: Int, height: Int)? {
        slots.wait()
        defer { slots.signal() }
        let filter = CIRAWFilter(imageURL: url)
        filter?.orientation = orientation
        let native = filter?.nativeSize ?? .zero
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var fullWidth = native.width > 0 ? Int(native.width) : (props?[kCGImagePropertyPixelWidth] as? Int ?? 0)
        var fullHeight = native.height > 0 ? Int(native.height) : (props?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        if orientation.rawValue >= 5 { swap(&fullWidth, &fullHeight) }

        func preview() -> (RawFrame, Int, Int)? {
            guard let image = embedded(source, orientation: orientation, maxPixel: nil) else { return nil }
            return (RawFrame(mode: mode, source: .embedded, fullWidth: fullWidth, fullHeight: fullHeight),
                    Int(image.extent.width), Int(image.extent.height))
        }
        func decoded() -> (RawFrame, Int, Int)? {
            guard let filter, let image = filter.outputImage,
                  !image.extent.isInfinite, !image.extent.isEmpty,
                  render(image, size: previewSize(image.extent.size, maxPixel: 256)) != nil else { return nil }
            let width = Int(image.extent.width), height = Int(image.extent.height)
            return (RawFrame(mode: mode, source: .decoded, fullWidth: width, fullHeight: height), width, height)
        }
        return mode == .camera ? preview() ?? decoded() : decoded() ?? preview()
    }

    static func load(_ frame: SourceFrame, maxPixel: Int?) -> CGImage? {
        guard let raw = frame.raw else { return nil }
        slots.wait()
        defer { slots.signal() }
        let orientation = CGImagePropertyOrientation(rawValue: UInt32(frame.orientation ?? 1)) ?? .up
        let target = previewSize(CGSize(width: frame.pixelWidth, height: frame.pixelHeight), maxPixel: maxPixel)
        let image: CIImage
        switch raw.source {
        case .embedded:
            guard let source = CGImageSourceCreateWithURL(frame.url as CFURL, nil),
                  let preview = embedded(source, orientation: orientation, maxPixel: maxPixel) else { return nil }
            image = preview
        case .decoded:
            guard let filter = CIRAWFilter(imageURL: frame.url) else { return nil }
            filter.orientation = orientation
            let longest = max(filter.nativeSize.width, filter.nativeSize.height)
            if longest > 0 { filter.scaleFactor = Float(min(1, max(target.width, target.height) / longest)) }
            guard let output = filter.outputImage else { return nil }
            image = output
        }
        // Project coordinates are based on the saved pixel grid. Small decoder crop/rounding
        // differences are resampled to that grid. A different aspect implies a different image.
        let size = image.extent.size
        guard size.width > 0, size.height > 0,
              abs((size.width / size.height) / (target.width / target.height) - 1) < 0.02 else { return nil }
        return render(image, size: target)
    }

    private static func embedded(_ source: CGImageSource, orientation: CGImagePropertyOrientation, maxPixel: Int?) -> CIImage? {
        // Without either CreateThumbnailFromImage option, ImageIO uses its embedded preview.
        var options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        if let maxPixel { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel }
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return CIImage(cgImage: cg, options: [.colorSpace: cg.colorSpace ?? color]).oriented(orientation)
    }

    private static func previewSize(_ size: CGSize, maxPixel: Int?) -> CGSize {
        guard let maxPixel else { return size }
        let scale = min(1, CGFloat(maxPixel) / max(size.width, size.height))
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    private static func render(_ image: CIImage, size: CGSize) -> CGImage? {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / extent.width, y: size.height / extent.height))
        return context.createCGImage(scaled, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: color)
    }
}

extension SourceFrame {
    public var hasRawPreviewLimit: Bool {
        guard let raw, raw.source == .embedded else { return false }
        return raw.fullWidth == 0 || raw.fullHeight == 0 ||
            Double(pixelWidth) < Double(raw.fullWidth) * 0.95 || Double(pixelHeight) < Double(raw.fullHeight) * 0.95
    }

    var rawCacheIdentity: String {
        guard let raw else { return "" }
        return "|apple-raw-v1:\(ProcessInfo.processInfo.operatingSystemVersionString):\(raw.mode.rawValue):\(raw.source.rawValue):\(orientation ?? 1):\(pixelWidth)x\(pixelHeight)"
    }
}
