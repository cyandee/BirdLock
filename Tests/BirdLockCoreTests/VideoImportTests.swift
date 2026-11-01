import XCTest
import AVFoundation
import CoreImage
@testable import BirdLockCore

final class VideoImportTests: XCTestCase {
    func testClipValidationBeforeDecodingAndSourceFrameRatePreview() throws {
        let info = VideoInfo(width:1920,height:1080,fps:24,duration:200)
        var options = VideoImportOptions();options.start=199;options.fps=60
        let clip = try VideoImporter.selection(info:info,options:options)
        XCTAssertEqual(clip.seconds,1);XCTAssertEqual(clip.fps,24);XCTAssertEqual(clip.count,24)
        options.start=200;XCTAssertThrowsError(try VideoImporter.selection(info:info,options:options))
        options.start=0;options.seconds=121;XCTAssertThrowsError(try VideoImporter.selection(info:info,options:options))
        options.seconds=1;options.fps = .nan;XCTAssertThrowsError(try VideoImporter.selection(info:info,options:options))
    }
    func testSilentVideoPresentationUsesOriginalURL() throws {
        let root = try temporary(),source = "/user/videos/C0320.MP4"
        let info = VideoSourceInfo(sourcePath:source,start:0,seconds:1,fps:30,count:1,audioFile:nil)
        try JSONEncoder().encode(info).write(to:root.appendingPathComponent("video-source.json"))
        let frame = SourceFrame(id:0,url:root.appendingPathComponent("video-000000.jpg"),pixelWidth:64,pixelHeight:48,captureTime:0,fileSize:0,modified:0,exif:ExifInfo())
        XCTAssertEqual(VideoSource.originalURL(frames:[frame])?.path,source)
        XCTAssertNil(VideoSource.originalURL(frames:[]))
    }
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }
    private func profile(_ root: URL, model: String = "opencv_fisheye", coefficients: [Double] = [0.02,-0.01,0,0]) throws -> URL {
        let url = root.appendingPathComponent("lens.json")
        let d: [String: Any] = ["name":"Test lens", "distortion_model":model, "calib_dimension":["w":64,"h":48],
            "fisheye_params":["camera_matrix":[[50.0,0,32],[0,50.0,24],[0,0,1.0]],"distortion_coeffs":coefficients]]
        try JSONSerialization.data(withJSONObject:d).write(to:url)
        return url
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return root
    }
    func testLensPixelsMatchOpenCVProjectionAndRejectInvalidProfiles() throws {
        let root = try temporary(), w = 64, h = 48
        var pixels = [UInt8](repeating:0,count:w*h*4)
        for y in 0..<h { for x in 0..<w {
            let i = (y*w+x)*4
            pixels[i] = UInt8(x*3);pixels[i+1] = UInt8(y*4);pixels[i+3] = 255
        } }
        let context = CIContext(options:[.workingColorSpace:NSNull(),.outputColorSpace:NSNull()])
        let image = CIImage(bitmapData:Data(pixels),bytesPerRow:w*4,size:CGSize(width:w,height:h),format:.RGBA8,colorSpace:nil)
        let lens = try LensProfile.load(profile(root))
        var corrected = pixels
        context.render(try lens.correct(image), toBitmap:&corrected,rowBytes:w*4,bounds:image.extent,format:.RGBA8,colorSpace:nil)
        // Independent OpenCV equidistant projection, in top-left pixel coordinates.
        let x = 10, y = 12, nx = (Double(x)-32)/50, ny = (Double(y)-24)/50
        let r = hypot(nx,ny), theta = atan(r), t2 = theta*theta
        let scale = theta*(1+0.02*t2-0.01*t2*t2)/r
        let u = 50*nx*scale+32, v = 50*ny*scale+24
        let offset = ((h-1-y)*w+x)*4
        XCTAssertEqual(Double(corrected[offset]),u*3,accuracy:2)
        XCTAssertEqual(Double(corrected[offset+1]),(Double(h-1)-v)*4,accuracy:2)
        let standard = try LensProfile.load(profile(root,model:"opencv_standard",coefficients:[0,0,0,0]))
        context.render(try standard.correct(image),toBitmap:&corrected,rowBytes:w*4,bounds:image.extent,format:.RGBA8,colorSpace:nil)
        XCTAssertEqual(corrected,pixels)
        XCTAssertThrowsError(try lens.validate(width:100,height:100))
        XCTAssertThrowsError(try LensProfile.load(profile(root,model:"gopro")))
    }
    private func video(_ root: URL, rotated: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(rotated ? "旋转.mov" : "飞鸟 片段.mov")
        let writer = try AVAssetWriter(outputURL:url,fileType:.mov)
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:64,AVVideoHeightKey:48])
        if rotated { input.transform = CGAffineTransform(a:0,b:1,c:-1,d:0,tx:48,ty:0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:64,kCVPixelBufferHeightKey as String:48])
        writer.add(input);XCTAssertTrue(writer.startWriting());writer.startSession(atSourceTime:.zero)
        for i in 0..<30 {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval:0.001) }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil,try XCTUnwrap(adaptor.pixelBufferPool),&buffer),kCVReturnSuccess)
            let pb = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pb,[])
            let bytes = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to:UInt8.self), row = CVPixelBufferGetBytesPerRow(pb)
            for y in 0..<48 { for x in 0..<64 { for c in 0..<4 { bytes[y*row+x*4+c] = c == 3 ? 255 : UInt8(i*3) } } }
            CVPixelBufferUnlockBaseAddress(pb,[])
            XCTAssertTrue(adaptor.append(pb,withPresentationTime:CMTime(value:Int64(i),timescale:30)))
        }
        input.markAsFinished();writer.endSession(atSourceTime:CMTime(value:1,timescale:1))
        let sem = DispatchSemaphore(value:0);writer.finishWriting { sem.signal() };sem.wait()
        XCTAssertEqual(writer.status,.completed,String(describing:writer.error))
        return url
    }
    func testVideoTrimSamplingCacheLensRotationAndCancellation() throws {
        let root = try temporary(), source = try video(root)
        let info = try VideoImporter.probe(source)
        XCTAssertEqual(info.width,64);XCTAssertEqual(info.height,48)
        var options = VideoImportOptions();options.start = 0.2;options.seconds = 0.6;options.fps = 15
        let cache = root.appendingPathComponent("cache")
        let result = try VideoImporter.extract(source,options:options,root:cache)
        XCTAssertEqual(result.frames.count,9);XCTAssertEqual(result.fps,15)
        XCTAssertEqual(result.frames.last!.captureTime!,8.0/15,accuracy:1e-9)
        XCTAssertTrue(result.frames.allSatisfy { ImageLoader.load($0.url) != nil })
        XCTAssertEqual(try VideoImporter.extract(source,options:options,root:cache).frames,result.frames)
        options.profile = try profile(root)
        let corrected = try VideoImporter.extract(source,options:options,root:cache)
        XCTAssertNotEqual(corrected.frames.first!.url,result.frames.first!.url)
        let flag = Flag(), aborted = root.appendingPathComponent("cancel")
        XCTAssertThrowsError(try VideoImporter.extract(source,options:options,root:aborted,progress:{ _ in flag.cancel() },isCancelled:{ flag.cancelled }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:aborted.path),[])
        let rotated = try video(root,rotated:true), rotatedInfo = try VideoImporter.probe(rotated)
        XCTAssertEqual(rotatedInfo.width,48);XCTAssertEqual(rotatedInfo.height,64)
        options.profile = nil
        let rotatedFrames = try VideoImporter.extract(rotated,options:options,root:cache).frames
        XCTAssertEqual(ImageLoader.load(rotatedFrames[0].url)?.width,48)
        XCTAssertEqual(ImageLoader.load(rotatedFrames[0].url)?.height,64)
    }
}
