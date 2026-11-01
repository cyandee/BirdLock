import XCTest
import CoreImage
@testable import BirdLockCore

final class VideoStabilizationTests: XCTestCase {
    func testStableSizeRejectsDetectionNoiseAndResourceBudgetRespectsMemory() {
        let sizes=(0..<120).map { 80*(1+0.35*sin(Double($0)*1.7)) }
        let stable=VideoStabilization.stableHeadSizes(sizes,smoothing:12)
        XCTAssertLessThan((stable.max()!-stable.min()!)/80,0.03)
        XCTAssertEqual(ResourceBudget.workers(bytesPerTask:96<<20,cpu:2,memory:4<<30),1)
        XCTAssertGreaterThan(ResourceBudget.workers(bytesPerTask:96<<20,cpu:64,memory:128<<30),8)
        XCTAssertEqual(ResourceBudget.workers(bytesPerTask:500<<20,cpu:64,memory:8<<30),1)
    }

    func testLargeCropAvoidsWeakeningMotionAndKeepsConstantZoom() throws {
        let root=try temporary(),n=90
        try Data("{}".utf8).write(to:root.appendingPathComponent("video-source.json"))
        let shifts=(0..<n).map { V2(350*sin(Double($0)*0.8),0) }
        let data=record(shifts),fr=frames(root,count:n)
        let tf=TrackFrame(eye:V2(480,270),headCenter:V2(480,270),headLength:80,angle:0,measuredEye:nil,eyeVisible:false,hasData:false,confidence:0)
        let track=Track(frames:Array(repeating:tf,count:n),template:nil,reflectDominant:false,facingRight:true,medianHeadLength:80)
        let a=SequenceAnalysis(fingerprint:"crop",frames:fr,fps:30,proxyLongSide:960,perFrame:(0..<n).map { FrameAnalysis(index:$0) },poseSchema:.cub15,track:track)
        var s=VideoStabilizationSettings();s.framing="camera"
        var e=ExportSettings();e.aspect=AspectRatio(w:16,h:9,label:"16:9");e.shortSide=360
        let low=VideoStabilization.composePlan(analysis:a,track:track,composition:Composition(),export:e,used:Array(0..<n),settings:s,record:data)
        s.maxZoom=8
        let high=VideoStabilization.composePlan(analysis:a,track:track,composition:Composition(),export:e,used:Array(0..<n),settings:s,record:data)
        XCTAssertTrue(try XCTUnwrap(low.status).limited);XCTAssertFalse(try XCTUnwrap(high.status).limited)
        let plan=try XCTUnwrap(high.plan),zs=plan.xforms.map(\.z)
        XCTAssertGreaterThan(try XCTUnwrap(high.status).maxZoom,2.5)
        XCTAssertLessThan(zs.max()!-zs.min()!,1e-10)
    }

