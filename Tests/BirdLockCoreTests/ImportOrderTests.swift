import CoreImage
import ImageIO
import os
import UniformTypeIdentifiers
import XCTest
@testable import BirdLockCore

final class ImportOrderTests: XCTestCase {
    private func frame(_ name: String, _ captureTime: Double?) -> SourceFrame {
        SourceFrame(id: 0, url: URL(fileURLWithPath: "/tmp/" + name), pixelWidth: 1, pixelHeight: 1,
                    captureTime: captureTime, fileSize: 0, modified: 0, exif: ExifInfo())
    }

    func testParentFolderImportsPhotosAtMixedDepthsAndGroupsByCaptureTime() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = root.appendingPathComponent("日期一/连拍一", isDirectory: true)
        let second = root.appendingPathComponent("日期二/归档/原片", isDirectory: true)
        let hidden = root.appendingPathComponent(".hidden", isDirectory: true)
        let package = root.appendingPathComponent("Unused.app/Contents", isDirectory: true)
        for folder in [first, second, hidden, package] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? files.removeItem(at: root) }

        let fixture = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try XCTUnwrap(FrameRenderer.shared.renderCGImage(fixture))
        func photo(_ folder: URL, _ name: String, _ timestamp: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            let metadata = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: timestamp]]
            CGImageDestinationAddImage(writer, image, metadata as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(writer))
            return url
        }

        let expected = try [
            photo(root, "00.JPG", "2026:11:16 09:10:00"),
            photo(first, "DSC001.jpg", "2026:11:16 09:10:00"),
            photo(second, "DSC001.jpg", "2026:11:16 09:11:00"),
            photo(second, "DSC002.jpg", "2026:11:16 09:11:00"),
        ]
        _ = try photo(hidden, "unused.jpg", "2026:11:16 09:12:00")
        _ = try photo(package, "unused.jpg", "2026:11:16 09:12:00")
        try Data().write(to: first.appendingPathComponent("readme.txt"))
        try files.createSymbolicLink(at: second.appendingPathComponent("loop"), withDestinationURL: root)
        try files.createSymbolicLink(at: second.appendingPathComponent("duplicate.jpg"), withDestinationURL: expected[0])

        let inputs = [root, second, expected[1]]
        XCTAssertEqual(Set(FrameImporter.collectImageURLs(inputs)), Set(expected))
        let frames = FrameImporter.importFrames(inputs)
        XCTAssertEqual(frames.map(\.url), expected)
        XCTAssertEqual(frames.map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(FrameImporter.segments(frames).map(\.range), [0..<2, 2..<4])

        let reports = OSAllocatedUnfairLock(initialState: [(done: Int, total: Int)]())
        let imported = FrameImporter.importFiles(expected + [expected[1]], rawMode: .camera, pairPolicy: .jpeg,
                                                 progress: { done, total in reports.withLock { $0.append((done, total)) } })
        XCTAssertEqual(imported.map(\.url), expected)
        let updates = reports.withLock { $0 }
        XCTAssertEqual(updates.first?.done, 0)
        XCTAssertEqual(updates.last?.done, expected.count)
        XCTAssertTrue(updates.allSatisfy { $0.total == expected.count })
        XCTAssertTrue(zip(updates, updates.dropFirst()).allSatisfy { $0.done < $1.done })

        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let partial = FrameImporter.importFiles(expected, rawMode: .camera, pairPolicy: .jpeg,
                                                isCancelled: { cancelled.withLock { $0 } },
                                                progress: { done, _ in
            if done == 1 { cancelled.withLock { $0 = true } }
        })
        XCTAssertTrue(cancelled.withLock { $0 })
        XCTAssertTrue(partial.isEmpty)

        var checks = 0
        XCTAssertTrue(FrameImporter.collectImageURLs([root], isCancelled: {
            checks += 1
            return checks >= 3
        }).isEmpty)
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
