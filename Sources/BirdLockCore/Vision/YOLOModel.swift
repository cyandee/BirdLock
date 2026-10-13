import Foundation
import CoreML
import CoreGraphics
import CoreVideo

public struct Keypoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var conf: Double
    public var p: V2 { V2(x, y) }
    public init(x: Double, y: Double, conf: Double) { self.x = x; self.y = y; self.conf = conf }
}

public struct Detection: Codable, Hashable, Sendable {
    /// Box in source pixel coordinates (top-left origin)
    public var x: Double, y: Double, w: Double, h: Double
    public var score: Double
    public var keypoints: [Keypoint]

    public var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    public var center: V2 { V2(x + w / 2, y + h / 2) }

    public func iou(_ o: Detection) -> Double {
        let a = rect, b = o.rect
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let ia = Double(i.width * i.height)
        return ia / (Double(a.width * a.height) + Double(b.width * b.height) - ia)
    }
}

public enum ModelError: Error, LocalizedError {
    case notFound(String)
    case badOutput(String)
    public var errorDescription: String? {
        switch self {
        case .notFound(let s): return "找不到模型：\(s)"
        case .badOutput(let s): return "模型输出格式不支持：\(s)"
        }
    }
}

/// Runs an Ultralytics YOLO (detect or pose) model exported to Core ML *without* NMS.
/// Raw output layout: [1, 4 + nc + nk*3, anchors] with boxes as cx,cy,w,h in input pixels.
public final class YOLOModel: @unchecked Sendable {
    public let model: MLModel
    public let inputName: String
    public let outputName: String
    public let inputSize: Int
    public let numClasses: Int
    public let numKeypoints: Int
    public let classNames: [String]
    private let lock = NSLock()

    public init(url: URL, keypointCount: Int? = nil) throws {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: cfg)
        let desc = model.modelDescription
        guard let (iname, ifeat) = desc.inputDescriptionsByName.first(where: { $0.value.type == .image }) else {
            throw ModelError.badOutput("no image input")
        }
        inputName = iname
        inputSize = Int(ifeat.imageConstraint?.pixelsWide ?? 640)
        guard let (oname, _) = desc.outputDescriptionsByName.first(where: { $0.value.type == .multiArray }) else {
            throw ModelError.badOutput("no multiarray output")
        }
        outputName = oname

