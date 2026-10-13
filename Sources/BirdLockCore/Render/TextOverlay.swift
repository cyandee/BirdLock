import Foundation
import CoreGraphics
import CoreText

public enum TextOverlay {
    /// Render lines of text (white with soft shadow) into a transparent CGImage.
    public static func render(lines: [String], fontSize: Double, bold: Bool = false) -> CGImage? {
        let lines = lines.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let fontName = bold ? "PingFangSC-Semibold" : "PingFangSC-Regular"
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
        ]
        let ctLines = lines.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attrs)) }
        var widths: [Double] = []
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        for l in ctLines {
            let w = CTLineGetTypographicBounds(l, &ascent, &descent, &leading)
            widths.append(w)
        }
        let lineH = Double(ascent + descent) * 1.25
        let pad = fontSize * 0.5
        let W = Int((widths.max() ?? 0) + pad * 2), H = Int(lineH * Double(lines.count) + pad * 2)
        guard W > 0, H > 0,
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.06), blur: fontSize * 0.25,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
        for (i, l) in ctLines.enumerated() {
            let y = Double(H) - pad - Double(ascent) - Double(i) * lineH
            ctx.textPosition = CGPoint(x: pad, y: y)
            CTLineDraw(l, ctx)
        }
        return ctx.makeImage()
    }

    public static func place(_ img: CGImage, corner: OverlayCorner, outW: Int, outH: Int, margin: Double) -> CGPoint {
        let w = Double(img.width), h = Double(img.height)
        switch corner {
        case .topLeft: return CGPoint(x: margin, y: margin)
        case .topRight: return CGPoint(x: Double(outW) - w - margin, y: margin)
        case .bottomLeft: return CGPoint(x: margin, y: Double(outH) - h - margin)
        case .bottomRight: return CGPoint(x: Double(outW) - w - margin, y: Double(outH) - h - margin)
        }
    }

    public static func lines(for exif: ExifInfo, settings: OverlaySettings) -> [String] {
        var out: [String] = []
        if !settings.customText.isEmpty { out.append(settings.customText) }
        if settings.showExif {
            var gear: [String] = []
            if let c = exif.cameraName { gear.append(c) }
            if let l = exif.lens { gear.append(l) }
            if !gear.isEmpty { out.append(gear.joined(separator: " · ")) }
            let e = exif.exposureLine
            if !e.isEmpty { out.append(e) }
        }
        return out
    }
}
