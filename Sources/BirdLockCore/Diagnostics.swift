import Foundation
import Darwin

/// Synchronous key events survive a later native crash; no photos or credentials are recorded.
public enum Diagnostics {
    private static let lock = NSLock()
    private static var handle: FileHandle?
    private static var role = "app"
    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["BIRDLOCK_LOG_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/BirdLock", isDirectory: true)
    }
    public static func start(role name: String = "app") {
        lock.lock(); defer { lock.unlock() }
        guard handle == nil else { return }
        role = name
        let fm = FileManager.default, root = directory
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(name == "app" ? "birdlock.log" : name+".log")
        if let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 2_000_000 {
            let old = path.appendingPathExtension("1")
            try? fm.removeItem(at: old); try? fm.moveItem(at: path, to: old)
        }
        if !fm.fileExists(atPath: path.path) { fm.createFile(atPath: path.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: path); _ = try? handle?.seekToEnd()
        let stderrURL = root.appendingPathComponent(name == "app" ? "native-stderr.log" : "worker-stderr.log")
        if fm.fileExists(atPath: stderrURL.path) {
            let old = stderrURL.appendingPathExtension("1")
            try? fm.removeItem(at: old); try? fm.moveItem(at: stderrURL, to: old)
        }
        let fd = Darwin.open(stderrURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if fd >= 0 { dup2(fd, STDERR_FILENO); Darwin.close(fd) }
        signal(SIGPIPE, SIG_IGN)
        if name == "app" {
            let marker = root.appendingPathComponent("running-session")
            let previous = fm.fileExists(atPath: marker.path)
            try? Data("\(getpid())".utf8).write(to: marker)
            writeLocked("launch version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "development") os=\(ProcessInfo.processInfo.operatingSystemVersionString) cores=\(ProcessInfo.processInfo.processorCount) memory=\(ProcessInfo.processInfo.physicalMemory) previous_exit_unexpected=\(previous)")
            NSSetUncaughtExceptionHandler { exception in
                Diagnostics.record("uncaught exception \(exception.name.rawValue): \(exception.reason ?? "")\n\(exception.callStackSymbols.joined(separator: "\n"))")
            }
        } else { writeLocked("worker started") }
    }
    private static func writeLocked(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(role)] \(message)\n"
        try? handle?.write(contentsOf: Data(line.utf8))
    }
    public static func record(_ message: String) {
        lock.lock(); defer { lock.unlock() }; writeLocked(message)
    }
    public static func finish() {
        record("normal exit")
        if role == "app" { try? FileManager.default.removeItem(at: directory.appendingPathComponent("running-session")) }
        try? handle?.synchronize()
    }
    public static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: NSHomeDirectory(), with: "<用户目录>")
            .replacingOccurrences(of: #"/Volumes/[^"\n]+"#, with: "<外部磁盘路径>", options: .regularExpression)
    }
    public static func export(to destination: URL) throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("BirdLock-Diagnostics-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let info = "BirdLock \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "development")\n\(ProcessInfo.processInfo.operatingSystemVersionString)\ncores=\(ProcessInfo.processInfo.processorCount) memory=\(ProcessInfo.processInfo.physicalMemory)\n"
        try Data(info.utf8).write(to: temp.appendingPathComponent("system.txt"))
        let logs = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in logs where ["log", "1"].contains(file.pathExtension) {
            let stream = try FileHandle(forReadingFrom: file)
            defer { try? stream.close() }
            let size = try stream.seekToEnd()
            try stream.seek(toOffset: size > 4_000_000 ? size-4_000_000 : 0)
            let data = try stream.readToEnd() ?? Data()
            let text = redact(String(decoding: data, as: UTF8.self))
            try Data(text.utf8).write(to: temp.appendingPathComponent(file.lastPathComponent))
        }
        let reports = directory.deletingLastPathComponent().appendingPathComponent("DiagnosticReports")
        let crashes = ((try? fm.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("BirdLock") && ["ips", "crash"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(3)
        for file in crashes {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 10_000_000 {
                let data = try Data(contentsOf: file)
                try Data(redact(String(decoding: data, as: UTF8.self)).utf8).write(to: temp.appendingPathComponent(file.lastPathComponent))
            }
        }
        try Data("包括运行日志、系统信息及最多三份 BirdLock 崩溃报告，不含照片或设置。默认隐藏用户目录，发送前请检查内容。".utf8).write(to: temp.appendingPathComponent("README.txt"))
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".birdlock-logs-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: staged) }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--norsrc", "--noextattr", temp.path, staged.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: staged) }
        else { try fm.moveItem(at: staged, to: destination) }
    }
}
