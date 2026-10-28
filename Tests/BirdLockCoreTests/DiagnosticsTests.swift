import XCTest
import CoreImage
@testable import BirdLockCore

final class DiagnosticsTests: XCTestCase {
    func testLong2KSequenceRecyclesWithoutDroppingInterpolationRequests() {
        var budget = OpticalFlowWorkBudget(width: 1440,height: 2560)
        XCTAssertEqual(budget.requestLimit,64)
        let restarts = (0..<599).filter { _ in budget.beginRequest() }
        XCTAssertEqual(restarts.count,9)
        XCTAssertEqual(restarts.first,64)
        XCTAssertEqual(restarts.last,576)
    }
    func testLargerFramesUseShorterWorkerLifetimes() {
        let hd = OpticalFlowWorkBudget(width: 1280,height: 720)
        let uhd = OpticalFlowWorkBudget(width: 3840,height: 2160)
        let maximum = OpticalFlowWorkBudget(width: 8192,height: 4320)
        XCTAssertLessThan(uhd.requestLimit,hd.requestLimit)
        XCTAssertLessThan(maximum.requestLimit,uhd.requestLimit)
        XCTAssertGreaterThanOrEqual(maximum.requestLimit,4)
    }
    func testDiagnosticRedaction() {
        XCTAssertEqual(Diagnostics.redact(NSHomeDirectory()+"/Pictures/a.jpg"),"<用户目录>/Pictures/a.jpg")
        XCTAssertFalse(Diagnostics.redact("/Volumes/private/photos/a.jpg").contains("private"))
    }
    func testInvalidWorkerAndOversizedFramesFailWithoutCrashingParent() {
        let context = CIContext()
        XCTAssertNil(IsolatedInterpolator(width: 9000,height: 40,context: context,cancelled: {false}))
        XCTAssertNil(IsolatedInterpolator(width: 64,height: 64,context: context,cancelled: {false},executable: URL(fileURLWithPath: "/does/not/exist")))
    }
    func testChildCrashAfterHandshakeDoesNotCrashParent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("worker")
        // A native-style abort after the valid handshake and the request header.
        try Data("#!/bin/sh\nprintf 'BLFLOW1\\n'\ndd bs=8 count=1 of=/dev/null 2>/dev/null\nkill -ABRT $$\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],ofItemAtPath: script.path)
        let context = CIContext()
        let ai = try XCTUnwrap(IsolatedInterpolator(width: 64,height: 64,context: context,cancelled: {false},executable: script))
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0,y: 0,width: 64,height: 64))
        XCTAssertNil(ai.interpolate(image,image,phase: 0.5))
        XCTAssertTrue(ai.failed)
        XCTAssertNil(ai.interpolate(image,image,phase: 0.6))
    }
    func testTruncatedWorkerProtocolReturnsEOF() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data([1,2,3]));try pipe.fileHandleForWriting.close()
        XCTAssertNil(try FlowWorkerIO.read(pipe.fileHandleForReading,count: 8))
    }
    func testStalledWorkerTimesOutAndLeavesParentUsable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("worker")
        try Data("#!/bin/sh\nprintf 'BLFLOW1\\n'\nexec /bin/sleep 120\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],ofItemAtPath: script.path)
        let context = CIContext(), started = Date()
        let ai = try XCTUnwrap(IsolatedInterpolator(width: 64,height: 64,context: context,cancelled: {false},executable: script,timeout: 2))
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0,y: 0,width: 64,height: 64))
        XCTAssertNil(ai.interpolate(image,image,phase: 0.5));XCTAssertTrue(ai.failed)
        XCTAssertLessThan(Date().timeIntervalSince(started),8)
    }
    func testBundleContainsLogsAndNotPhotosOrSettings() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root,withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["BIRDLOCK_LOG_DIR"]
        setenv("BIRDLOCK_LOG_DIR",root.path,1)
        defer {
            if let previous { setenv("BIRDLOCK_LOG_DIR",previous,1) } else { unsetenv("BIRDLOCK_LOG_DIR") }
            try? fm.removeItem(at: root)
        }
        try Data((NSHomeDirectory()+"/Pictures/private.jpg").utf8).write(to: root.appendingPathComponent("birdlock.log"))
        try Data("private settings".utf8).write(to: root.appendingPathComponent("settings.json"))
        let zip = root.appendingPathComponent("logs.zip")
        try Diagnostics.export(to: zip)
        let p = Process();p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-Z1",zip.path];let pipe = Pipe();p.standardOutput = pipe
        try p.run()
        let names = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),as: UTF8.self);p.waitUntilExit()
        XCTAssertTrue(names.contains("birdlock.log"));XCTAssertFalse(names.contains("settings.json"))
        XCTAssertFalse(names.contains("._"));XCTAssertTrue(names.contains("README.txt"))
    }
}
