import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

public enum ImageLoader {
    /// Decode an image with EXIF orientation applied. If maxPixel is given, ImageIO decodes at reduced
    /// size (fast DCT-domain downscale for JPEG).
    public static func load(_ url: URL, maxPixel: Int? = nil) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixel { opts[kCGImageSourceThumbnailMaxPixelSize] = maxPixel }
        else {
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1
            if orientation == 1 {
                // Fast path: plain full decode
                return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }
            opts[kCGImageSourceThumbnailMaxPixelSize] = max(w, h)
        }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.88) -> Bool {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dst, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dst)
    }

    public static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dst, image, nil)
        return CGImageDestinationFinalize(dst)
    }
}

/// A grayscale float image patch, row-major, origin top-left.
public struct GrayPatch {
    public var width: Int
    public var height: Int
    public var data: [Float]

    public init(width: Int, height: Int, data: [Float]) {
        self.width = width; self.height = height; self.data = data
    }

    /// Extract the region `rect` (source pixel coords, top-left origin, may exceed the image) from `image`,
    /// resampled to `outW x outH`. Areas outside the image are filled with edge-mean gray.
    public static func extract(from image: CGImage, rect: CGRect, outW: Int, outH: Int) -> GrayPatch? {
        let cs = CGColorSpaceCreateDeviceGray()
        var buf = [UInt8](repeating: 0, count: outW * outH)
        let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: outW, height: outH, bitsPerComponent: 8,
                                      bytesPerRow: outW, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.setFillColor(gray: 0.5, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
            // CG context origin is bottom-left. Map source rect -> [0,outW]x[0,outH] with y flipped.
            let sx = CGFloat(outW) / rect.width, sy = CGFloat(outH) / rect.height
            let imgH = CGFloat(image.height)
            // Source image drawn at (0,0,W,H) in CG coords (bottom-left). Source top-left y = imgH - y_cg.
            // We want source point (x, y_top) -> patch (u, v_top) = ((x - rect.minX)*sx, (y_top - rect.minY)*sy)
            // In CG coords: u = (x - minX)*sx ; v_cg = outH - v_top = outH - (imgH - y_cg - minY)*sy
            ctx.translateBy(x: -rect.minX * sx, y: CGFloat(outH) - (imgH - rect.minY) * sy)
            ctx.scaleBy(x: sx, y: sy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: imgH))
            return true
        }
        guard ok else { return nil }
        return GrayPatch(width: outW, height: outH, data: buf.map { Float($0) / 255 })
    }

    /// Exact (resampling-free) extraction: copies the integer-aligned square (x0, y0, N·D, N·D) of `image`
    /// 1:1 and box-averages D×D blocks. Patch pixel u covers image x ∈ [x0 + u·D, x0 + (u+1)·D).
    /// Out-of-image areas are filled with the mean of the valid region.
    public static func extractExact(from image: CGImage, x0: Int, y0: Int, n: Int, factor d: Int) -> GrayPatch? {
        let side = n * d
        let cs = CGColorSpaceCreateDeviceGray()
        var buf = [UInt8](repeating: 0, count: side * side)
        var valid = [Bool](repeating: true, count: side * side)
        let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            // Source pixel (x, y_top) -> buffer (x - x0, y_top - y0). CG y-up: device_y = side - (y_top - y0)
            let H = image.height
            ctx.draw(image, in: CGRect(x: -x0, y: side - (H - y0), width: image.width, height: H))
            return true
        }
        guard ok else { return nil }
        // validity mask for out-of-bounds
        let W = image.width, H = image.height
        var sum = 0.0, cnt = 0.0
        for yy in 0..<side {
            let sy = y0 + yy
            for xx in 0..<side {
                let sx = x0 + xx
                let inside = sx >= 0 && sx < W && sy >= 0 && sy < H
                valid[yy * side + xx] = inside
                if inside { sum += Double(buf[yy * side + xx]); cnt += 1 }
            }
        }
        let fill = cnt > 0 ? Float(sum / cnt / 255) : 0.5
        var out = [Float](repeating: 0, count: n * n)
        let inv = 1 / Float(d * d) / 255
        for v in 0..<n {
            for u in 0..<n {
                var s: Float = 0
                var bad = 0
                for yy in (v * d)..<((v + 1) * d) {
                    let row = yy * side
                    for xx in (u * d)..<((u + 1) * d) {
                        if valid[row + xx] { s += Float(buf[row + xx]) } else { bad += 1 }
                    }
                }
                out[v * n + u] = bad == 0 ? s * inv : (s * inv + Float(bad) * fill / Float(d * d))
            }
        }
        return GrayPatch(width: n, height: n, data: out)
    }

    public func toCGImage() -> CGImage? {
        let bytes = data.map { UInt8(clamp($0, 0, 1) * 255) }
        let cs = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
