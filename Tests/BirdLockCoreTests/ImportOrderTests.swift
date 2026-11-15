import XCTest
@testable import BirdLockCore

final class ImportOrderTests: XCTestCase {
    private func frame(_ name: String, _ captureTime: Double?) -> SourceFrame {
        SourceFrame(id: 0, url: URL(fileURLWithPath: "/tmp/" + name), pixelWidth: 1, pixelHeight: 1,
                    captureTime: captureTime, fileSize: 0, modified: 0, exif: ExifInfo())
    }

    func testPhotosWithoutCaptureTimeComeLastInNameOrder() {
        let ordered = FrameImporter.sortedForImport([
            frame("b.jpg", nil), frame("c.jpg", 20), frame("a.jpg", nil), frame("z.jpg", 10),
        ])
        XCTAssertEqual(ordered.map(\.fileName), ["z.jpg", "c.jpg", "a.jpg", "b.jpg"])
    }

    func testMixedTimeAndNameOrderingIsDeterministic() {
        // A near-equal pair must not flip back to file-name order: the previous comparator
        // compared time for distant pairs and names otherwise, which was not transitive.
        let ordered = FrameImporter.sortedForImport([frame("c.jpg", 10), frame("b.jpg", nil), frame("a.jpg", 20)])
        XCTAssertEqual(ordered.map(\.fileName), ["c.jpg", "a.jpg", "b.jpg"])
    }
}