    func testLimitedCorrectionPreservesSubjectAnchor() throws {
        let root = try temporary(), n = 90
        let shifts = (0..<n).map { V2(450*sin(Double($0)*0.8),0) }
        let fr = frames(root,count:n)
        let tracked = shifts.map { p in TrackFrame(eye:V2(480,270)+p,headCenter:V2(480,270)+p,headLength:80,angle:0,measuredEye:nil,eyeVisible:true,hasData:true,confidence:1) }
        let track = Track(frames:tracked,template:nil,reflectDominant:false,facingRight:true,medianHeadLength:80)
        let analysis = SequenceAnalysis(fingerprint:"limited-anchor",frames:fr,fps:30,proxyLongSide:960,perFrame:(0..<n).map { FrameAnalysis(index:$0) },poseSchema:.cub15,track:track)
        var composition = Composition();composition.framing=3;composition.edgeFill = .black;composition.autoLeadRoom=false;composition.followSoftness=0
        var export = ExportSettings();export.aspect=AspectRatio(w:16,h:9,label:"16:9");export.shortSide=360
        let result = VideoStabilization.composePlan(analysis:analysis,track:track,composition:composition,export:export,used:Array(0..<n),settings:VideoStabilizationSettings(),record:record(shifts))
        XCTAssertTrue(try XCTUnwrap(result.status).limited)
        let plan = try XCTUnwrap(result.plan)
        let first = plan.xforms[0].map(tracked[0].eye)
        for i in 0..<n { XCTAssertLessThan((plan.xforms[i].map(tracked[i].eye)-first).length,1e-6) }
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return root
    }
    private func frames(_ root: URL, count: Int, width: Int = 960, height: Int = 540) -> [SourceFrame] {
        (0..<count).map { SourceFrame(id:$0,url:root.appendingPathComponent(String(format:"video-%06d.png",$0)),pixelWidth:width,pixelHeight:height,captureTime:Double($0)/30,fileSize:0,modified:0,exif:ExifInfo()) }
    }
    private func record(_ shifts: [V2]) -> VideoMotionRecord {
        let steps = shifts.indices.map { i -> [Double] in
            let delta = i == 0 ? V2.zero : shifts[i]-shifts[i-1]
            return [delta.x,delta.y,0,0,1]
        }
        return VideoMotionRecord(width:960,height:540,fps:30,start:0,intrinsics:[900,900,480,270],steps:steps,gyro:[])
    }
    private func jitter(_ points: [V2]) -> Double {
        guard points.count > 2 else { return 0 }
        var total: Double = 0
        for i in 1..<(points.count-1) {
            let before: V2 = points[i-1]
            let middle: V2 = points[i]*2
            let after: V2 = points[i+1]
            let acceleration: V2 = after-middle+before
            total += acceleration.length
        }
        return total / Double(points.count-2)
    }
    func testPhysicalSensorIntrinsicsRequireFixedCompleteCompatibleMetadata() throws {
        func frame(sensorWidth: Double = 31.948, sensorHeight: Double = 17.971, focal: Double = 600) -> TelemetryJSON {
            .object(["Default":.object(["SensorWidth":.number(sensorWidth),"SensorHeight":.number(sensorHeight)]),"Lens":.object(["FocalLength":.number(focal)])])
        }
        let fixed = [frame(),frame(),frame()]
        let estimate = try XCTUnwrap(VideoStabilization.physicalIntrinsics(reportFrames:fixed,width:3840,height:2160))
        XCTAssertEqual(estimate[0],3840*600/31.948,accuracy:1e-8)
        XCTAssertEqual(estimate[1],2160*600/17.971,accuracy:1e-8)
        XCTAssertEqual(Array(estimate.suffix(2)),[1920,1080])
        XCTAssertNotNil(VideoStabilization.physicalIntrinsics(reportFrames:[frame(),frame(focal:600.001)],width:3840,height:2160))
        XCTAssertNil(VideoStabilization.physicalIntrinsics(reportFrames:[frame(),frame(focal:599)],width:3840,height:2160),"Changing focal length must retain the original fallback")
        XCTAssertNil(VideoStabilization.physicalIntrinsics(reportFrames:[frame(),frame(sensorWidth:32)],width:3840,height:2160))
        XCTAssertNil(VideoStabilization.physicalIntrinsics(reportFrames:[frame(),.object(["Lens":.object(["FocalLength":.number(600)])])],width:3840,height:2160),"Every metadata frame must have all three physical values")
        for invalid in [0.0,-1,.nan,.infinity] {
            XCTAssertNil(VideoStabilization.physicalIntrinsics(reportFrames:[frame(focal:invalid)],width:3840,height:2160))
            XCTAssertNil(VideoStabilization.physicalIntrinsics(reportFrames:[frame(sensorWidth:invalid)],width:3840,height:2160))
        }
        XCTAssertNil(VideoStabilization.physicalIntrinsics(reportFrames:fixed,width:3840,height:2880),"A cropped or different-aspect image cannot use the full physical sensor dimensions")
        XCTAssertNil(VideoStabilization.physicalIntrinsics(reportFrames:[],width:3840,height:2160))
        XCTAssertNil(VideoStabilization.physicalIntrinsics(reportFrames:fixed,width:0,height:2160))
    }
    func testProjectiveMappingInverseAndOldSettingsCompatibility() throws {
        let matrix = Mat3([1.01,0.03,12,-0.02,0.99,-7,0.00008,-0.00004,1])
        let transform = FrameXform(a:V2(480,270),p:V2(320,180),z:0.8,psi:0.17,valid:true,prewarp:matrix.v)
        for point in [V2(0,0),V2(300,140),V2(960,540)] {
            let expected = transform.p + (matrix.apply(point)-transform.a).rotated(transform.psi)*transform.z
            XCTAssertLessThan((transform.map(point)-expected).length,1e-10)
            XCTAssertLessThan((transform.unmap(transform.map(point))-point).length,1e-9)
        }
        for (output,input) in zip([V2(0,0),V2(640,0),V2(640,360),V2(0,360)],transform.sourceQuad(outW:640,outH:360)) {
            XCTAssertLessThan((transform.map(input)-output).length,1e-9)
        }
        let old = try JSONDecoder().decode(LookSettings.self,from:Data(#"{"deflicker":false,"exposureEV":0.5}"#.utf8))
        XCTAssertFalse(old.deflicker);XCTAssertTrue(old.stabilization.enabled);XCTAssertEqual(old.stabilization.framing,"subject")
        let xf = FrameXform(a:.zero,p:.zero,z:1,psi:0,valid:true)
        let raw = try JSONEncoder().encode(xf)
        XCTAssertNil(try JSONDecoder().decode(FrameXform.self,from:raw).prewarp)
    }
    func testVisualPathReducesJitterAndCameraFramingKeepsSafeCorners() throws {
        let root = try temporary(), n = 90
        try Data("{}".utf8).write(to:root.appendingPathComponent("video-source.json"))
        let shifts = (0..<n).map { V2(22*sin(Double($0)*1.3)+Double($0)*0.3,15*cos(Double($0)*1.1)-15) }
        let data = record(shifts), sourceFrames = frames(root,count:n)
        try VideoStabilization.save(data,frames:sourceFrames)
        var settings = VideoStabilizationSettings();settings.method = "visual";settings.framing = "camera"
        let result = VideoStabilization.corrections(data,settings:settings)
        let input = shifts.map { V2(400,240)+$0 }, stabilized = zip(result.matrices,input).map { Mat3($0.0).apply($0.1) }
        XCTAssertLessThan(jitter(stabilized),jitter(input)*0.05)
        XCTAssertEqual(result.status.gyroSamples,0);XCTAssertEqual(result.status.method,"图像防抖")
        let tracked = TrackFrame(eye:V2(480,270),headCenter:V2(480,270),headLength:100,angle:0,measuredEye:nil,eyeVisible:false,hasData:false,confidence:0)
        let track = Track(frames:Array(repeating:tracked,count:n),template:nil,reflectDominant:false,facingRight:true,medianHeadLength:100)
        let analysis = SequenceAnalysis(fingerprint:"camera-test",frames:sourceFrames,fps:30,proxyLongSide:960,perFrame:(0..<n).map { FrameAnalysis(index:$0) },poseSchema:.cub15,track:track)
        var export = ExportSettings();export.aspect = AspectRatio(w:16,h:9,label:"16:9");export.shortSide = 360
        let composed = VideoStabilization.composePlan(analysis:analysis,track:track,composition:Composition(),export:export,used:Array(0..<n),settings:settings)
        let plan = try XCTUnwrap(composed.plan)
        XCTAssertEqual(plan.xforms.count,n);XCTAssertLessThanOrEqual(try XCTUnwrap(composed.status).maxZoom,1.4)
        for xf in plan.xforms {
            XCTAssertNotNil(xf.prewarp)
            for point in xf.sourceQuad(outW:640,outH:360) {
                XCTAssertGreaterThanOrEqual(point.x,-0.02);XCTAssertGreaterThanOrEqual(point.y,-0.02)
                XCTAssertLessThanOrEqual(point.x,960.02);XCTAssertLessThanOrEqual(point.y,540.02)
            }
        }
        var look = LookSettings();look.stabilization = settings
        let job = RenderJob(analysis:analysis,composition:Composition(),look:look,export:export,selection:FrameSelection(),cache:ProxyCache(root:root.appendingPathComponent("render-cache")))
        XCTAssertEqual(job.used.count,n,"Camera framing must retain frames without a detected subject")
        XCTAssertNotNil(job.stabilizationStatus)
        settings.maxZoom = 1
        let noMargin = try XCTUnwrap(VideoStabilization.composePlan(analysis:analysis,track:track,composition:Composition(),export:export,used:Array(0..<n),settings:settings).plan)
        for xf in noMargin.xforms { for point in xf.sourceQuad(outW:640,outH:360) {
            XCTAssertGreaterThanOrEqual(point.x,-0.02);XCTAssertGreaterThanOrEqual(point.y,-0.02)
            XCTAssertLessThanOrEqual(point.x,960.02);XCTAssertLessThanOrEqual(point.y,540.02)
        } }
        settings.enabled = false
        XCTAssertNil(VideoStabilization.composePlan(analysis:analysis,track:track,composition:Composition(),export:export,used:Array(0..<n),settings:settings).plan)
    }
    func testSynchronizationRecoversSourceClockOffsetAndCameraAxes() {
        let fps = 30.0, n = 180, offset = 0.137
        func velocity(_ t: Double) -> [Double] {
            [0.11*sin(8.3*t)+0.05*cos(13.7*t),0.13*cos(6.1*t)+0.03*sin(17.3*t),0.08*sin(11.3*t)+0.02*cos(21.7*t)]
        }
        let cx = 480.0, cy = 270.0, focal = 900.0
        var steps = [[0.0,0,0,0,1]]
        for i in 0..<(n-1) {
            let v = velocity(0.5+(Double(i)+0.5)/fps), angle = -v[2]/fps
            let dx = -v[1]*focal/fps - (cos(angle)*cx-sin(angle)*cy-cx)
            let dy = v[0]*focal/fps - (sin(angle)*cx+cos(angle)*cy-cy)
            steps.append([dx,dy,angle,0,1])
        }
        let gyro = (0...3000).map { i -> [Double] in
            let t = Double(i)/400, v = velocity(t-offset)
            return [t,-v[1],-v[0],-v[2]]
        }
        let data = VideoMotionRecord(width:960,height:540,fps:fps,start:0.5,intrinsics:[focal,focal,cx,cy],steps:steps,gyro:gyro)
        let sync = VideoStabilization.synchronize(data)
        XCTAssertTrue(sync.valid);XCTAssertGreaterThan(sync.confidence,0.99)
        XCTAssertEqual(sync.offset,offset,accuracy:0.002)
        XCTAssertEqual(sync.axes,[1,0,2]);XCTAssertEqual(sync.signs,[-1,-1,-1])
        var settings = VideoStabilizationSettings();settings.method = "gyro"
        let result = VideoStabilization.corrections(data,settings:settings)
        XCTAssertEqual(result.status.method,"陀螺仪防抖");XCTAssertEqual(result.status.gyroSamples,3001)
        XCTAssertTrue(result.matrices.flatMap { $0 }.allSatisfy(\.isFinite))
    }
    func testGyroscopeRotationReducesMeasuredRollJitter() {
        let fps = 30.0, n = 150, cx = 480.0, cy = 270.0
        func angle(_ t: Double) -> Double { 0.035*sin(14*t)+0.03*t }
        func rate(_ t: Double) -> Double { 0.49*cos(14*t)+0.03 }
        let angles = (0..<n).map { angle(0.3+Double($0)/fps) }
        var steps = [[0.0,0,0,0,1]]
        for i in 1..<n {
            let a = angles[i]-angles[i-1]
            steps.append([cx-cos(a)*cx+sin(a)*cy,cy-sin(a)*cx-cos(a)*cy,a,0,1])
        }
        let gyro = (0...2400).map { i in [Double(i)/400,0,0,rate(Double(i)/400)] }
        let data = VideoMotionRecord(width:960,height:540,fps:fps,start:0.3,intrinsics:[900,900,cx,cy],steps:steps,gyro:gyro)
        var settings = VideoStabilizationSettings();settings.method = "gyro";settings.autoSync = false
        let result = VideoStabilization.corrections(data,settings:settings)
        let observed = angles.map { V2(cx,cy)+V2(280,0).rotated($0-angles[0]) }
        let stabilized = zip(result.matrices,observed).map { Mat3($0.0).apply($0.1) }
        XCTAssertLessThan(jitter(stabilized),jitter(observed)*0.06)
        XCTAssertEqual(result.status.method,"陀螺仪防抖");XCTAssertFalse(result.status.sync.valid)
    }
    func testSynchronizationRejectsPeriodicAmbiguity() {
        let fps = 60.0, offset = 0.137
        func rate(_ t: Double) -> Double { 0.2*sin(20 * .pi * t) }
        var steps = [[0.0,0,0,0,1]]
        for i in 0..<179 { steps.append([0,rate(0.5+(Double(i)+0.5)/fps)*900/fps,0,0,1]) }
        let gyro = (0...1800).map { i in [Double(i)/400,0,-rate(Double(i)/400-offset),0] }
        let data = VideoMotionRecord(width:960,height:540,fps:fps,start:0.5,intrinsics:[900,900,480,270],steps:steps,gyro:gyro)
        let sync = VideoStabilization.synchronize(data)
        XCTAssertGreaterThan(sync.score,0.95,"A periodic signal can correlate strongly at many offsets")
        XCTAssertFalse(sync.valid,"Several equally strong time offsets must not be accepted as automatic synchronization")
    }
    func testGyroscopeMissingIntervalFallsBackToVisualThroughSmoothingWindow() {
        let n = 180, fps = 30.0
        let shifts = (0..<n).map { V2(8*sin(Double($0)*1.1),5*cos(Double($0)*0.9)-5) }
        var data = record(shifts)
        data.gyro = (0...2400).compactMap { i -> [Double]? in
            let t = Double(i)/400
            if t > 2, t < 2.7 { return nil }
            return [t,0.25*sin(12*t),0.2*cos(9*t),0.3*sin(15*t)]
        }
        var settings = VideoStabilizationSettings();settings.autoSync = false;settings.method = "gyro";settings.smoothness = 0.1
        let gyro = VideoStabilization.corrections(data,settings:settings)
        settings.method = "visual"
        let visual = VideoStabilization.corrections(data,settings:settings)
        for i in 0..<n where Double(i)/fps >= 1.7 && Double(i)/fps <= 3 {
            for j in 0..<9 { XCTAssertEqual(gyro.matrices[i][j],visual.matrices[i][j],accuracy:1e-12) }
        }
        XCTAssertTrue(gyro.matrices.flatMap { $0 }.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(zip(gyro.matrices[30],visual.matrices[30]).map { abs($0-$1) }.max() ?? 0,0.01)
    }
    func testPrepareWritesMotionCacheAndExternalGyroPreservesIt() throws {
        let root = try temporary(), sourceFrames = frames(root,count:3,width:640,height:480), renderer = FrameRenderer.shared
        try Data("{}".utf8).write(to:root.appendingPathComponent("video-source.json"))
        let image = try texturedImage(width:640,height:480)
        for i in sourceFrames.indices {
            let xf = FrameXform(a:.zero,p:V2(Double(i)*5,Double(i)*(-3)),z:1,psi:0,valid:true)
            let output = renderer.compose(source:CIImage(cgImage:image),sourceScale:1,originalHeight:480,xform:xf,outW:640,outH:480,gains:[1,1,1],edgeFill:.black)
            XCTAssertTrue(ImageLoader.writePNG(try XCTUnwrap(renderer.renderCGImage(output)),to:sourceFrames[i].url))
        }
        let data = try XCTUnwrap(VideoStabilization.prepare(frames:sourceFrames,video:sourceFrames[0].url,start:0,fps:30))
        XCTAssertEqual(data.steps.count,3);XCTAssertEqual(data.gyro.count,0)
        XCTAssertEqual(data.steps[1][0],5,accuracy:1);XCTAssertEqual(data.steps[1][1],-3,accuracy:1)
        XCTAssertGreaterThan(data.steps[1][4],0.7)
        let cached = try XCTUnwrap(VideoStabilization.load(frames:sourceFrames))
        XCTAssertEqual(cached.steps,data.steps)
        XCTAssertThrowsError(try VideoStabilization.prepare(frames:sourceFrames,video:sourceFrames[0].url,start:0,fps:30,isCancelled:{true}))
        guard TelemetryIO.helperURL != nil else { throw XCTSkip("Local telemetry helper is not built") }
        let csv = root.appendingPathComponent("motion.gcsv")
        let lines = ["GYROFLOW IMU LOG","version,1.3","id,BirdLock test","orientation,XYZ","tscale,0.01","gscale,1","ascale,1","t,gx,gy,gz"] + (0..<40).map { "\($0),0.1,0.2,0.3" }
        try lines.joined(separator:"\n").write(to:csv,atomically:true,encoding:.utf8)
        let sync = try VideoStabilization.importGyro(frames:sourceFrames,source:csv)
        XCTAssertFalse(sync.valid)
        let imported = try XCTUnwrap(VideoStabilization.load(frames:sourceFrames))
        XCTAssertEqual(imported.gyro.count,40);XCTAssertEqual(imported.gyroSource,"motion.gcsv")
        XCTAssertEqual(imported.steps,data.steps);XCTAssertEqual(imported.telemetryWarning,"")
    }
    func testVisionRegistrationDirectionAndBadTextureRejection() throws {
        let w = 640, h = 480, image = try texturedImage(width:w,height:h)
        let renderer = FrameRenderer.shared
        let expected = Mat3.similarity(12,-7,0.04)
        let xf = FrameXform(a:.zero,p:.zero,z:1,psi:0,valid:true,prewarp:expected.v)
        let warped = renderer.compose(source:CIImage(cgImage:image),sourceScale:1,originalHeight:Double(h),xform:xf,outW:w,outH:h,gains:[1,1,1],edgeFill:.black)
        let target = try XCTUnwrap(renderer.renderCGImage(warped))
        let (measured,quality) = VideoStabilization.imagePair(previous:image,current:target)
        XCTAssertGreaterThan(quality,0.65)
        XCTAssertEqual(measured.v[2],12,accuracy:1.2);XCTAssertEqual(measured.v[5],-7,accuracy:1.2)
        XCTAssertEqual(atan2(measured.v[3],measured.v[0]),0.04,accuracy:0.003)
        let blank = try XCTUnwrap(renderer.renderCGImage(CIImage(color:.gray).cropped(to:CGRect(x:0,y:0,width:w,height:h))))
        XCTAssertEqual(VideoStabilization.imagePair(previous:blank,current:blank).1,0)
    }
    func testRendererSamplesCombinedPerspectiveAndFramingAtProxyScale() throws {
        let w = 640, h = 480, image = try gradientImage(width:w,height:h), renderer = FrameRenderer.shared
        let matrix = Mat3([1.01,0.02,8,-0.01,0.99,-5,0.00008,-0.00004,1])
        let xf = FrameXform(a:V2(320,240),p:V2(160,120),z:0.5,psi:0.06,valid:true,prewarp:matrix.v)
        let result = renderer.compose(source:CIImage(cgImage:image),sourceScale:1,originalHeight:480,xform:xf,outW:320,outH:240,gains:[1,1,1],edgeFill:.black)
        let actual = rgba(renderer,result,width:320,height:240)
        for point in [V2(80.5,60.5),V2(160.5,120.5),V2(240.5,180.5)] {
            let source = xf.unmap(point), index = (Int(point.y)*320+Int(point.x))*4
            XCTAssertEqual(Double(actual[index]),source.x/Double(w)*255,accuracy:3)
            XCTAssertEqual(Double(actual[index+1]),source.y/Double(h)*255,accuracy:3)
        }
        let proxy = CIImage(cgImage:image).applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:0.5])
        let proxyResult = renderer.compose(source:proxy,sourceScale:0.5,originalHeight:480,xform:xf,outW:320,outH:240,gains:[1,1,1],edgeFill:.black)
        let proxyBytes = rgba(renderer,proxyResult,width:320,height:240)
        for point in [V2(80,60),V2(160,120),V2(240,180)] {
            let i = (Int(point.y)*320+Int(point.x))*4
            XCTAssertEqual(Int(actual[i]),Int(proxyBytes[i]),accuracy:2)
            XCTAssertEqual(Int(actual[i+1]),Int(proxyBytes[i+1]),accuracy:2)
        }
    }
    private func rgba(_ renderer: FrameRenderer, _ image: CIImage, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating:0,count:width*height*4)
        renderer.context.render(image,toBitmap:&bytes,rowBytes:width*4,bounds:CGRect(x:0,y:0,width:width,height:height),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        return bytes
    }
    private func gradientImage(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating:255,count:width*height*4)
        for y in 0..<height { for x in 0..<width { let i=(y*width+x)*4;bytes[i]=UInt8(Double(x)/Double(width)*255);bytes[i+1]=UInt8(Double(y)/Double(height)*255);bytes[i+2]=128 } }
        return try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:true,intent:.defaultIntent))
    }
    private func texturedImage(width: Int, height: Int) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(gray:0.12,alpha:1);ctx.fill(CGRect(x:0,y:0,width:width,height:height))
        var value: UInt64 = 109
        for _ in 0..<300 {
            value = value &* 6364136223846793005 &+ 1;let x = Int((value>>32)%UInt64(width-30))
            value = value &* 6364136223846793005 &+ 1;let y = Int((value>>32)%UInt64(height-30))
            value = value &* 6364136223846793005 &+ 1;let size = Int((value>>32)%20)+5
            ctx.setFillColor(gray:Double((value>>24)%200+55)/255,alpha:1);ctx.fillEllipse(in:CGRect(x:x,y:y,width:size,height:size))
        }
        return try XCTUnwrap(ctx.makeImage())
    }
}
