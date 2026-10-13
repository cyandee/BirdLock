import Foundation
import CoreGraphics

/// Draws a camera-style AF frame (thin coloured square or corner brackets with a faint dark outline).
public enum FocusMark {
    /// - Parameters:
    ///   - side: frame side in pixels
    ///   - line: stroke width in pixels
    public static func image(side: Int, line: Double, style: FocusMarkStyle, color: FocusMarkColor) -> CGImage? {
        let pad = Int(ceil(line * 2 + 2))
        let W = side + 2 * pad
        guard side > 2, let ctx = CGContext(data: nil, width: W, height: W, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGRect(x: Double(pad), y: Double(pad), width: Double(side), height: Double(side))
        let path = CGMutablePath()
        switch style {
        case .box:
            path.addRect(r)
        case .brackets:
            let L = Double(side) * 0.28
            for (cx, cy, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1, 1), (r.minX, r.maxY, 1, -1), (r.maxX, r.maxY, -1, -1)] {
                path.move(to: CGPoint(x: cx, y: cy + dy * L))
                path.addLine(to: CGPoint(x: cx, y: cy))
                path.addLine(to: CGPoint(x: cx + dx * L, y: cy))
            }
        }
        ctx.setLineJoin(.miter)
        ctx.setLineCap(.square)
        // faint dark outline keeps the frame visible on bright backgrounds
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
        ctx.setLineWidth(line + 1.5)
        ctx.strokePath()
        let (cr, cg, cb) = color.rgb
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(red: cr, green: cg, blue: cb, alpha: 1))
        ctx.setLineWidth(line)
        ctx.strokePath()
        return ctx.makeImage()
    }
}
