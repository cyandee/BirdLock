import XCTest
import CoreGraphics
@testable import BirdLockCore

final class FocusTests: XCTestCase {
    func testOffscreenBodyFrameNeverAllocatesTheWholeBirdBox() throws {
        let viewport = CGRect(x:0,y:0,width:320,height:240)
        for style in FocusMarkStyle.allCases {
            XCTAssertNil(FocusMark.clippedLayout(rect:CGRect(x:-10000,y:-10000,width:20000,height:20000),viewport:viewport,line:2,style:style))
        }
        let layout = try XCTUnwrap(FocusMark.clippedLayout(rect:CGRect(x:40,y:-10000,width:20000,height:20000),viewport:viewport,line:2,style:.box))
        let image = try XCTUnwrap(FocusMark.image(layout:layout,line:2,style:.box,color:.white))
        XCTAssertLessThanOrEqual(image.width,16)
        XCTAssertEqual(image.height,240)
        XCTAssertLessThan(image.bytesPerRow * image.height,20000)
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        XCTAssertGreaterThan(bytes[120 * image.bytesPerRow + Int(40-layout.bounds.minX)*4 + 3],200)
    }

    func testClippingPreservesVisibleStrokesAndDoesNotInventViewportEdges() throws {
        let viewport = CGRect(x:0,y:0,width:100,height:120)
        func placed(_ image: CGImage, at rect: CGRect) throws -> Data {
            let context = try XCTUnwrap(CGContext(data:nil,width:100,height:120,bitsPerComponent:8,bytesPerRow:400,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image,in:rect)
            let result = try XCTUnwrap(context.makeImage())
            return try XCTUnwrap(result.dataProvider?.data) as Data
        }
        for style in FocusMarkStyle.allCases {
            for rect in [CGRect(x:-20,y:30,width:100,height:70),CGRect(x:10,y:-20,width:50,height:90),CGRect(x:80,y:90,width:70,height:80)] {
                let original = try XCTUnwrap(FocusMark.image(width:Int(rect.width),height:Int(rect.height),line:2,style:style,color:.green))
                let originalWidth = CGFloat(original.width), originalHeight = CGFloat(original.height)
                let referenceRect = CGRect(x:rect.midX-originalWidth/2,
                    y:viewport.height-rect.midY-originalHeight/2,width:originalWidth,height:originalHeight)
                let reference = try placed(original,at:referenceRect)
                let layout = try XCTUnwrap(FocusMark.clippedLayout(rect:rect,viewport:viewport,line:2,style:style))
                let clipped = try XCTUnwrap(FocusMark.image(layout:layout,line:2,style:style,color:.green))
                let actual = try placed(clipped,at:CGRect(x:layout.bounds.minX,y:viewport.height-layout.bounds.maxY,
                    width:CGFloat(clipped.width),height:CGFloat(clipped.height)))
                XCTAssertEqual(actual,reference,"Clipping changed the visible AF frame: \(style) \(rect)")
            }
        }
    }

    func testSeparateColorsMigrateOldSharedColor() throws {
        var s = try JSONDecoder().decode(FocusMarkSettings.self, from: Data(#"{"color":"orange","size":1.8}"#.utf8))
        XCTAssertEqual(s.eyeColor, .orange)
        XCTAssertEqual(s.headColor, .orange)
        XCTAssertEqual(s.bodyColor, .orange)
        XCTAssertEqual(s.bodySize, 1.8)
        s.eyeColor = .white; s.headColor = .black; s.bodyColor = .green
        let saved = try JSONDecoder().decode(FocusMarkSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(saved.color(for: "eye"), .white)
        XCTAssertEqual(saved.color(for: "head"), .black)
        XCTAssertEqual(saved.color(for: "body"), .green)
    }

    func test120HzDoesNotClampTo15Hz() {
        var s = FocusMarkSettings(); s.flashRate = 120
        XCTAssertTrue(s.flashOn(at: 0))
        XCTAssertFalse(s.flashOn(at: 1.0 / 240))
        XCTAssertTrue(s.flashOn(at: 1.0 / 120))
    }
    func testSlowMotionReusesFramesUnlessFlashingIsEnabled() {
        let a = OutputFrame(a: 0, b: 0, t: 0, fade: 1, time: 0)
        let b = OutputFrame(a: 0, b: 0, t: 0, fade: 1, time: 0.1)
        var focus = FocusMarkSettings()
        XCTAssertEqual(a.renderKey(focus: focus), b.renderKey(focus: focus))
        focus.captureFlash = true
        XCTAssertNotEqual(a.renderKey(focus: focus), b.renderKey(focus: focus))
        focus.captureFlash = false; focus.enabled = true; focus.showBody = true; focus.blinkBody = true
        XCTAssertNotEqual(a.renderKey(focus: focus), b.renderKey(focus: focus))
    }
    func testOldSettingsKeepEyeAndDoNotEnableNewEffects() throws {
        let s = try JSONDecoder().decode(FocusMarkSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        XCTAssertTrue(s.showEye)
        XCTAssertFalse(s.showHead)
        XCTAssertFalse(s.showBody)
        XCTAssertFalse(s.captureFlash)
    }

    func testRepeatedFramesStillCarryOutputTime() {
        var s = ExportSettings()
        s.outputFPS = 30
        let frames = TimeMapper.outputFrames(used: [0, 1], sourceFPS: 1, settings: s)
        XCTAssertEqual(frames[1].a, frames[2].a)
        XCTAssertEqual(frames[1].time, 1.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(frames[2].time, 2.0 / 30, accuracy: 1e-9)
    }

    func testBodyFrameEnclosesAllWingCornersAfterRotation() throws {
        let source = SourceFrame(id: 0, url: URL(fileURLWithPath: "/test.jpg"), pixelWidth: 1200,
                                 pixelHeight: 900, captureTime: nil, fileSize: 1, modified: 0, exif: ExifInfo())
        var per = FrameAnalysis(index: 0)
        let box = BoxD(x: 150, y: 200, w: 700, h: 220, score: 0.9)
        per.birds = [box]; per.target = 0
        let tf = TrackFrame(eye: V2(700, 300), headCenter: V2(680, 300), headLength: 60, angle: 0,
                            measuredEye: V2(700, 300), eyeVisible: true, hasData: true, confidence: 1)
        let track = Track(frames: [tf], template: nil, reflectDominant: false, facingRight: true, medianHeadLength: 60)
        let analysis = SequenceAnalysis(fingerprint: "test", frames: [source], fps: 30, proxyLongSide: 1200,
                                        perFrame: [per], poseSchema: .cub15, track: track)
        var comp = Composition(); comp.rotationOffsetDeg = 35
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let job = RenderJob(analysis: analysis, composition: comp, look: LookSettings(), export: ExportSettings(),
                            selection: FrameSelection(), cache: ProxyCache(root: root))
        let rect = try XCTUnwrap(job.focusRect(0, target: "body", scale: 0.5))
        let xf = job.plan.xforms[0].scaled(0.5)
        for q in [V2(150, 200), V2(850, 200), V2(150, 420), V2(850, 420)] {
            let p = xf.map(q)
            XCTAssertTrue(rect.contains(CGPoint(x: p.x, y: p.y)))
        }
    }
}
