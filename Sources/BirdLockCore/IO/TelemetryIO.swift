import Foundation

public indirect enum TelemetryJSON: Decodable, Sendable {
    case object([String: TelemetryJSON]), array([TelemetryJSON]), number(Double), string(String), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([String: TelemetryJSON].self) { self = .object(value) }
        else { self = .array(try c.decode([TelemetryJSON].self)) }
    }
    public subscript(_ key: String) -> TelemetryJSON? { if case .object(let map) = self { return map[key] }; return nil }
    public var number: Double? { if case .number(let value) = self { return value }; return nil }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var array: [TelemetryJSON]? { if case .array(let value) = self { return value }; return nil }
}

public struct TelemetrySample: Decodable, Sendable {
    public let t: Double
    public let gyro: [Double]
    public let accel: [Double]?
}

public struct TelemetryReport: Decodable, Sendable {
    public let schema: Int
    public let parser: String
    public let cameraBrand: String
    public let cameraModel: String?
    public let gyroUnit: String
    public let timestampUnit: String
    public let orientation: String
    public let sourceOrientation: String?
    /// Gyroflow's normalized IMU frame: X up, Y left, Z toward the viewer.
    public let imuFrame: String
    public let cameraFrame: String
    /// Multiply an IMU angular-velocity vector by this matrix for OpenCV camera axes.
    public let imuToCamera: [[Double]]
    public let metadataFrameCount: Int
    public let gyroscopeFrameCount: Int
    public let timestampsAccurate: Bool
    public let sonyPacketTimed: Bool
    public let partial: Bool
    public let frameReadoutSeconds: Double?
    public let frameReadoutDirection: String?
    public let video: TelemetryJSON?
    public let samples: [TelemetrySample]
    public let rawMetadataFrames: [TelemetryJSON]
    public let warnings: [String]
    public let projectSettings: TelemetryJSON?

    public static func decode(_ data: Data) throws -> TelemetryReport {
        let report = try JSONDecoder().decode(TelemetryReport.self, from: data)
        guard report.schema == 1, report.gyroUnit == "rad/s", report.timestampUnit == "s",
              report.orientation == "XYZ", report.imuFrame == "gyroflow-x-up-y-left-z-back",
              report.cameraFrame == "opencv-x-right-y-down-z-forward",
              report.imuToCamera == [[0, -1, 0], [-1, 0, 0], [0, 0, -1]],
              report.samples.count <= 2_000_000 else {
            throw TelemetryError.invalid("陀螺仪数据格式或单位无效")
        }
        var previous = -Double.infinity
        for sample in report.samples {
            guard sample.t.isFinite, sample.t > previous, sample.gyro.count == 3, sample.gyro.allSatisfy(\.isFinite) else {
                throw TelemetryError.invalid("陀螺仪时间戳或角速度无效")
            }
            previous = sample.t
        }
        return report
    }
}

public enum TelemetryError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

public enum TelemetryIO {
    public static var helperURL: URL? {
        let fm = FileManager.default
        if let explicit = ProcessInfo.processInfo.environment["BIRDLOCK_TELEMETRY_HELPER"], fm.isExecutableFile(atPath: explicit) {
            return URL(fileURLWithPath: explicit)
        }
        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL { candidates.append(executable.deletingLastPathComponent().appendingPathComponent("BirdLockTelemetry")) }
        if let resource = Bundle.main.resourceURL { candidates.append(resource.appendingPathComponent("Telemetry/BirdLockTelemetry")) }
        var root = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<9 {
            candidates.append(root.appendingPathComponent("dist/telemetry/macos/BirdLockTelemetry"))
            candidates.append(root.appendingPathComponent("dist/telemetry/BirdLockTelemetry"))
            candidates.append(root.appendingPathComponent("tools/telemetry/target/release/birdlock-telemetry"))
            root.deleteLastPathComponent()
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Reads the selected local telemetry source. Accurate source clocks still require alignment validation.
    public static func read(_ source: URL, probe: Bool = false, timeout: Double = 120,
                            isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> TelemetryReport {
        guard let helper = helperURL else { throw TelemetryError.invalid("陀螺仪读取组件缺失，请重新安装完整应用") }
        if isCancelled() { throw CancellationError() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("birdlock-telemetry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("telemetry.json"), errors = folder.appendingPathComponent("errors.log")
        _ = FileManager.default.createFile(atPath: errors.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errors)
        defer { try? errorHandle.close() }
        let process = Process(); process.executableURL = helper
        process.arguments = ["--input", source.standardizedFileURL.path, "--output", output.path] + (probe ? ["--probe"] : [])
        process.standardOutput = FileHandle.nullDevice; process.standardError = errorHandle
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if isCancelled() { process.terminate(); throw CancellationError() }
            if Date() >= deadline { process.terminate(); throw TelemetryError.invalid("读取陀螺仪数据超时") }
            Thread.sleep(forTimeInterval: 0.04)
        }
        process.waitUntilExit()
        if isCancelled() { throw CancellationError() }
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else {
            let data = (try? Data(contentsOf: errors)) ?? Data()
            let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: String])?["error"] ?? String(decoding: data.prefix(4096), as: UTF8.self)
            throw TelemetryError.invalid("无法读取陀螺仪数据：" + detail)
        }
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 256 * 1024 * 1024 else { throw TelemetryError.invalid("陀螺仪数据超过支持范围") }
        return try TelemetryReport.decode(Data(contentsOf: output))
    }
}
