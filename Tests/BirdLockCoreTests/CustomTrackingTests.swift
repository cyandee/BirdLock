import XCTest
import CoreGraphics
@testable import BirdLockCore

final class CustomTrackingTests: XCTestCase {
    func temporary() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) };return root
    }
    func birds(_ count: Int = 30) -> SequenceAnalysis {
        let frames=(0..<count).map { SourceFrame(id:$0,url:URL(fileURLWithPath:"/fixture-\($0).jpg"),pixelWidth:600,pixelHeight:400,captureTime:nil,fileSize:1,modified:1,exif:ExifInfo()) }
        let per=(0..<count).map { i -> FrameAnalysis in
            var f=FrameAnalysis(index:i);f.birds=[BoxD(x:70+Double(i),y:60,w:130,h:100,score:0.9)];f.target=0
            f.keypoints=[Keypoint](repeating:Keypoint(x:0,y:0,conf:0),count:PoseSchema.cub15.keypoints.count)
            for (part,x,y) in [(BirdPart.beak,150.0,115.0),(.crown,112,75),(.nape,90,100),(.throat,110,130),(.leftEye,110,100),(.rightEye,130,100)] {
                let confidence=(part == .leftEye && i<15) || (part == .rightEye && i>=15) ? 0.99 : 0.65
                f.keypoints[PoseSchema.cub15.index(of:part)!]=Keypoint(x:x+Double(i),y:y,conf:confidence)
            }
            return f
        }
        return SequenceAnalysis(fingerprint:"birds",frames:frames,fps:30,proxyLongSide:600,perFrame:per,poseSchema:.cub15)
    }
    func testFixedEyeFromLastFrameKeepsIdentityAndManualConstraint() throws {
        var a=birds();a.eyeSelections=[EyeSelection(frame:29,side:"left_eye")]
        let fixed=TrackBuilder.build(a)
        for i in 0..<a.count { XCTAssertEqual(fixed.frames[i].measuredEye,V2(110+Double(i),100)) }
        a.manualEye[20]=V2(128,102)
        let manual=TrackBuilder.build(a);XCTAssertEqual(manual.frames[20].eye.x,128,accuracy:0.3)
        let restored=try JSONDecoder().decode(SequenceAnalysis.self,from:JSONEncoder().encode(a))
        XCTAssertEqual(restored.eyeSelections,a.eyeSelections)
        a.eyeSelections=nil;XCTAssertGreaterThan(try XCTUnwrap(TrackBuilder.build(a).frames.last?.measuredEye).x,fixed.frames.last!.measuredEye!.x+10)
    }
    func testFixedEyeDoesNotPretendLongOcclusionIsStillObserved() {
        var a=birds();a.eyeSelections=[EyeSelection(frame:0,side:"left_eye")]
        let li=a.poseSchema.index(of:.leftEye)!
        for i in 4..<a.count { a.perFrame[i].keypoints[li].conf=0 }
        let track=TrackBuilder.build(a)
        XCTAssertFalse(track.frames[20].eyeVisible);XCTAssertFalse(track.frames[20].hasData)
        XCTAssertNotNil(track.frames[3].measuredEye)
    }
    func testSelectedEyeFollowsBurstReordering() throws {
        var a=birds(8);a.clips=[BurstClip(start:0,count:4,fps:30),BurstClip(start:4,count:4,fps:30)];a.groupedDetection=true
        a.eyeSelections=[EyeSelection(frame:3,side:"left_eye"),EyeSelection(frame:7,side:"right_eye")]
        let moved=try ClipOrder.reorder(a,order:[1,0]).analysis
        XCTAssertEqual(moved.selectedEye(at:0),"right_eye");XCTAssertEqual(moved.selectedEye(at:7),"left_eye")
        XCTAssertEqual(moved.track?.frames[0].measuredEye?.x,134)
    }
    func image(frame: Int, blank: Bool = false) throws -> CGImage {
        let width=320,height=240;var random=UInt64(3);var texture=[UInt8](repeating:0,count:70*90)
        for i in texture.indices { random=random &* 6364136223846793005 &+ 1;texture[i]=UInt8(truncatingIfNeeded:random>>32) }
        var pixels=[UInt8](repeating:90,count:width*height)
        if !blank { for y in 0..<70 { for x in 0..<90 { pixels[(70+y+frame)*width+90+x+frame]=texture[y*90+x] } } }
        let provider=try XCTUnwrap(CGDataProvider(data:Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    }
    func testCustomMiddleReferenceTracksIndependentAnchorInBothDirections() throws {
        let root=try temporary(),cache=ProxyCache(root:root.appendingPathComponent("cache"))
        var frames:[SourceFrame]=[]
        for i in 0..<7 {
            let url=root.appendingPathComponent("photo-\(i).jpg");XCTAssertTrue(ImageLoader.writeJPEG(try image(frame:i),to:url,quality:0.98))
            frames.append(try XCTUnwrap(FrameImporter.readFrame(url:url,id:i)))
        }
        var a=try CustomTracking.prepare(frames:frames,fps:30,cache:cache)
        XCTAssertFalse(a.track!.frames.contains(where: { $0.hasData }))
        a.customSeeds=[CustomSeed(frame:3,box:BoxD(x:93,y:73,w:90,h:70,score:1),anchor:V2(113,93))]
        let result=try CustomTracking.retrack(a,cache:cache)
        XCTAssertNotNil(result.perFrame[0].sharpness)
        for i in 0..<7 {
            XCTAssertTrue(result.track!.frames[i].hasData,"frame \(i)")
            XCTAssertEqual(result.track!.frames[i].eye.x,110+Double(i),accuracy:0.6)
            XCTAssertEqual(result.track!.frames[i].eye.y,90+Double(i),accuracy:0.6)
        }
        XCTAssertTrue(a.perFrame.allSatisfy { $0.custom==nil })
        let restored=try JSONDecoder().decode(SequenceAnalysis.self,from:JSONEncoder().encode(result))
        XCTAssertEqual(restored.customSeeds?.first?.anchor,V2(113,93))
        XCTAssertNotEqual(Analyzer.fingerprint(frames),result.fingerprint)
        XCTAssertThrowsError(try CustomTracking.retrack(a,cache:cache,isCancelled:{ true }))
    }
    func testCustomShortGapsAreFlaggedAndNeverBridgeCutsOrLongOcclusions() {
        var a=birds(10);a.subject = .custom;a.eyeSelections=nil
        for i in [0,3,8] { a.perFrame[i].custom=CustomObservation(box:BoxD(x:80,y:60,w:50,h:40,score:1),anchor:V2(90+Double(i),80),confidence:0.9) }
        a.clips=[BurstClip(start:0,count:5,fps:30),BurstClip(start:5,count:5,fps:30)]
        let t=TrackBuilder.build(a)
        XCTAssertTrue(t.frames[1].hasData);XCTAssertFalse(t.frames[1].eyeVisible);XCTAssertEqual(t.frames[1].confidence,0.3)
        XCTAssertFalse(t.frames[4].hasData);XCTAssertFalse(t.frames[5].hasData);XCTAssertFalse(t.frames[9].hasData)
        XCTAssertFalse(CustomTracking.valid(CustomSeed(frame:1,box:BoxD(x:1,y:2,w:50,h:40,score:1),anchor:V2(0,0)),frames:a.frames))
    }
}
