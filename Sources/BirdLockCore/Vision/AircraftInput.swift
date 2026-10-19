import Foundation
import CoreGraphics
import CryptoKit

public enum AircraftModelError: Error, LocalizedError {
    case invalidManifest, missingWeights, corruptWeights, imageDecode, proxyTooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidManifest: return "飞机模型说明格式无效。"
        case .missingWeights: return "飞机部位模型尚未安装，请使用包含该模型的完整测试包。"
        case .corruptWeights: return "飞机部位模型校验失败，未运行或替换该文件。"
        case .imageDecode: return "无法读取飞机代理照片的像素。"
        case .proxyTooLarge: return "分析照片尺寸超出范围，请重新生成预览后重试。"
        }
    }
}

/// Fixed local model metadata. Reading/verification never downloads or overwrites resources.
public struct AircraftModelManifest: Decodable, Sendable {
    public let id: String, file: String, sha256: String
    public let bytes: Int
    public let tokenIDs: [Int64]
    public let noseTokenIndex: Int
    public let inputSize: Int
    public let imageMean: [Float], imageStd: [Float]
    public var analysisIdentity: String { "\(id):\(sha256):aircraft-sequence-v2" }
    enum CodingKeys: String, CodingKey {
        case id, file, sha256, bytes
        case tokenIDs = "token_ids", noseTokenIndex = "nose_token_index", inputSize = "input_size"
        case imageMean = "image_mean", imageStd = "image_std"
    }

    public static func load(directory: URL, verifyWeights: Bool = true) throws -> AircraftModelManifest {
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard !manifest.file.isEmpty, !manifest.file.contains(".."), !manifest.file.contains("\\"),
              URL(fileURLWithPath: manifest.file).lastPathComponent == manifest.file,
              !manifest.file.contains("/"), manifest.bytes > 0,
              manifest.sha256.count == 64, manifest.sha256.allSatisfy({ $0.isHexDigit }),
              manifest.inputSize == 800, manifest.tokenIDs == [101, 1996, 4451, 1997, 2019, 13297, 1012, 102],
              manifest.noseTokenIndex == 2,
              manifest.imageMean.count == 3, manifest.imageStd.count == 3,
              manifest.imageMean.allSatisfy(\.isFinite), manifest.imageStd.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw AircraftModelError.invalidManifest
        }
        if verifyWeights {
            let url = directory.appendingPathComponent(manifest.file)
            guard FileManager.default.fileExists(atPath: url.path) else { throw AircraftModelError.missingWeights }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size == manifest.bytes else { throw AircraftModelError.corruptWeights }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1024*1024), !data.isEmpty { hash.update(data: data) }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == manifest.sha256.lowercased() else { throw AircraftModelError.corruptWeights }
        }
        return manifest
    }
}

/// Geometry shared by native preprocessing and candidate projection (top-left pixel coordinates).
public struct AircraftInputGeometry: Sendable {
    public let body: BoxD
    public let imageWidth: Int, imageHeight: Int, rotation: Int
    public let x0: Int, y0: Int, cropWidth: Int, cropHeight: Int, side: Int, offX: Int, offY: Int
    private let a: Double, b: Double, d: Double, e: Double, tx: Double, ty: Double

    public init?(imageWidth: Int, imageHeight: Int, body: BoxD, rotation: Int) {
        guard imageWidth > 0, imageHeight > 0, [0, 90, 180, 270].contains(rotation),
              [body.x, body.y, body.w, body.h].allSatisfy(\.isFinite), body.w > 0, body.h > 0 else { return nil }
        let pad = max(body.w, body.h) * 0.22
        let left = max(0, body.x-pad), top = max(0, body.y-pad)
        let right = min(Double(imageWidth), body.x+body.w+pad), bottom = min(Double(imageHeight), body.y+body.h+pad)
        guard right > left, bottom > top else { return nil }
        let x0 = Int(left), y0 = Int(top), x1 = Int(right), y1 = Int(bottom)
        guard x1 > x0, y1 > y0 else { return nil }
        self.body = body; self.imageWidth = imageWidth; self.imageHeight = imageHeight; self.rotation = rotation
        self.x0 = x0; self.y0 = y0; cropWidth = x1-x0; cropHeight = y1-y0
        side = max(cropWidth, cropHeight); offX = (side-cropWidth)/2; offY = (side-cropHeight)/2
        let radians = Double(rotation) * .pi / 180, c = cos(radians)*0.85, s = sin(radians)*0.85
        let centre = Double(side)/2, forwardTX = (1-c)*centre-s*centre, forwardTY = s*centre+(1-c)*centre
        let determinant = c*c+s*s
        a = c/determinant; b = -s/determinant; d = s/determinant; e = c/determinant
        tx = -(a*forwardTX+b*forwardTY); ty = -(d*forwardTX+e*forwardTY)
    }

