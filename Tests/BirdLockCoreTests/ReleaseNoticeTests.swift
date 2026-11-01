import XCTest
@testable import BirdLockCore

final class ReleaseNoticeTests:XCTestCase {
    func suite() -> UserDefaults {
        let name="BirdLock.NoticeTests."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        addTeardownBlock { defaults.removePersistentDomain(forName:name) };return defaults
    }
    func testFreshInstallIsSilentAndLaterUpgradeShowsOnce() {
        let d=suite();XCTAssertFalse(ReleaseNotice(defaults:d,current:"1.9.0").start())
        XCTAssertFalse(ReleaseNotice(defaults:d,current:"1.9.0").start())
        let next=ReleaseNotice(defaults:d,current:"1.9.1");XCTAssertTrue(next.start());next.acknowledge()
        XCTAssertFalse(ReleaseNotice(defaults:d,current:"1.9.1").start())
    }
    func testLegacy15SettingsNeedNoPreexistingVersionMarker() {
        let d=suite();d.set(Data("settings".utf8),forKey:"settings.v1");d.set("1.0",forKey:"agreement.accepted")
        let n=ReleaseNotice(defaults:d,current:"1.9.0");XCTAssertTrue(n.start())
        XCTAssertTrue(ReleaseNotice(defaults:d,current:"1.9.0").start());n.acknowledge()
        XCTAssertFalse(ReleaseNotice(defaults:d,current:"1.9.0").start())
    }
    func testLegacyConsentWithoutAnyPhotoEditsStillShowsNotes() {
        let d=suite();d.set("1.0",forKey:"agreement.accepted")
        XCTAssertTrue(ReleaseNotice(defaults:d,current:"1.9.0").start())
    }
    func testDowngradeDoesNotClaimUpgradeAndLegacyIsCapturedBeforeNewSettings() {
        let d=suite(),fresh=ReleaseNotice(defaults:d,current:"1.9.0")
        d.set(Data(),forKey:"settings.v1");d.set("1.0",forKey:"agreement.accepted")
        XCTAssertFalse(fresh.start());XCTAssertFalse(ReleaseNotice(defaults:d,current:"1.8.1").start())
    }
}
