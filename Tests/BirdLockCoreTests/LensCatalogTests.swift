import XCTest
@testable import BirdLockCore

final class LensCatalogTests: XCTestCase {
    func testDatabaseSearchUnderstandsCameraLensAndChineseBrands() throws {
        let catalog=try LensCatalog.entries()
        XCTAssertFalse(LensCatalog.search("索尼 FX3",in:catalog).isEmpty)
        XCTAssertTrue(LensCatalog.search("no-such-camera-xyz",in:catalog).isEmpty)
        XCTAssertTrue(LensCatalog.search("SONY",in:catalog).contains { $0.cameraBrand == "Sony" })
    }
    func testEmbeddedTelemetryIdentityAndExplicitGoProModes() throws {
        var raw: [String:Any] = ["schema":1,"parser":"GoPro","cameraBrand":"GoPro","cameraModel":"HERO11 Black",
            "gyroUnit":"rad/s","timestampUnit":"s","orientation":"XYZ","imuFrame":"gyroflow-x-up-y-left-z-back",
            "cameraFrame":"opencv-x-right-y-down-z-forward","imuToCamera":[[0,-1,0],[-1,0,0],[0,0,-1]],
            "metadataFrameCount":1,"gyroscopeFrameCount":0,"timestampsAccurate":true,"sonyPacketTimed":false,
            "partial":true,"samples":[],"warnings":[],"video":["fps":119.88],
            "rawMetadataFrames":[["Default":["0x56464f56":"W","0x45495341":"N"]]]]
        func metadata() throws -> CameraMetadata {
            CameraMetadata.fromTelemetry(try TelemetryReport.decode(JSONSerialization.data(withJSONObject:raw)))
        }
        var camera = try metadata()
        XCTAssertEqual(camera.cameraModel,"HERO11 Black");XCTAssertEqual(camera.lensModel,"Wide")
        XCTAssertEqual(try LensCatalog.match(camera,width:3840,height:2160,fps:119.88).selected?.id,"gopro-hero11-wide-4k120")
        raw["rawMetadataFrames"] = [["Default":["0x56464f56":"W"]]]
        camera = try metadata()
        XCTAssertNil(try LensCatalog.match(camera,width:3840,height:2160,fps:119.88).selected)
        raw["cameraBrand"] = "DJI";raw["cameraModel"] = "DJI Mini 3 Pro";raw["rawMetadataFrames"] = []
        camera = try metadata()
        XCTAssertEqual(try LensCatalog.match(camera,width:1920,height:1080,fps:29.97).selected?.id,"dji-mini3pro-1080p30")
    }
    private func xml(camera: String = "ILCE-1M2", lens: String = "FE 600mm F4 GM OSS", fps: String = "119.88") -> Data {
        // Relevant supplied C0320M01.XML fields, omitting serial numbers, UMID and timestamps.
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20">
        <VideoFormat><VideoFrame captureFps="\(fps)p" formatFps="\(fps)p"/>
        <VideoLayout pixel="3840" numOfVerticalLine="2160" aspectRatio="16:9"/></VideoFormat>
        <Device manufacturer="Sony" modelName="\(camera)" serialNo="ignored"/><Lens modelName="\(lens)"/>
        <AcquisitionRecord><ChangeTable name="Gyroscope"><Event frameCount="0" status="none"/></ChangeTable>
        <ChangeTable name="DistortionCorrection"><Event frameCount="0" status="none"/></ChangeTable></AcquisitionRecord>
        </NonRealTimeMeta>
        """.utf8)
    }
    func testRealProfilesAndSourceIntegrity() throws {
        let entries = try LensCatalog.entries()
        XCTAssertEqual(entries.count,383)
        for entry in entries {
            XCTAssertTrue(entry.sourceURL.contains("/886fc616c9c2c788856f54c21d451b9cb7fc4f44/"))
            let profile = try LensProfile.load(entry.url)
            try profile.validate(width: entry.width,height: entry.height)
        }
        let root = try XCTUnwrap(LensCatalog.directory)
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("CC0-1.0.txt"),encoding:.utf8).contains("CC0 1.0 Universal"))
    }
    func testSuppliedSonyXMLRecognizesIdentityWithoutPretendingToBeCalibration() throws {
        let data: Data
        if let path = ProcessInfo.processInfo.environment["BIRDLOCK_TEST_SONY_XML"] { data = try Data(contentsOf: URL(fileURLWithPath:path)) }
        else { data = xml() }
        let camera = try CameraMetadata.parseSonyXML(data)
        XCTAssertEqual(camera.cameraModel,"ILCE-1M2");XCTAssertEqual(camera.lensModel,"FE 600mm F4 GM OSS")
        XCTAssertEqual(camera.cameraBrand,"Sony");XCTAssertEqual(camera.width,3840);XCTAssertEqual(camera.height,2160)
        XCTAssertEqual(camera.fps,119.88);XCTAssertNil(camera.focalLength)
        let result = try LensCatalog.match(camera,width:3840,height:2160,fps:119.88)
        XCTAssertNil(result.selectedURL);XCTAssertTrue(result.candidates.isEmpty)
        let encoded = try JSONEncoder().encode(camera)
        XCTAssertFalse(String(decoding:encoded,as:UTF8.self).contains("serialNo"))
    }
    func testMatchRequiresCameraLensFocalModeAndGeometry() throws {
        var prime = CameraMetadata(cameraBrand:"Sony",cameraModel:"ILME-FX3",lensModel:"FE 24mm F1.4 GM")
        XCTAssertEqual(try LensCatalog.match(prime,width:3840,height:2160,fps:25).selected?.id,"sony-fx3-fe24gm-4k25")
        XCTAssertNil(try LensCatalog.match(prime,width:1920,height:1080,fps:25).selected)
        XCTAssertNil(try LensCatalog.match(prime,width:3840,height:2160,fps:59.94).selected)
        XCTAssertNil(try LensCatalog.match(prime,width:3840,height:2160,fps:0).selected)
        XCTAssertNil(try LensCatalog.match(prime,width:3840,height:0,fps:25).selected)
        prime.stabilizationMode = "Active"
        XCTAssertNil(try LensCatalog.match(prime,width:3840,height:2160,fps:25).selected)
        prime.stabilizationMode = ""
        prime.cameraSetting = "APS-C"
        XCTAssertNil(try LensCatalog.match(prime,width:3840,height:2160,fps:25).selected)
        var zoom = CameraMetadata(cameraModel:"ILCE-7M4",lensModel:"Sigma 28-70mm 2.8")
        XCTAssertNil(try LensCatalog.match(zoom,width:3840,height:2160,fps:25).selected)
        zoom.focalLength = 28
        XCTAssertEqual(try LensCatalog.match(zoom,width:3840,height:2160,fps:25).selected?.id,"sony-a7iv-sigma28-70-28-4k25")
        zoom.variableFocalLength = true
        XCTAssertNil(try LensCatalog.match(zoom,width:3840,height:2160,fps:25).selected)
        var gopro = CameraMetadata(cameraModel:"HERO11 Black",lensModel:"Wide")
        XCTAssertNil(try LensCatalog.match(gopro,width:3840,height:2160,fps:119.88).selected)
        gopro.stabilizationMode = "off"
        XCTAssertEqual(try LensCatalog.match(gopro,width:3840,height:2160,fps:119.88).selected?.id,"gopro-hero11-wide-4k120")
    }
    func testCaseInsensitiveSidecarReferenceAndMalformedXML() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let video = root.appendingPathComponent("C0320.MP4"), sidecar = root.appendingPathComponent("c0320m01.xml")
        try Data().write(to:video);try xml().write(to:sidecar)
        XCTAssertEqual(try CameraMetadata.forVideo(video).cameraModel,"ILCE-1M2")
        XCTAssertEqual(try LensCatalog.importXML(sidecar).metadata.lensModel,"FE 600mm F4 GM OSS")
        XCTAssertThrowsError(try LensProfile.load(sidecar))
        try xml(camera:"ILME-FX3",lens:"FE 24mm F1.4 GM",fps:"25").write(to:sidecar)
        XCTAssertEqual(try LensProfile.load(sidecar).coefficients.count,4)
        XCTAssertThrowsError(try CameraMetadata.parseSonyXML(Data("<!DOCTYPE x [<!ENTITY y SYSTEM 'file:///etc/passwd'>]><NonRealTimeMeta/>".utf8)))
        XCTAssertThrowsError(try CameraMetadata.parseSonyXML(Data("<not-sony/>".utf8)))
    }
}
