import Foundation
import BirdLockCore

public enum AircraftModelResources {
    /// Only locate local metadata. Model verification is done before the runtime is allocated.
    public static func directory() throws -> URL {
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["BIRDLOCK_AIRCRAFT_MODELS"] { candidates.append(URL(fileURLWithPath: path)) }
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("AircraftModels")) }
        var parent = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            candidates.append(parent.appendingPathComponent("SharedResources/AircraftModels"))
            parent.deleteLastPathComponent()
        }
        guard let directory = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }) else {
            throw ModelError.notFound("飞机部位模型说明，请使用完整测试包")
        }
        return directory
    }
}
