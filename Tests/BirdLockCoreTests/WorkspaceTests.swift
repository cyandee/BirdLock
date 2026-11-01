import XCTest
import CoreImage
@testable import BirdLockCore

final class WorkspaceTests: XCTestCase {
    private func temporary() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) };return root
    }
    private func example(_ root:URL) throws -> WorkspaceDocument {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var frames:[SourceFrame]=[]
        let image=try XCTUnwrap(FrameRenderer.shared.renderCGImage(CIImage(color:.gray).cropped(to:CGRect(x:0,y:0,width:64,height:48))))
        for i in 0..<6 {
            let file=root.appendingPathComponent("鸟 \(i).jpg");XCTAssertTrue(ImageLoader.writeJPEG(image,to:file))
            let size=try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            frames.append(SourceFrame(id:i,url:file,pixelWidth:64,pixelHeight:48,captureTime:Double(i)/30,fileSize:size,modified:1,exif:ExifInfo()))
        }
        var a=SequenceAnalysis(fingerprint:Analyzer.fingerprint(frames),frames:frames,fps:30,proxyLongSide:64,perFrame:(0..<6).map { i in
            var frame=FrameAnalysis(index:i);frame.birds=[BoxD(x:10,y:10,w:30,h:20,score:0.9)];frame.target=0;return frame
        },poseSchema:.cub15)
        a.manualEye=[2:V2(26.25,21.5)];a.excluded=[1]
        var shot=Closeup();shot.frame=3;shot.endFrame=4;shot.seconds=0.5;shot.zoom=2;a.closeups=[shot]
        var selection=FrameSelection();selection.trimStart=1;selection.trimEnd=5
        var look=LookSettings();look.stabilization.maxZoom=6
        let profile=SubjectProfile(composition:Composition(),look:look,export:ExportSettings(),selection:selection,presetID:"lead")
        return try WorkspaceDocument(frames:frames,segments:[BurstSegment(range:0..<6,fps:30)],analysis:a,remembered:[],subject:.bird,
            profile:profile,profiles:["bird":profile],audio:AudioSettings(),watermark:WatermarkSettings(),segmentIndex:0,mergeGroups:[0],currentFrame:3,viewMode:"source",sourceZoom:4,previewAudio:true)
    }
    func testProjectAndEditsSurviveDisposableProxyCleanup() throws {
        let root=try temporary(),cache=ProxyCache(root:root.appendingPathComponent("cache")),file=root.appendingPathComponent("工程.birdlock")
        let document=try example(root.appendingPathComponent("素材"));try document.save(to:file,cacheRoot:cache.root)
        let restored=try WorkspaceDocument.read(from:file).restoreMedia(cache:cache)
        let analysis=restored.analyses[0]
        XCTAssertEqual(analysis.manualEye[2],V2(26.25,21.5));XCTAssertEqual(analysis.excluded,[1])
        XCTAssertEqual(analysis.closeups?.first?.endFrame,4);XCTAssertEqual(restored.profile.selection.trimEnd,5)
        XCTAssertEqual(restored.profile.look.stabilization.maxZoom,6)
        XCTAssertNotNil(cache.loadProxy(fingerprint:analysis.fingerprint,index:2))
        let record=cache.root.appendingPathComponent(analysis.fingerprint).appendingPathComponent("analysis.json"),before=try Data(contentsOf:record)
        let cleanup=CachePolicy.clean(root:cache.root)
        XCTAssertGreaterThan(cleanup.removed,0);XCTAssertEqual(try Data(contentsOf:record),before)
        XCTAssertNotNil(cache.loadAnalysis(fingerprint:analysis.fingerprint));XCTAssertNotNil(cache.loadProxy(fingerprint:analysis.fingerprint,index:2))
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
    }
    func testRelocationAndSchemaValidationAreExplicit() throws {
        let root=try temporary(),file=root.appendingPathComponent("工程.birdlock"),old=root.appendingPathComponent("old"),new=root.appendingPathComponent("new")
        let document=try example(old);try document.save(to:file,cacheRoot:root.appendingPathComponent("cache"))
        try FileManager.default.moveItem(at:old,to:new)
        XCTAssertThrowsError(try WorkspaceDocument.read(from:file))
        let relocated=try WorkspaceDocument.read(from:file,relocation:new)
        XCTAssertEqual(relocated.frames[0].url.deletingLastPathComponent().path,new.path)
        var bad=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any]);bad["schema"]=999
        try JSONSerialization.data(withJSONObject:bad).write(to:file)
        XCTAssertThrowsError(try WorkspaceDocument.read(from:file))
    }
    func testDocumentsCannotBeSavedInsideDisposableCache() throws {
        let root=try temporary(),cache=root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
        let doc=try example(root.appendingPathComponent("media"))
        XCTAssertThrowsError(try doc.save(to:cache.appendingPathComponent("project.birdlock"),cacheRoot:cache))
    }
    func testQuotaKeepsActiveAndOriginalFilesAndNeverFollowsSymlink() throws {
        let root=try temporary(),cache=root.appendingPathComponent("cache"),video=cache.appendingPathComponent("video-imports").appendingPathComponent(String(repeating:"a",count:32))
        try FileManager.default.createDirectory(at:video,withIntermediateDirectories:true)
        let source=root.appendingPathComponent("source.mp4");try Data("original".utf8).write(to:source)
        let recipe=VideoRecipe(sourcePath:source.path,bytes:8,modified:1,width:64,height:48,start:0,seconds:1,fps:1,count:1,lensJSON:nil)
        try JSONEncoder().encode(recipe).write(to:video.appendingPathComponent("video-recipe.json"))
        let frame=video.appendingPathComponent("video-000000.jpg");try Data(repeating:1,count:1000).write(to:frame)
        let lease=CachePolicy.beginOperation(root:cache)
        XCTAssertEqual(CachePolicy.clean(root:cache).removed,0)
        CachePolicy.endOperation(lease)
        let protected=CachePolicy.clean(root:cache,protected:[video.path])
        XCTAssertTrue(protected.overLimit);XCTAssertTrue(FileManager.default.fileExists(atPath:frame.path))
        let outside=root.appendingPathComponent("outside");try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        try Data("keep".utf8).write(to:outside.appendingPathComponent("video-000000.jpg"))
        try FileManager.default.createSymbolicLink(at:video.deletingLastPathComponent().appendingPathComponent(String(repeating:"b",count:32)),withDestinationURL:outside)
        let cleanup=CachePolicy.clean(root:cache)
        XCTAssertGreaterThan(cleanup.removed,0);XCTAssertTrue(FileManager.default.fileExists(atPath:video.appendingPathComponent(".evicted.json").path))
        XCTAssertEqual(try Data(contentsOf:source),Data("original".utf8));XCTAssertEqual(try Data(contentsOf:outside.appendingPathComponent("video-000000.jpg")),Data("keep".utf8))
    }
}
