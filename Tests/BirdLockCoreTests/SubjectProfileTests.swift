import XCTest
@testable import BirdLockCore

final class SubjectProfileTests: XCTestCase {
    func testAircraftDefaultsPreserveIndependentBirdAndShutterChoices() {
        var composition = Composition();composition.anchorX = 0.36
        var export = ExportSettings();export.focusMark.captureFlash = true;export.focusMark.captureColor = .white;export.focusMark.headColor = .orange
        var selection = FrameSelection();selection.trimStart = 8
        let bird = SubjectProfile(composition: composition,look: LookSettings(),export: export,selection: selection,presetID: "lead")
        var plane = SubjectProfile.initialAircraft(from: bird)
        XCTAssertEqual(plane.composition.lockPoint,.headCenter);XCTAssertEqual(plane.export.aspect.value,16.0/9,accuracy: 1e-9)
        XCTAssertFalse(plane.export.focusMark.showEye);XCTAssertTrue(plane.export.focusMark.showHead);XCTAssertTrue(plane.export.focusMark.showBody)
        XCTAssertTrue(plane.export.focusMark.captureFlash);XCTAssertEqual(plane.export.focusMark.captureColor,.white)
        XCTAssertEqual(plane.selection.trimStart,0);XCTAssertNil(plane.selection.trimEnd)
        plane.composition.anchorX = 0.8;plane.export.focusMark.headColor = .black
        XCTAssertEqual(bird.composition.anchorX,0.36);XCTAssertEqual(bird.export.focusMark.headColor,.orange);XCTAssertEqual(bird.selection.trimStart,8)
    }

    func testNestedProfileRestoresAndMissingFieldsKeepDefaults() throws {
        var profile = SubjectProfile(composition: Composition(),look: LookSettings(),export: ExportSettings(),selection: FrameSelection(),presetID: nil)
        profile.export.focusMark.bodySize = 2.1
        let restored = try JSONDecoder().decode(SubjectProfile.self,from: JSONEncoder().encode(profile))
        XCTAssertEqual(restored.export.focusMark.bodySize,2.1)
        let old = try JSONDecoder().decode(SubjectProfile.self,from: Data(#"{"composition":{"anchorX":0.4},"export":{"focusMark":{"color":"white"}}}"#.utf8))
        XCTAssertEqual(old.composition.anchorX,0.4);XCTAssertEqual(old.export.focusMark.headColor,.white)
    }

    func testPresetRegistriesStaySeparate() {
        XCTAssertEqual(CompositionPreset.forSubject(.bird).first?.id,"center")
        XCTAssertEqual(CompositionPreset.forSubject(.aircraft)[1].id,"aircraft-lead")
        XCTAssertTrue(CompositionPreset.forSubject(.aircraft).allSatisfy { $0.composition.lockPoint == .headCenter })
    }
}