    public func candidate(box: [Float], score: Double) -> AircraftPartCandidate? {
        guard box.count == 4, box.allSatisfy(\.isFinite), score.isFinite, score >= 0.25 else { return nil }
        let cx = Double(box[0])*Double(side), cy = Double(box[1])*Double(side)
        var w = Double(box[2])*Double(side)/0.85, h = Double(box[3])*Double(side)/0.85
        let span = max(body.w, body.h), pad = span*0.22
        guard w > 0, h > 0, w*h <= body.w*body.h*0.3, max(w,h) <= span*0.6 else { return nil }
        let x = a*cx+b*cy+tx-Double(offX)+Double(x0), y = d*cx+e*cy+ty-Double(offY)+Double(y0)
        guard x >= 0, x < Double(imageWidth), y >= 0, y < Double(imageHeight),
              x >= body.x-pad, x <= body.x+body.w+pad, y >= body.y-pad, y <= body.y+body.h+pad else { return nil }
        if rotation == 90 || rotation == 270 { swap(&w, &h) }
        return AircraftPartCandidate(rotation: rotation, score: score, x: x, y: y, w: w, h: h)
    }

    fileprivate func warpRGB(_ rgba: [UInt8]) -> [UInt8] {
        // Bilinear affine sampling, then a separate bilinear resize, with constant ROI padding.
        // Keep floating coordinates here: quantizing the affine grid introduced visible edge
        // differences against the validated Mac research backend (up to 3 color levels).
        var warped = [UInt8](repeating: 127, count: side*side*3)
        func pixel(_ x: Int, _ y: Int, _ channel: Int) -> Double {
            let sx = x-offX, sy = y-offY
            guard sx >= 0, sy >= 0, sx < cropWidth, sy < cropHeight else { return 127 }
            return Double(rgba[((sy+y0)*imageWidth+sx+x0)*4+channel])
        }
        for y in 0..<side {
            for x in 0..<side {
                let xx = a*Double(x)+b*Double(y)+tx, yy = d*Double(x)+e*Double(y)+ty
                let sx = Int(floor(xx)), sy = Int(floor(yy)), fx = xx-Double(sx), fy = yy-Double(sy)
                let index = (y*side+x)*3
                for c in 0..<3 {
                    let top = pixel(sx,sy,c)*(1-fx)+pixel(sx+1,sy,c)*fx
                    let bottom = pixel(sx,sy+1,c)*(1-fx)+pixel(sx+1,sy+1,c)*fx
                    warped[index+c] = UInt8(clamping: Int((top*(1-fy)+bottom*fy).rounded(.toNearestOrEven)))
                }
            }
        }
        return warped
    }

    fileprivate func resizeNormalize(_ warped: [UInt8], manifest: AircraftModelManifest) -> [Float] {
        let size = manifest.inputSize, plane = size*size
        var output = [Float](repeating: 0, count: plane*3)
        func axis(_ v: Int) -> (Int, Int, Int, Int) {
            let p = (Double(v)+0.5)*Double(side)/Double(size)-0.5
            let low = Int(floor(p))
            if low < 0 { return (0,0,2048,0) }
            if low >= side-1 { return (side-1,side-1,2048,0) }
            let f = p-Double(low)
            return (low,low+1,Int(((1-f)*2048).rounded(.toNearestOrEven)),Int((f*2048).rounded(.toNearestOrEven)))
        }
        let axes = (0..<size).map(axis)
        for y in 0..<size {
            let (y0,y1,by0,by1) = axes[y]
            for x in 0..<size {
                let (x0,x1,bx0,bx1) = axes[x]
                for c in 0..<3 {
                    let top = Int(warped[(y0*side+x0)*3+c])*bx0+Int(warped[(y0*side+x1)*3+c])*bx1
                    let bottom = Int(warped[(y1*side+x0)*3+c])*bx0+Int(warped[(y1*side+x1)*3+c])*bx1
                    let value = UInt8(clamping: (top*by0+bottom*by1+(1 << 21)) >> 22)
                    output[c*plane+y*size+x] = (Float(value)/255-manifest.imageMean[c])/manifest.imageStd[c]
                }
            }
        }
        return output
    }
}

/// Decodes one proxy for all four rotations; buffers are released with this analysis step.
public struct AircraftImagePixels {
    public let width: Int, height: Int
    private let rgba: [UInt8]
    public init(image: CGImage) throws {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width*height*4)
        let success = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { throw AircraftModelError.imageDecode }
        self.width = width; self.height = height
        rgba = pixels
    }
    public func prepare(body: BoxD, rotation: Int, manifest: AircraftModelManifest) -> (pixels: [Float], geometry: AircraftInputGeometry)? {
        guard let geometry = AircraftInputGeometry(imageWidth: width, imageHeight: height, body: body, rotation: rotation) else { return nil }
        let warped = geometry.warpRGB(rgba)
        return (geometry.resizeNormalize(warped, manifest: manifest), geometry)
    }
}
