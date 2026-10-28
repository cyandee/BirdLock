import XCTest
import CoreImage
@testable import BirdLockCore

final class OpticalFlowColorTests: XCTestCase {
    private let width = 1280, height = 720
    private let colors: [[UInt8]] = [
        [0,0,0], [16,16,16], [32,32,32], [64,64,64], [96,96,96],
        [128,128,128], [160,160,160], [192,192,192], [224,224,224], [255,255,255],
        [64,128,192], [192,128,64], [32,160,96], [160,64,128], [192,192,64], [64,192,192],
    ]

    private func fixture(moving: Bool = false) -> CIImage {
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for y in 0..<height { for x in 0..<width {
                let color = colors[min(colors.count-1, x * colors.count / width)]
                let i = (y * width + x) * 4
                p[i] = color[2]; p[i+1] = color[1]; p[i+2] = color[0]; p[i+3] = 255
            }}
        }
        var image = CIImage(bitmapData: bytes, bytesPerRow: width*4,
                            size: CGSize(width: width, height: height), format: .BGRA8,
                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        if moving {
            let patch = CIImage(color: .white).cropped(to: CGRect(x: 610, y: 290, width: 80, height: 80))
            image = patch.composited(over: image)
        }
        return image
    }

    private func bytes(_ image: CIImage, context: CIContext) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: width*height*4)
        context.render(image, toBitmap: &result, rowBytes: width*4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .BGRA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return result
    }

    @available(macOS 15.4, *)
    private func checkBackground(_ image: CIImage, reference: CIImage, context: CIContext,
                                 phase: Double, file: StaticString = #filePath, line: UInt = #line) {
        let actual = bytes(image, context: context), expected = bytes(reference, context: context)
        // Stay away from color boundaries and the moving foreground patch.
        for j in colors.indices {
            let x = Int((Double(j)+0.5) * Double(width) / Double(colors.count))
            let i = (height/8 * width + x) * 4
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(abs(Int(actual[i+channel])-Int(expected[i+channel])), 2,
                    "Optical flow changed stable patch \(j), channel \(channel), phase \(phase)", file: file, line: line)
            }
        }
    }

    func testStaticImageKeepsGrayRampAndColorsAtEveryPhase() throws {
        guard #available(macOS 15.4, *), AIInterpolator.isSupported else {
            throw XCTSkip("VideoToolbox optical flow is unavailable on this device")
        }
        let context = FrameRenderer().context
        let ai = try XCTUnwrap(AIInterpolator(width: width, height: height, context: context))
        let source = fixture()
        for phase in [0.25, 0.5, 0.75] {
            let interpolated = try XCTUnwrap(ai.interpolate(source, source, phase: phase))
            checkBackground(interpolated, reference: source, context: context, phase: phase)
        }
    }

    func testMovingForegroundKeepsBackgroundExposure() throws {
        guard #available(macOS 15.4, *), AIInterpolator.isSupported else {
            throw XCTSkip("VideoToolbox optical flow is unavailable on this device")
        }
        let context = FrameRenderer().context
        let ai = try XCTUnwrap(AIInterpolator(width: width, height: height, context: context))
        let first = fixture(moving: true)
        let second = CIImage(color: .white).cropped(to: CGRect(x: 650, y: 290, width: 80, height: 80))
            .composited(over: fixture())
        let interpolated = try XCTUnwrap(ai.interpolate(first, second, phase: 0.5))
        checkBackground(interpolated, reference: first, context: context, phase: 0.5)
    }
}
