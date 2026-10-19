import Foundation
import CoreGraphics

/// Draws a camera-style AF frame (thin coloured square or corner brackets with a faint dark outline).
public enum FocusMark {
    public struct ClippedLayout {
        /// Top-left output coordinates occupied by visible strokes, rounded to whole pixels.
        public let bounds: CGRect
        let rect: CGRect
        public var cacheKey: String {
            [bounds.width, bounds.height, rect.minX, rect.minY, rect.width, rect.height]
                .map { String(Double($0).bitPattern) }.joined(separator: ",")
        }
    }

    /// Bound allocations by the visible stroke segments, not the potentially enormous offscreen bird box.
    public static func clippedLayout(rect r: CGRect, viewport: CGRect, line: Double, style: FocusMarkStyle) -> ClippedLayout? {
        guard r.width > 2, r.height > 2, viewport.width > 0, viewport.height > 0, line > 0,
              [r.minX,r.minY,r.width,r.height,viewport.minX,viewport.minY,viewport.width,viewport.height,line].allSatisfy({ $0.isFinite }) else { return nil }
        var segments: [(CGPoint,CGPoint)] = []
        switch style {
        case .box:
            let points = [CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY),CGPoint(x:r.minX,y:r.minY)]
            segments = Array(zip(points,points.dropFirst()))
        case .brackets:
            let length = min(r.width,r.height) * 0.28
            for (x,y,dx,dy) in [(r.minX,r.minY,1.0,1.0),(r.maxX,r.minY,-1,1),(r.minX,r.maxY,1,-1),(r.maxX,r.maxY,-1,-1)] {
                let corner = CGPoint(x:x,y:y)
                segments.append((CGPoint(x:x,y:y+dy*length),corner))
                segments.append((corner,CGPoint(x:x+dx*length,y:y)))
            }
        }
        let pad = ceil(line * 2 + 2)
        var visible = CGRect.null
        for (a,b) in segments {
            let stroke = CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y)).insetBy(dx:-pad,dy:-pad)
            let clipped = stroke.intersection(viewport)
            if !clipped.isNull && !clipped.isEmpty { visible = visible.union(clipped) }
        }
        guard !visible.isNull else { return nil }
        let bounds = visible.integral.intersection(viewport)
        let local = CGRect(x:r.minX-bounds.minX,y:bounds.height-(r.maxY-bounds.minY),width:r.width,height:r.height)
        return ClippedLayout(bounds:bounds,rect:local)
    }

    public static func image(layout: ClippedLayout, line: Double, style: FocusMarkStyle, color: FocusMarkColor) -> CGImage? {
        let width = Int(layout.bounds.width), height = Int(layout.bounds.height)
        guard width > 0, height > 0, let ctx = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return draw(rect:layout.rect,in:ctx,line:line,style:style,color:color)
    }

    /// - Parameters:
    ///   - side: frame side in pixels
    ///   - line: stroke width in pixels
    public static func image(side: Int, line: Double, style: FocusMarkStyle, color: FocusMarkColor) -> CGImage? {
        image(width: side, height: side, line: line, style: style, color: color)
    }

    public static func image(width: Int, height: Int, line: Double, style: FocusMarkStyle, color: FocusMarkColor) -> CGImage? {
        let pad = Int(ceil(line * 2 + 2))
        let W = width + 2 * pad, H = height + 2 * pad
        guard width > 2, height > 2, let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGRect(x: Double(pad), y: Double(pad), width: Double(width), height: Double(height))
        return draw(rect:r,in:ctx,line:line,style:style,color:color)
    }

    private static func draw(rect r: CGRect, in ctx: CGContext, line: Double, style: FocusMarkStyle, color: FocusMarkColor) -> CGImage? {
        let path = CGMutablePath()
        switch style {
        case .box:
            path.addRect(r)
        case .brackets:
            let L = Double(min(r.width, r.height)) * 0.28
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
