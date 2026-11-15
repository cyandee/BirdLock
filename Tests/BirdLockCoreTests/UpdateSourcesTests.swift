import XCTest
@testable import BirdLockCore

final class UpdateSourcesTests:XCTestCase {
    let mirror="https://3rd.0x01.page/birdlock/update-api/"
    let prefix="https://github.com/cyandee/BirdLock/releases/download/"
    func suite() -> UserDefaults {
        let name="BirdLock.UpdateSourcesTests."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        addTeardownBlock { defaults.removePersistentDomain(forName:name) };return defaults
    }
    func testBaseURLRules() throws {
        XCTAssertEqual(try UpdateSource.base(" https://Mirror.Test/a/b "),"https://mirror.test/a/b/")
        XCTAssertEqual(try UpdateSource.base(mirror),mirror)
        for bad in ["http://mirror.test/","https://u:p@mirror.test/","https://mirror.test/?x=1","https://mirror.test/#a","mirror.test","https:///path","",
                    "https://mirror:8o8o/","https://host:99999/x","https://exa mple.com/","https://%zz/"] {
            XCTAssertThrowsError(try UpdateSource.base(bad),bad)
        }
    }
    func testFeedAndAssetMapping() throws {
        let source=try UpdateSource.custom(mirror),github=UpdateSource.github
        XCTAssertEqual(source.name,"3rd.0x01.page")
        XCTAssertEqual(source.feedURL(githubFeed:"https://raw.test/macos.xml"),mirror+"macos.xml")
        XCTAssertEqual(github.feedURL(githubFeed:"https://raw.test/macos.xml"),"https://raw.test/macos.xml")
        let asset=URL(string:prefix+"v1.5.0-beta.1/BirdLock-1.5.0-macOS-update.zip")!
        XCTAssertEqual(source.assetURL(asset,releasePrefix:prefix)?.absoluteString,mirror+"download/v1.5.0-beta.1/BirdLock-1.5.0-macOS-update.zip")
        XCTAssertEqual(github.assetURL(asset,releasePrefix:prefix),asset)
        XCTAssertNil(source.assetURL(URL(string:"https://elsewhere.test/a.zip")!,releasePrefix:prefix))
        XCTAssertNil(source.assetURL(asset,releasePrefix:nil))
    }
    func testShippedDefaultsAndOverrides() throws {
        let info:[String:Any]=["BirdLockUpdateSources":[["id":"github","name":"GitHub"],["name":"镜像","url":"https://3rd.0x01.page/birdlock/update-api"],["url":"http://bad.test/"]]]
        let d=suite(),list=UpdateSourceList(store:d,info:info)
        XCTAssertEqual(list.defaults,[.github,UpdateSource(name:"镜像",url:mirror)])
        XCTAssertEqual(UpdateSourceList(store:d,info:nil).defaults,[.github])
        var custom=[list.defaults[1],list.defaults[0],try UpdateSource.custom("https://extra.test/u"),list.defaults[1]]
        list.sources=custom;custom.removeLast()
        XCTAssertEqual(list.sources,custom);XCTAssertTrue(list.isCustom)
        XCTAssertEqual(UpdateSourceList(store:d,info:info).sources,custom,"saved order survives relaunch")
        list.sources=list.defaults;XCTAssertFalse(list.isCustom);XCTAssertEqual(list.sources,list.defaults)
        list.sources=[];XCTAssertEqual(list.sources,list.defaults,"an empty list falls back to defaults")
        d.set(Data("not json".utf8),forKey:"updates.sources");XCTAssertEqual(list.sources,list.defaults)
        list.sources=(0..<15).map { UpdateSource(name:"m\($0)",url:"https://m\($0).test/") }
        XCTAssertEqual(list.sources.count,UpdateSourceList.maximum)
    }
    func testProbeKeepsListOrderWithoutWaitingForLaterSources() async throws {
        let a=UpdateSource.github,b=try UpdateSource.custom("https://b.test/"),c=try UpdateSource.custom("https://c.test/")
        let delays:[String:UInt64]=["GitHub":200,"b.test":10,"c.test":5_000]
        let pass:Set<String>=["GitHub","b.test","c.test"]
        let started=Date()
        let first=await UpdateSourceProbe.firstReachable([a,b,c]) { s in try? await Task.sleep(nanoseconds:delays[s.name]!*1_000_000);return pass.contains(s.name) }
        XCTAssertEqual(first,a,"a slower earlier source still wins");XCTAssertLessThan(Date().timeIntervalSince(started),3,"later sources are cancelled")
        let second=await UpdateSourceProbe.firstReachable([a,b,c]) { s in s.name != "GitHub" }
        XCTAssertEqual(second,b)
        let none=await UpdateSourceProbe.firstReachable([a,b]) { _ in false }
        XCTAssertNil(none)
    }
    func testFirstEnclosureIsReadFromTheAppcast() {
        let feed="<item><enclosure length=\"1\" url=\"https://github.com/cyandee/BirdLock/releases/download/v1.10.0/A.zip?x=1&amp;y=2\" type=\"application/octet-stream\"/></item>"
        XCTAssertEqual(UpdateSourceProbe.firstEnclosure(feed)?.absoluteString,"https://github.com/cyandee/BirdLock/releases/download/v1.10.0/A.zip?x=1&y=2")
        XCTAssertNil(UpdateSourceProbe.firstEnclosure("<item/>"))
    }
}
