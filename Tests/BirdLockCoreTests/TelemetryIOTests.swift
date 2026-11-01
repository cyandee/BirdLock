import Foundation
import XCTest
@testable import BirdLockCore

final class TelemetryIOTests: XCTestCase {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/telemetry/tests/fixtures/known-rates.gcsv")
    }

    func testActualHelperConvertsSourceUnitsAndDeclaresCameraAxes() throws {
        try XCTSkipIf(TelemetryIO.helperURL == nil, "Build the telemetry helper first")
        let original = try Data(contentsOf: fixture)
        let report = try TelemetryIO.read(fixture)
        XCTAssertEqual(try Data(contentsOf: fixture), original)
        XCTAssertEqual(report.parser, "GyroflowGcsv")
        XCTAssertEqual(report.samples.count, 3)
        XCTAssertEqual(report.samples[0].t, 0, accuracy: 1e-12)
        XCTAssertEqual(report.samples[1].t, 0.01, accuracy: 1e-12)
        XCTAssertEqual(report.samples[0].gyro, [1, -2, 3])
        XCTAssertEqual(report.samples[0].accel?[1] ?? 0, 9.80665, accuracy: 1e-10)
        XCTAssertEqual(report.imuToCamera, [[0, -1, 0], [-1, 0, 0], [0, 0, -1]])
        XCTAssertFalse(report.timestampsAccurate)
    }

    func testCancellationAndUnreadableInputProduceErrors() throws {
        try XCTSkipIf(TelemetryIO.helperURL == nil, "Build the telemetry helper first")
        XCTAssertThrowsError(try TelemetryIO.read(fixture, isCancelled: { true })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertThrowsError(try TelemetryIO.read(fixture.deletingLastPathComponent().appendingPathComponent("missing.gcsv")))
    }
}