        // Parse Ultralytics metadata
        let meta = desc.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        var names: [String] = []
        if let n = meta["names"] {
            // "{0: 'person', 1: 'bicycle', ...}"
            let re = try? NSRegularExpression(pattern: "(\\d+):\\s*'([^']*)'")
            let ns = n as NSString
            let matches = re?.matches(in: n, range: NSRange(location: 0, length: ns.length)) ?? []
            names = matches.map { ns.substring(with: $0.range(at: 2)) }
        }
        var nk = keypointCount ?? 0
        if keypointCount == nil, let ks = meta["kpt_shape"] {
            let nums = ks.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
            if let first = nums.first { nk = first }
        }
        numKeypoints = nk
        classNames = names
        numClasses = names.isEmpty ? 1 : names.count
    }

    public var birdClassIndex: Int {
        if let i = classNames.firstIndex(where: { $0.lowercased() == "bird" }) { return i }
        return numClasses == 80 ? 14 : 0
    }

    /// Letterbox `crop` (source coords, may exceed bounds) of `image` into the model input and run it.
    /// Returned detections are in source coordinates.
    public func detect(image: CGImage, crop: CGRect? = nil, classIndex: Int? = nil,
                       scoreThreshold: Double = 0.2, iouThreshold: Double = 0.5, maxResults: Int = 20) throws -> [Detection] {
        let region = crop ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let s = Double(inputSize)
        let r = s / Double(max(region.width, region.height))
        let padX = (s - Double(region.width) * r) / 2
        let padY = (s - Double(region.height) * r) / 2
        guard let pb = makeInput(image: image, region: region, scale: r, padX: padX, padY: padY) else {
            throw ModelError.badOutput("could not create input buffer")
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: pb)])
        let out: MLFeatureProvider
        lock.lock()
        do { out = try model.prediction(from: input) } catch { lock.unlock(); throw error }
        lock.unlock()
        guard let arr = out.featureValue(for: outputName)?.multiArrayValue else { throw ModelError.badOutput("missing output") }
        let cls = classIndex ?? birdClassIndex
        var dets = try parse(arr, classIndex: cls, scoreThreshold: scoreThreshold)
        // map back to source coords
        for i in dets.indices {
            func mx(_ v: Double) -> Double { (v - padX) / r + Double(region.minX) }
            func my(_ v: Double) -> Double { (v - padY) / r + Double(region.minY) }
            let x0 = mx(dets[i].x), y0 = my(dets[i].y)
            dets[i].x = x0; dets[i].y = y0
            dets[i].w /= r; dets[i].h /= r
            for k in dets[i].keypoints.indices {
                dets[i].keypoints[k].x = mx(dets[i].keypoints[k].x)
                dets[i].keypoints[k].y = my(dets[i].keypoints[k].y)
            }
        }
        return Self.nms(dets, iou: iouThreshold, max: maxResults)
    }

    private func makeInput(image: CGImage, region: CGRect, scale r: Double, padX: Double, padY: Double) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, inputSize, inputSize, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: inputSize, height: inputSize,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(red: 114 / 255, green: 114 / 255, blue: 114 / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: inputSize, height: inputSize))
        ctx.interpolationQuality = .high
        let S = CGFloat(inputSize)
        let imgH = CGFloat(image.height)
        // map source (x, y_top) -> input (padX + (x-minX)*r, padY + (y_top-minY)*r) [top-left], CG is bottom-left
        let rr = CGFloat(r)
        ctx.translateBy(x: CGFloat(padX) - region.minX * rr, y: S - CGFloat(padY) - (imgH - region.minY) * rr)
        ctx.scaleBy(x: rr, y: rr)
        // clip to the letterbox content area so pad stays gray
        ctx.clip(to: CGRect(x: region.minX, y: imgH - region.maxY, width: region.width, height: region.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: imgH))
        return pb
    }

    private func parse(_ a: MLMultiArray, classIndex: Int, scoreThreshold: Double) throws -> [Detection] {
        let shape = a.shape.map { $0.intValue }
        let strides = a.strides.map { $0.intValue }
        guard shape.count == 3 else { throw ModelError.badOutput("shape \(shape)") }
        let C = shape[1], N = shape[2]
        let expectC = 4 + numClasses + numKeypoints * 3
        // Ultralytics pose models have nc classes then nk*3 keypoint channels.
        let nc = C - 4 - numKeypoints * 3
        guard nc >= 1 else { throw ModelError.badOutput("channels \(C), expected \(expectC)") }
        let cidx = min(classIndex, nc - 1)
        let read: (Int, Int) -> Double
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.assumingMemoryBound(to: Float.self)
            read = { c, n in Double(p[c * strides[1] + n * strides[2]]) }
        case .float16:
            let p = a.dataPointer.assumingMemoryBound(to: UInt16.self)
            read = { c, n in Double(halfToFloat(p[c * strides[1] + n * strides[2]])) }
        case .double:
            let p = a.dataPointer.assumingMemoryBound(to: Double.self)
            read = { c, n in p[c * strides[1] + n * strides[2]] }
        default:
            throw ModelError.badOutput("dtype \(a.dataType.rawValue)")
        }
        var dets: [Detection] = []
        for n in 0..<N {
            let sc = read(4 + cidx, n)
            guard sc >= scoreThreshold else { continue }
            let cx = read(0, n), cy = read(1, n), w = read(2, n), h = read(3, n)
            var kps: [Keypoint] = []
            if numKeypoints > 0 {
                let base = 4 + nc
                for k in 0..<numKeypoints {
                    kps.append(Keypoint(x: read(base + 3 * k, n), y: read(base + 3 * k + 1, n), conf: read(base + 3 * k + 2, n)))
                }
            }
            dets.append(Detection(x: cx - w / 2, y: cy - h / 2, w: w, h: h, score: sc, keypoints: kps))
        }
        return dets
    }

    public static func nms(_ dets: [Detection], iou: Double, max: Int) -> [Detection] {
        let sorted = dets.sorted { $0.score > $1.score }
        var keep: [Detection] = []
        for d in sorted {
            if keep.contains(where: { $0.iou(d) > iou }) { continue }
            keep.append(d)
            if keep.count >= max { break }
        }
        return keep
    }
}

/// IEEE 754 half -> float (Float16 is not available on Intel Macs).
@inline(__always) func halfToFloat(_ h: UInt16) -> Float {
    let sign = UInt32(h & 0x8000) << 16
    let exp = UInt32(h >> 10) & 0x1F
    let mant = UInt32(h & 0x03FF)
    if exp == 0 {   // zero / subnormal: mant × 2^-24
        let v = Float(mant) * 0x1p-24
        return sign != 0 ? -v : v
    }
    if exp == 0x1F { return Float(bitPattern: sign | 0x7F80_0000 | (mant << 13)) }   // inf / NaN
    return Float(bitPattern: sign | ((exp + 112) << 23) | (mant << 13))
}
