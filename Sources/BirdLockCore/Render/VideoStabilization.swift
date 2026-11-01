import Foundation
import CoreGraphics
import Vision

public struct VideoStabilizationSettings: Codable, Hashable, Sendable {
    public var enabled = true
    public var method = "auto"
    public var framing = "subject"
    public var strength = 1.0
    public var smoothness = 0.5
    public var maxZoom = 1.4
    public var fixedZoom = true
    public var autoZoom = true
    public var autoSync = true
    public var gyroOffset = 0.0
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = Self()
        enabled = c.value(.enabled, d.enabled); method = c.value(.method, d.method)
        framing = c.value(.framing, d.framing); strength = c.value(.strength, d.strength)
        smoothness = c.value(.smoothness, d.smoothness); maxZoom = c.value(.maxZoom, d.maxZoom)
        fixedZoom = c.value(.fixedZoom, d.fixedZoom)
        autoZoom = c.value(.autoZoom, d.autoZoom); autoSync = c.value(.autoSync, d.autoSync)
        gyroOffset = c.value(.gyroOffset, d.gyroOffset)
    }
}

/// Cached observations use original, top-left source pixels and source-video seconds.
public struct VideoMotionRecord: Codable, Sendable {
    public var schema = 2
    public var width: Int
    public var height: Int
    public var fps: Double
    public var start: Double
    public var intrinsics: [Double] // fx, fy, cx, cy
    public var steps: [[Double]] // previous -> current: dx, dy, angle, logScale, confidence
    public var gyro: [[Double]] // seconds, gx, gy, gz (Gyroflow's normalized IMU frame)
    public var telemetryWarning = ""
    public var gyroSource: String? = nil
    public var intrinsicsSource: String? = nil
}

public struct VideoSyncResult: Codable, Sendable {
    public var offset = 0.0
    public var score = 0.0
    public var valid = false
    public var axes = [1, 0, 2]
    public var signs = [-1.0, -1.0, -1.0]
    public var confidence: Double { score }
}

public struct VideoStabilizationStatus: Sendable {
    public var method = "图像防抖"
    public var sync = VideoSyncResult()
    public var gyroSamples = 0
    public var measuredFrames = 0
    public var maxZoom = 1.0
    public var limited = false
}

/// Row-major projective matrix. External prewarps remain plain nine-element arrays.
struct Mat3: Sendable {
    var v: [Double]
    init(_ v: [Double]) { self.v = v.count == 9 ? v : Self.identity.v }
    static let identity = Mat3([1, 0, 0, 0, 1, 0, 0, 0, 1])
    static func similarity(_ dx: Double = 0, _ dy: Double = 0, _ angle: Double = 0, _ logScale: Double = 0) -> Mat3 {
        let c = cos(angle) * exp(logScale), s = sin(angle) * exp(logScale)
        return Mat3([c, -s, dx, s, c, dy, 0, 0, 1])
    }
    static func * (a: Mat3, b: Mat3) -> Mat3 {
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 { for c in 0..<3 { for k in 0..<3 { out[r * 3 + c] += a.v[r * 3 + k] * b.v[k * 3 + c] } } }
        return Mat3(out)
    }
    func apply(_ p: V2) -> V2 {
        let d = v[6] * p.x + v[7] * p.y + v[8]
        guard d.isFinite, abs(d) > 1e-12 else { return V2(.nan, .nan) }
        return V2((v[0] * p.x + v[1] * p.y + v[2]) / d, (v[3] * p.x + v[4] * p.y + v[5]) / d)
    }
    var inverse: Mat3? {
        let a = v[0], b = v[1], c = v[2], d = v[3], e = v[4], f = v[5], g = v[6], h = v[7], i = v[8]
        let co = [e*i-f*h, c*h-b*i, b*f-c*e, f*g-d*i, a*i-c*g, c*d-a*f, d*h-e*g, b*g-a*h, a*e-b*d]
        let det = a * co[0] + b * co[3] + c * co[6]
        guard det.isFinite, abs(det) > 1e-14 else { return nil }
        return Mat3(co.map { $0 / det })
    }
    var transpose: Mat3 { Mat3((0..<9).map { v[($0 % 3) * 3 + $0 / 3] }) }
    func attenuated(_ strength: Double) -> Mat3 {
        let s = strength.isFinite ? clamp(strength, 0, 1) : 1
        var out = (0..<9).map { Self.identity.v[$0] + (v[$0] - Self.identity.v[$0]) * s }
        if abs(out[8]) > 1e-12 { let den = out[8]; out = out.map { $0 / den } }
        return Mat3(out)
    }
    var finite: Bool { v.allSatisfy(\.isFinite) }
}

