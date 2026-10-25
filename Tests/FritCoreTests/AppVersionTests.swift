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

    func testEqualPrereleasesWorkAsSetAndDictionaryKeys() throws {
        for (left, right) in [
            ("1.2-beta.01", "v1.2.0-beta.1+build.9"),
            ("0-rc.0002", "0.0.0-rc.2"),
            ("1.2-alpha.0001.test.02", "1.2.0-alpha.1.test.2"),
            ("1.2", "V1.2.0.0+build"),
        ] {
            let a = try XCTUnwrap(AppVersion(left))
            let b = try XCTUnwrap(AppVersion(right))
            XCTAssertEqual(a, b)
            XCTAssertEqual(a.hashValue, b.hashValue)
            XCTAssertTrue(Set([a]).contains(b))
            var dictionary = [a: "old"]
            XCTAssertEqual(dictionary[b], "old")
            dictionary[b] = "new"
            XCTAssertEqual(dictionary.count, 1)
            XCTAssertEqual(dictionary[a], "new")
        }
    }

    func testFoundationEquivalentSuffixesKeepTheirHashContract() throws {
        // 不同 Foundation 平台的 Unicode/数字等价关系可能不同；
        // 每个平台认为相等的版本都必须遵守同一哈希契约。
        let suffixes = ["beta.1", "beta.01", "beta.0001", "beta.١", "beta.１",
                        "é.1", "e\u{301}.01", "β.1", "β.0001",
                        "beta." + String(repeating: "0", count: 10_000) + "1"]
        let versions = try suffixes.map { try XCTUnwrap(AppVersion("2.3-" + $0)) }
        for a in versions {
            for b in versions where a == b {
                XCTAssertEqual(a.hashValue, b.hashValue)
                XCTAssertTrue(Set([a]).contains(b))
                XCTAssertEqual([a: 7][b], 7)
            }
        }
    }

    func testDifferentPrereleasesRemainDistinctAndOrdered() throws {
        let versions = try (1...64).map { try XCTUnwrap(AppVersion("3.4-beta.\($0)")) }
        let set = Set(versions)
        XCTAssertEqual(set.count, 64)
        for number in 1...64 {
            XCTAssertTrue(set.contains(try XCTUnwrap(AppVersion("3.4.0-beta.000\(number)"))))
        }
        XCTAssertEqual(versions.sorted(), versions)
        XCTAssertLessThan(versions.last!, try XCTUnwrap(AppVersion("3.4")))
        XCTAssertEqual(AppVersion("3.4-beta.0001")?.description, "3.4-beta.0001")
    }
}
