import XCTest
@testable import FritCore

final class AppVersionTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(AppVersion("0.2.1")?.components, [0, 2, 1])
        XCTAssertEqual(AppVersion("v1.10")?.components, [1, 10])
        XCTAssertEqual(AppVersion(" V2.0.0-beta.1 ")?.components, [2, 0, 0])
        XCTAssertEqual(AppVersion(" V2.0.0-beta.1 ")?.prerelease, "beta.1")
        XCTAssertEqual(AppVersion("3.1+build.7")?.description, "3.1")
        XCTAssertEqual(AppVersion("3.1.0-rc.2+build.7")?.description, "3.1.0-rc.2")
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertNil(AppVersion("1.-2"))
        XCTAssertNil(AppVersion("1.2-"))
    }

    func testOrdering() throws {
        let versions = ["0.1.4", "0.2.0-beta.1", "0.2.0-beta.2", "0.2.0-beta.10", "0.2.0", "0.2.1", "0.10.0", "1.0"]
            .compactMap(AppVersion.init)
        XCTAssertEqual(versions.count, 8)
        XCTAssertEqual(versions, versions.sorted())
        XCTAssertLessThan(try XCTUnwrap(AppVersion("0.9.9")), try XCTUnwrap(AppVersion("0.10")))
        XCTAssertEqual(AppVersion("1.2"), AppVersion("v1.2.0"))
        XCTAssertEqual(Set([AppVersion("1.2"), AppVersion("1.2.0")]).count, 1)
        XCTAssertFalse(try XCTUnwrap(AppVersion("0.2.0")) < XCTUnwrap(AppVersion("0.2")))
    }

    func testIsNewer() {
        XCTAssertTrue(AppVersion.isNewer("v0.45.0", than: "0.44.2"))
        XCTAssertTrue(AppVersion.isNewer("0.4.0", than: "0.4.0-beta.3"))
        XCTAssertFalse(AppVersion.isNewer("0.4.0-beta.3", than: "0.4.0"))
        XCTAssertFalse(AppVersion.isNewer("0.4.0", than: "0.4.0"))
        XCTAssertFalse(AppVersion.isNewer("latest", than: "0.1.0"))
    }
}
