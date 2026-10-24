import XCTest
@testable import CalendarSyncCore

final class UpdateCheckTests: XCTestCase {
    func testNumericDottedComparison() {
        XCTAssertTrue(UpdateCheck.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertTrue(UpdateCheck.isNewer("0.10.0", than: "0.9.9"), "components compare as numbers, not text")
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "0.99.99"))
    }

    func testTagPrefixSuffixAndMissingComponents() {
        XCTAssertTrue(UpdateCheck.isNewer("v0.2.0", than: "0.1.0"), "release tags start with v")
        XCTAssertFalse(UpdateCheck.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.2.0", than: "1.2"))
        XCTAssertFalse(UpdateCheck.isNewer("0.2.0-beta", than: "0.2.0"), "pre-release suffixes are ignored")
        XCTAssertTrue(UpdateCheck.isNewer("0.2.1-beta", than: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("", than: "0.1.0"), "an empty version is never an update")
        XCTAssertFalse(UpdateCheck.isNewer("not a version", than: "0.1.0"))
    }

    func testParsesTheLatestReleaseResponse() throws {
        let json = #"{"tag_name":"v0.3.0","html_url":"https://github.com/neteinstein/Calendar-Sync/releases/tag/v0.3.0","name":"Calendar view"}"#
        let latest = try XCTUnwrap(UpdateCheck.latest(fromReleaseJSON: Data(json.utf8)))
        XCTAssertEqual(latest.version, "v0.3.0")
        XCTAssertEqual(latest.url?.absoluteString, "https://github.com/neteinstein/Calendar-Sync/releases/tag/v0.3.0")
        XCTAssertTrue(UpdateCheck.isNewer(latest.version, than: "0.1.0"))

        XCTAssertNil(UpdateCheck.latest(fromReleaseJSON: Data(#"{"message":"Not Found"}"#.utf8)),
                     "a repo without releases answers 404 with no tag_name")
        XCTAssertNil(UpdateCheck.latest(fromReleaseJSON: Data("not json".utf8)))
    }

    func testReadsTheVersionFromAnInfoPlist() throws {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleName</key><string>Calendar Sync</string>
                <key>CFBundleShortVersionString</key><string>0.4.2</string>
            </dict>
            </plist>
            """
        XCTAssertEqual(UpdateCheck.version(fromInfoPlist: Data(plist.utf8)), "0.4.2")
        XCTAssertNil(UpdateCheck.version(fromInfoPlist: Data("junk".utf8)))
    }
}