/// Global camera motion is measured once; changing framing only smooths the cached path.
public enum VideoStabilization {
    private static func cacheFile(_ frames: [SourceFrame]) -> URL? {
        guard let first = frames.first else { return nil }
        let folder = first.url.deletingLastPathComponent().standardizedFileURL
        guard frames.allSatisfy({ $0.url.deletingLastPathComponent().standardizedFileURL == folder }),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("video-source.json").path) else { return nil }
        return folder.appendingPathComponent("motion.json")
    }
    private static func valid(_ data: VideoMotionRecord, count: Int) -> Bool {
        guard data.schema == 2, data.steps.count == count, count > 0,
              (2...32768).contains(data.width), (2...32768).contains(data.height),
              data.fps.isFinite, data.fps > 0, data.fps <= 240, data.start.isFinite,
              data.intrinsics.count == 4, data.intrinsics.allSatisfy(\.isFinite), data.intrinsics[0] > 0, data.intrinsics[1] > 0,
              data.steps.allSatisfy({ $0.count == 5 && $0.allSatisfy(\.isFinite) }),
              data.gyro.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) }) else { return false }
        return zip(data.gyro, data.gyro.dropFirst()).allSatisfy { $0[0] < $1[0] }
    }
    public static func load(frames: [SourceFrame]) -> VideoMotionRecord? {
        guard let path = cacheFile(frames), let raw = try? Data(contentsOf: path), raw.count <= 256 * 1024 * 1024,
              let data = try? JSONDecoder().decode(VideoMotionRecord.self, from: raw), valid(data, count: frames.count) else { return nil }
        return data
    }
    /// Fixed physical sensor dimensions and focal length provide a pinhole estimate, not lens calibration.
    static func physicalIntrinsics(reportFrames: [TelemetryJSON], width: Int, height: Int) -> [Double]? {
        guard !reportFrames.isEmpty, width > 0, height > 0 else { return nil }
        var values: [[Double]] = []
        for frame in reportFrames {
            guard let sw = frame["Default"]?["SensorWidth"]?.number,
                  let sh = frame["Default"]?["SensorHeight"]?.number,
                  let focal = frame["Lens"]?["FocalLength"]?.number,
                  [sw, sh, focal].allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
            values.append([sw, sh, focal])
        }
        var fixed: [Double] = []
        for column in 0..<3 {
            let samples = values.map { $0[column] }, mean = samples.reduce(0) { $0 + $1 / Double(samples.count) }
            guard mean.isFinite, mean > 0, (samples.max()! - samples.min()!) / mean < 1e-4 else { return nil }
            fixed.append(mean)
        }
        let sensorAspect = fixed[0] / fixed[1], imageAspect = Double(width) / Double(height)
        guard abs(sensorAspect / imageAspect - 1) <= 0.002 else { return nil }
        let result = [Double(width) * fixed[2] / fixed[0], Double(height) * fixed[2] / fixed[1], Double(width) / 2, Double(height) / 2]
        return result.allSatisfy(\.isFinite) ? result : nil
    }
    public static func save(_ record: VideoMotionRecord, frames: [SourceFrame]) throws {
        guard let path = cacheFile(frames), valid(record, count: frames.count) else { throw VideoImportError.invalid("视频防抖分析结果无效") }
        try JSONEncoder().encode(record).write(to: path, options: .atomic)
    }
    @discardableResult
    public static func importGyro(frames: [SourceFrame], source: URL,
                                  isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> VideoSyncResult {
        guard var record = load(frames: frames) else { throw VideoImportError.invalid("请先完成视频防抖分析，再导入陀螺仪数据") }
        let report = try TelemetryIO.read(source, isCancelled: isCancelled)
        guard report.samples.count >= 10 else { throw VideoImportError.invalid("文件没有足够的陀螺仪采样，无法同步") }
        record.gyro = report.samples.map { [$0.t] + $0.gyro }
        record.gyroSource = source.lastPathComponent
        record.telemetryWarning = ""
        if isCancelled() { throw CancellationError() }
        let sync = synchronize(record)
        if isCancelled() { throw CancellationError() }
        try save(record, frames: frames)
        return sync
    }
    public static func prepare(frames: [SourceFrame], video: URL, start: Double, fps: Double,
                               profile: URL? = nil, force: Bool = false,
                               isCancelled: @escaping @Sendable () -> Bool = { false },
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> VideoMotionRecord? {
        guard let path = cacheFile(frames), let first = frames.first else { return nil }
        if isCancelled() { throw CancellationError() }
        if !force, let data = load(frames: frames) { progress(1); return data }
        guard fps.isFinite, fps > 0, fps <= 240, start.isFinite, start >= 0 else { throw VideoImportError.invalid("视频防抖的时间参数无效") }
        let w = first.pixelWidth, h = first.pixelHeight
        var previous: CGImage?, steps = [[0.0, 0.0, 0.0, 0.0, 1.0]]
        for (i, frame) in frames.enumerated() {
            if isCancelled() { throw CancellationError() }
            try autoreleasepool {
                guard let image = ImageLoader.load(frame.url, maxPixel: 960) else { throw VideoImportError.invalid("无法读取视频帧进行防抖分析") }
                if let previous {
                    let (matrix, quality) = imagePair(previous: previous, current: image), s = Double(image.width) / Double(w)
                    steps.append([matrix.v[2] / s, matrix.v[5] / s, atan2(matrix.v[3], matrix.v[0]), log(hypot(matrix.v[0], matrix.v[3])), quality])
                }
                previous = image
            }
            progress(0.8 * Double(i + 1) / Double(frames.count))
        }
        let metadata = (try? LensCatalog.detect(video: video, width: w, height: h, fps: fps))?.metadata
        var focal = metadata?.focalLength
        if focal == nil, let lens = metadata?.lensModel,
           let range = lens.range(of: #"\d+(?:\.\d+)?\s*mm"#, options: .regularExpression) {
            focal = Double(lens[range].lowercased().replacingOccurrences(of: "mm", with: "").trimmingCharacters(in: .whitespaces))
        }
        let camera = metadata?.cameraModel.uppercased() ?? ""
        let sensor = ["6700", "6600", "6500", "6400", "ZV-E10", "FX30"].contains(where: camera.contains) ? 23.5 : 36.0
        let fx = focal.map { $0 > 0 ? Double(w) * $0 / sensor : 0.9 * Double(w) } ?? 0.9 * Double(w)
        var intrinsics = [fx, fx, Double(w) / 2, Double(h) / 2]
        var intrinsicsSource = "camera-estimate"
        if let profile {
            let lens = try LensProfile.load(profile), sx = Double(w) / Double(lens.width), sy = Double(h) / Double(lens.height)
            intrinsics = [lens.matrix[0][0] * sx, lens.matrix[1][1] * sy, lens.matrix[0][2] * sx, lens.matrix[1][2] * sy]
            intrinsicsSource = "lens-profile"
        }
        var gyro: [[Double]] = [], warning = ""
        do {
            let report = try TelemetryIO.read(video, isCancelled: isCancelled)
            if profile == nil, let physical = physicalIntrinsics(reportFrames: report.rawMetadataFrames, width: w, height: h) {
                intrinsics = physical; intrinsicsSource = "physical-sensor-estimate"
            }
            gyro = report.samples.map { [$0.t] + $0.gyro }
            warning = report.warnings.joined(separator: "；")
        } catch {
            if isCancelled() { throw CancellationError() }
            warning = error.localizedDescription
        }
        if isCancelled() { throw CancellationError() }
        let data = VideoMotionRecord(width: w, height: h, fps: fps, start: start, intrinsics: intrinsics, steps: steps, gyro: gyro, telemetryWarning: warning, intrinsicsSource: intrinsicsSource)
        guard valid(data, count: frames.count) else { throw VideoImportError.invalid("视频防抖分析结果无效") }
        try JSONEncoder().encode(data).write(to: path, options: .atomic)
        progress(1)
        return data
    }

    /// Vision returns a previous->current warp in bottom-left pixels. Keep only its stable similarity component.
    static func imagePair(previous: CGImage, current: CGImage) -> (Mat3, Double) {
        guard previous.width == current.width, previous.height == current.height else { return (.identity, 0) }
        let w = Double(previous.width), h = Double(previous.height), center = V2(w / 2, h / 2)
        var candidates: [(Mat3, Double)] = []
        let flip = Mat3([1, 0, 0, 0, -1, h, 0, 0, 1])
        let request = VNHomographicImageRegistrationRequest(targetedCGImage: previous, options: [:])
        if (try? VNImageRequestHandler(cgImage: current, options: [:]).perform([request])) != nil,
           let observation = request.results?.first {
            let raw = observation.warpTransform
            let matrix = flip * Mat3((0..<9).map { Double(raw[$0 % 3][$0 / 3]) }) * flip
            let c = matrix.apply(center), x = matrix.apply(center + V2(1, 0)) - c, y = matrix.apply(center + V2(0, 1)) - c
            let a = (x.x + y.y) / 2, b = (x.y - y.x) / 2
            let displacement = c - V2(a * center.x - b * center.y, b * center.x + a * center.y)
            candidates.append((Mat3([a, -b, displacement.x, b, a, displacement.y, 0, 0, 1]), Double(observation.confidence)))
        }
        // Translation is more reliable than perspective registration on a low-texture scene.
        let translation = VNTranslationalImageRegistrationRequest(targetedCGImage: previous, options: [:])
        if (try? VNImageRequestHandler(cgImage: current, options: [:]).perform([translation])) != nil,
           let observation = translation.results?.first {
            let t = observation.alignmentTransform
            candidates.append((.similarity(Double(t.tx), -Double(t.ty)), min(0.6, Double(observation.confidence))))
        }
        var best: (Mat3, Double) = (.identity, 0)
        for (matrix, confidence) in candidates {
            let scale = hypot(matrix.v[0], matrix.v[3]), angle = atan2(matrix.v[3], matrix.v[0])
            guard matrix.finite, scale > 0.94, scale < 1.06, abs(angle) < 0.25,
                  (matrix.apply(center) - center).length < max(w, h) * 0.25 else { continue }
            let quality = min(confidence, registrationQuality(previous: previous, current: current, matrix: matrix))
            if quality >= 0.25, quality > best.1 { best = (matrix, quality) }
        }
        return best
    }
    private static func registrationQuality(previous: CGImage, current: CGImage, matrix: Mat3) -> Double {
        let w = min(160, previous.width), h = max(2, Int(Double(previous.height) * Double(w) / Double(previous.width)))
        let rect = CGRect(x: 0, y: 0, width: previous.width, height: previous.height)
        guard let a = GrayPatch.extract(from: previous, rect: rect, outW: w, outH: h),
              let b = GrayPatch.extract(from: current, rect: rect, outW: w, outH: h) else { return 0 }
        let sx = Double(w) / Double(previous.width), sy = Double(h) / Double(previous.height)
        var xsum = 0.0, ysum = 0.0, xx = 0.0, yy = 0.0, xy = 0.0, count = 0.0
        for y in stride(from: 2, to: h - 2, by: 2) { for x in stride(from: 2, to: w - 2, by: 2) {
            let target = matrix.apply(V2((Double(x) + 0.5) / sx, (Double(y) + 0.5) / sy))
            let tx = target.x * sx - 0.5, ty = target.y * sy - 0.5
            guard tx >= 0, ty >= 0, tx < Double(w - 1), ty < Double(h - 1) else { continue }
            let ix = Int(tx), iy = Int(ty), dx = tx - Double(ix), dy = ty - Double(iy)
            let p = Double(a.data[y * w + x])
            let q0 = Double(b.data[iy*w+ix]) * (1-dx) + Double(b.data[iy*w+ix+1]) * dx
            let q1 = Double(b.data[(iy+1)*w+ix]) * (1-dx) + Double(b.data[(iy+1)*w+ix+1]) * dx
            let q = q0 * (1-dy) + q1 * dy
            xsum += p; ysum += q; xx += p*p; yy += q*q; xy += p*q; count += 1
        } }
        guard count >= 30 else { return 0 }
        let variance = (xx-xsum*xsum/count) * (yy-ysum*ysum/count)
        guard variance > 1e-6 else { return 0 }
        return clamp((xy-xsum*ysum/count) / sqrt(variance), 0, 1)
    }

    static func opticalAngularVelocity(_ data: VideoMotionRecord) -> [[Double]] {
        let fx = data.intrinsics[0], fy = data.intrinsics[1], center = V2(data.intrinsics[2], data.intrinsics[3])
        return data.steps.dropFirst().map { step in
            let delta = Mat3.similarity(step[0], step[1], step[2], step[3]).apply(center) - center
            return [delta.y / fy * data.fps, -delta.x / fx * data.fps, -step[2] * data.fps]
        }
    }
    private static func interpolate(_ times: [Double], _ values: [Double], at: [Double]) -> [Double] {
        guard !times.isEmpty else { return Array(repeating: 0, count: at.count) }
        var index = 0
        return at.map { t in
            if t <= times[0] { return values[0] }
            if t >= times[times.count - 1] { return values[values.count - 1] }
            while index + 1 < times.count - 1, times[index + 1] < t { index += 1 }
            while index > 0, times[index] > t { index -= 1 }
            let weight = (t-times[index]) / (times[index+1]-times[index])
            return values[index] * (1-weight) + values[index+1] * weight
        }
    }
    public static func synchronize(_ data: VideoMotionRecord, initial: Double = 0, search: Double = 0.5) -> VideoSyncResult {
        var fallback = VideoSyncResult(); fallback.offset = initial
        guard initial.isFinite else { return VideoSyncResult() }
        guard valid(data, count: data.steps.count), data.gyro.count >= 10, data.steps.count >= 13 else { return fallback }
        let vectors = opticalAngularVelocity(data), n = vectors.count
        let indices = (0..<n).filter { data.steps[$0+1][4] >= 0.3 }
        guard indices.count >= 12 else { return fallback }
        let sigma = max(1, data.fps * 0.25), times = (0..<n).map { data.start + (Double($0) + 0.5) / data.fps }
        let optical = (0..<3).map { axis -> [Double] in
            let raw = vectors.map { $0[axis] }, smooth = Signal.gaussian(raw, sigma: sigma)
            return zip(raw, smooth).map(-)
        }
        let weights = optical.map { values -> Double in
            let mean = indices.reduce(0) { $0 + values[$1] } / Double(indices.count)
            return sqrt(indices.reduce(0) { $0 + pow(values[$1] - mean, 2) } / Double(indices.count))
        }
        let active = (0..<3).filter { weights[$0] > max(1e-5, (weights.max() ?? 0) * 0.1) }
        guard !active.isEmpty else { return fallback }
        let total = active.reduce(0) { $0 + weights[$1] }, imuTimes = data.gyro.map { $0[0] }
        let imu = (0..<3).map { axis in data.gyro.map { $0[axis+1] } }
        let permutations = [[0,1,2], [0,2,1], [1,0,2], [1,2,0], [2,0,1], [2,1,0]]
        var best = fallback; best.score = -2
        var coarseScores: [(offset: Double, score: Double)] = []
        func evaluate(_ offset: Double) -> Double? {
            let at = times.map { $0 + offset }
            let mask = indices.filter { at[$0] >= imuTimes[0] && at[$0] <= imuTimes[imuTimes.count-1] }
            guard Double(mask.count) >= max(12, Double(indices.count) * 0.8) else { return nil }
            let gyro = imu.map { samples -> [Double] in
                let raw = interpolate(imuTimes, samples, at: at), smooth = Signal.gaussian(raw, sigma: sigma)
                return zip(raw, smooth).map(-)
            }
            var correlation = Array(repeating: [Double](repeating: 0, count: 3), count: 3)
            for row in 0..<3 { for col in 0..<3 {
                var numerator = 0.0, a = 0.0, b = 0.0
                for i in mask { let x = optical[row][i], y = gyro[col][i]; numerator += x*y; a += x*x; b += y*y }
                correlation[row][col] = numerator / (sqrt(a*b) + 1e-16)
            } }
            var winner = -2.0
            for axes in permutations {
                var signs = (0..<3).map { correlation[$0][axes[$0]] >= 0 ? 1.0 : -1.0 }
                let parity = ((axes[0]-axes[1]) * (axes[1]-axes[2]) * (axes[0]-axes[2]) < 0) ? 1.0 : -1.0
                if parity * signs.reduce(1, *) < 0 {
                    let least = (0..<3).min { weights[$0] < weights[$1] }!; signs[least] *= -1
                }
                let score = active.reduce(0) { $0 + weights[$1] * correlation[$1][axes[$1]] * signs[$1] } / total
                winner = max(winner, score)
                if score > best.score { best = VideoSyncResult(offset: offset, score: score, valid: score >= 0.6, axes: axes, signs: signs) }
            }
            return winner
        }
        let span = search.isFinite ? clamp(search, 0, 2) : 0.5
        for i in 0...max(0, Int((span*2/0.005).rounded())) {
            let offset = initial-span+Double(i)*0.005
            if let score = evaluate(offset) { coarseScores.append((offset, score)) }
        }
        let center = best.offset
        for i in 0...20 { _ = evaluate(center-0.005+Double(i)*0.0005) }
        if let secondary = coarseScores.filter({ abs($0.offset-best.offset) > 0.07 }).map(\.score).max(), best.score-secondary < 0.03 { best.valid = false }
        if abs(best.offset-initial) >= span-0.005 { best.valid = false }
        best.score = max(0, best.score)
        return best
    }

    private struct Quaternion {
        var v: [Double]
        static let identity = Quaternion(v: [1, 0, 0, 0])
        var normalized: Quaternion {
            let norm = sqrt(v.reduce(0) { $0+$1*$1 })
            return norm > 1e-12 ? Quaternion(v: v.map { $0/norm }) : .identity
        }
        static func * (a: Quaternion, b: Quaternion) -> Quaternion {
            let w=a.v[0], x=a.v[1], y=a.v[2], z=a.v[3], v=b.v[0], i=b.v[1], j=b.v[2], k=b.v[3]
            return Quaternion(v: [w*v-x*i-y*j-z*k, w*i+x*v+y*k-z*j, w*j-x*k+y*v+z*i, w*k+x*j-y*i+z*v])
        }
        static func step(_ vector: [Double]) -> Quaternion {
            let angle = sqrt(vector.reduce(0) { $0+$1*$1 })
            guard angle > 1e-12 else { return .identity }
            return Quaternion(v: [cos(angle/2)] + vector.map { $0/angle*sin(angle/2) })
        }
        var matrix: Mat3 {
            let q=normalized.v, w=q[0], x=q[1], y=q[2], z=q[3]
            return Mat3([1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w),
                         2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w),
                         2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)])
        }
    }
    public static func corrections(_ data: VideoMotionRecord, settings: VideoStabilizationSettings) -> (matrices: [[Double]], status: VideoStabilizationStatus) {
        let n = data.steps.count, fps = data.fps
        guard valid(data, count: n) else { return (Array(repeating: Mat3.identity.v, count: n), VideoStabilizationStatus()) }
        var paths = [Mat3.identity]
        for step in data.steps.dropFirst() { paths.append(Mat3.similarity(step[0], step[1], step[2], step[3]) * paths.last!) }
        var coords = [paths.map { $0.v[2] }, paths.map { $0.v[5] }, paths.map { atan2($0.v[3], $0.v[0]) }, paths.map { log(hypot($0.v[0], $0.v[3])) }]
        coords[2] = Signal.unwrapAngles(coords[2])
        let sigma = max(0.5, min(600, (settings.smoothness.isFinite ? settings.smoothness : 0.5) * fps))
        let target = coords.map { Signal.gaussian($0, sigma: sigma) }
        let visual = (0..<n).map { Mat3.similarity(target[0][$0], target[1][$0], target[2][$0], target[3][$0]) * (paths[$0].inverse ?? .identity) }
        var result = visual, status = VideoStabilizationStatus()
        status.gyroSamples = data.gyro.count; status.measuredFrames = data.steps.filter { $0[4] >= 0.3 }.count
        status.sync = !data.gyro.isEmpty && settings.autoSync ? synchronize(data) : VideoSyncResult()
        if !status.sync.valid { status.sync.offset = 0; status.sync.axes = [1,0,2]; status.sync.signs = [-1,-1,-1] }
        if settings.method != "visual", data.gyro.count >= 10 {
            let imu = data.gyro, axes = status.sync.axes, signs = status.sync.signs
            let rates = imu.map { row in (0..<3).map { row[axes[$0]+1] * signs[$0] } }
            let deltas = (1..<imu.count).map { imu[$0][0]-imu[$0-1][0] }
            let gapThreshold = max(0.1, 5 * (Stats.median(deltas) ?? 0.02))
            let gaps = (1..<imu.count).filter { imu[$0][0]-imu[$0-1][0] > gapThreshold }.map { (imu[$0-1][0], imu[$0][0]) }
            var quaternions = [Quaternion.identity]
            for i in 1..<imu.count {
                if imu[i][0]-imu[i-1][0] > gapThreshold { quaternions.append(quaternions.last!); continue }
                let delta = (0..<3).map { (rates[i][$0]+rates[i-1][$0]) * 0.5 * (imu[i][0]-imu[i-1][0]) }
                var q = (quaternions.last! * Quaternion.step(delta)).normalized
                if zip(q.v, quaternions.last!.v).reduce(0, { $0+$1.0*$1.1 }) < 0 { q.v = q.v.map(-) }
                quaternions.append(q)
            }
            let offset = settings.gyroOffset.isFinite ? settings.gyroOffset : 0
            let times = (0..<n).map { data.start + Double($0)/fps + status.sync.offset + offset }, imuTimes = imu.map { $0[0] }
            let components = (0..<4).map { axis in interpolate(imuTimes, quaternions.map { $0.v[axis] }, at: times) }
            let poses = (0..<n).map { i in Quaternion(v: components.map { $0[i] }).normalized }
            let smoothed = (0..<4).map { axis in Signal.gaussian(poses.map { $0.v[axis] }, sigma: sigma) }
            let k = Mat3([data.intrinsics[0],0,data.intrinsics[2],0,data.intrinsics[1],data.intrinsics[3],0,0,1]), ki = k.inverse ?? .identity
            var gyro = (0..<n).map { i in k * Quaternion(v: smoothed.map { $0[i] }).matrix.transpose * poses[i].matrix * ki }
            let gapMargin = ceil(sigma * 3) / fps
            for i in 0..<n where times[i] < imuTimes[0]-1/fps || times[i] > imuTimes[imuTimes.count-1]+1/fps || gaps.contains(where: { times[i] >= $0.0-gapMargin && times[i] <= $0.1+gapMargin }) { gyro[i] = visual[i] }
            result = gyro; status.method = "陀螺仪防抖"
            if settings.method == "auto" {
                let center = V2(data.intrinsics[2], data.intrinsics[3])
                let residual = (0..<n).map { (visual[$0] * (gyro[$0].inverse ?? .identity)).apply(center)-center }
                let x = Signal.gaussian(residual.map(\.x), sigma: max(0.5, fps*0.04)), y = Signal.gaussian(residual.map(\.y), sigma: max(0.5, fps*0.04))
                result = (0..<n).map { i in
                    let confidence = clamp(data.steps[i][4], 0, 1)
                    return Mat3.similarity(x[i]*confidence, y[i]*confidence) * gyro[i]
                }
                status.method = "陀螺仪＋图像融合"
            }
        }
        return (result.map { $0.attenuated(settings.strength).v }, status)
    }

    public static func composePlan(analysis: SequenceAnalysis, track: Track, composition: Composition,
                                   export: ExportSettings, used: [Int], settings: VideoStabilizationSettings,
                                   record: VideoMotionRecord? = nil) -> (plan: CompositionPlan?, status: VideoStabilizationStatus?) {
        guard settings.enabled, let data = record ?? load(frames: analysis.frames), valid(data, count: analysis.count),
              track.frames.count == analysis.frames.count else { return (nil, nil) }
        let correction = corrections(data, settings: settings), w = Double(data.width), h = Double(data.height)
        var matrices = correction.matrices.map(Mat3.init), status = correction.status, transformed = track
        let lockSize = settings.framing == "subject" && composition.sizeMode == .lockSize && track.frames.contains(where: \.hasData)
        var cameraScale = [Double](repeating: 1, count: matrices.count), logScale = 0.0
        for i in matrices.indices {
            if i > 0 && data.steps[i][4] >= 0.3 { logScale += data.steps[i][3] }
            cameraScale[i] = exp(clamp(logScale, -4, 4))
            if lockSize {
                let p = track.frames[i].headCenter, center = matrices[i].apply(p)
                let x = matrices[i].apply(p + V2(1,0))-center, y = matrices[i].apply(p + V2(0,1))-center
                let scale = cameraScale[i] * sqrt(abs(x.x*y.y-x.y*y.x))
                if scale.isFinite && scale > 0.01 {
                    matrices[i] = Mat3.similarity(center.x,center.y) * Mat3.similarity(0,0,0,-log(scale)) * Mat3.similarity(-center.x,-center.y) * matrices[i]
                }
            }
        }
        let stableSize = lockSize ? stableHeadSizes(track.frames.enumerated().map { $0.element.headLength/cameraScale[$0.offset] }, smoothing: composition.sizeSmoothing) : []
        for i in transformed.frames.indices {
            let source = track.frames[i], matrix = matrices[i]
            transformed.frames[i].eye = matrix.apply(source.eye)
            transformed.frames[i].headCenter = matrix.apply(source.headCenter)
            let tip = matrix.apply(source.headCenter + V2(cos(source.angle), sin(source.angle)) * source.headLength)
            let vector = tip - transformed.frames[i].headCenter
            transformed.frames[i].headLength = max(1e-3, vector.length)
            if lockSize { transformed.frames[i].headLength = stableSize[i] }
            let angle = atan2(vector.y, vector.x), change = angle-source.angle
            transformed.frames[i].angle = source.angle + atan2(sin(change),cos(change))
        }
        let output = export.outputSize, ow = Double(output.w), oh = Double(output.h)
        var base: CompositionPlan
        if settings.framing == "camera" || !track.frames.contains(where: \.hasData) {
            let z = max(ow/w, oh/h)
            base = CompositionPlan(xforms: matrices.map { _ in FrameXform(a: V2(w/2,h/2), p: V2(ow/2,oh/2), z: z, psi: 0, valid: true) }, outW: ow, outH: oh, maxUpscale: z, outOfBoundsFrames: 0)
        } else {
            transformed.medianHeadLength = Stats.median(transformed.frames.map(\.headLength)) ?? track.medianHeadLength
            base = ProjectTimeline.plan(analysis, track: transformed, composition: composition, width: ow, height: oh, used: used)
        }
        func fits(_ xf: FrameXform, _ matrix: Mat3, _ zoom: Double, rawAnchor: V2? = nil) -> Bool {
            var test = xf; test.z *= zoom; test.prewarp = matrix.v
            if let rawAnchor { test.a = matrix.apply(rawAnchor) }
            return test.sourceQuad(outW: ow, outH: oh).allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.x >= -0.01 && $0.y >= -0.01 && $0.x <= w+0.01 && $0.y <= h+0.01 }
        }
        var zooms = [Double](repeating: 1, count: matrices.count)
        if settings.autoZoom {
            let limit = settings.maxZoom.isFinite ? clamp(settings.maxZoom, 1, 8) : 1.4
            for i in matrices.indices {
                let rawAnchor = settings.framing == "subject" && track.frames.contains(where: \.hasData) ? matrices[i].inverse?.apply(base.xforms[i].a) : nil
                for _ in 0..<20 {
                    if fits(base.xforms[i], matrices[i], limit, rawAnchor:rawAnchor) { break }
                    matrices[i] = matrices[i].attenuated(0.7); status.limited = true
                }
                if !fits(base.xforms[i], matrices[i], limit, rawAnchor:rawAnchor), fits(base.xforms[i], .identity, limit, rawAnchor:rawAnchor) { matrices[i] = .identity }
                var lo = 1.0, hi = limit
                for _ in 0..<16 {
                    let mid = (lo+hi)/2
                    if fits(base.xforms[i], matrices[i], mid, rawAnchor:rawAnchor) { hi = mid } else { lo = mid }
                }
                if let rawAnchor { base.xforms[i].a = matrices[i].apply(rawAnchor) }
                zooms[i] = hi
            }
            let eased = Signal.gaussian(Signal.runningMax(zooms, radius: max(1, Int(data.fps*0.15))), sigma: max(0.5, data.fps*0.1))
            zooms = zip(zooms, eased).map(max)
            if settings.fixedZoom || lockSize {
                let selected = used.isEmpty ? Array(zooms.indices) : used
                let fixed = selected.map { zooms[$0] }.max() ?? 1
                zooms = Array(repeating: fixed, count: zooms.count)
            }
        }
        for i in base.xforms.indices { base.xforms[i].z *= zooms[i]; base.xforms[i].prewarp = matrices[i].v }
        base.maxUpscale = base.xforms.map(\.z).max() ?? base.maxUpscale
        status.maxZoom = zooms.max() ?? 1
        return (base, status)
    }

    static func stableHeadSizes(_ values: [Double], smoothing: Double) -> [Double] {
        let logs = values.map { log(max(1e-3,$0)) }
        let center = Stats.median(logs) ?? 0
        let filtered = Signal.gaussian(Signal.median(logs,radius:3),sigma:max(2,smoothing))
        return filtered.map { value in
            let delta = value-center, band = log(1.10)
            return exp(center + (delta >= 0 ? 1 : -1)*max(0,abs(delta)-band))
        }
    }
}
