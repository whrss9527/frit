import XCTest
@testable import FritCore

final class TolerantJSONTests: XCTestCase {
    private struct Settings: Codable, Equatable, Sendable {
        struct Section: Codable, Equatable, Sendable { var size = 24; var enabled = true }
        var section = Section()
        var optional: String? = "default"
        @LossyArray var numbers: [Int] = [1]
    }

    func testNestedDefaultsAndUnknownKeys() throws {
        let json = #"{"section":{"size":22,"future":true},"numbers":[2,"unknown",{},null,3]}"#
        let value = try TolerantJSON.decode(Settings.self, from: Data(json.utf8), defaults: Settings())
        XCTAssertEqual(value.section.size, 22)
        XCTAssertTrue(value.section.enabled)
        XCTAssertEqual(value.numbers, [2, 3])
        XCTAssertEqual(value.optional, "default")
    }

    /// Meno 的旧配置必须保留显式 null 和空数组。
    func testStoredNilOptionalsAndEmptyArraysStayEmpty() throws {
        let value = try TolerantJSON.decode(Settings.self, from: Data(#"{"optional":null,"numbers":[]}"#.utf8), defaults: Settings())
        XCTAssertNil(value.optional)
        XCTAssertEqual(value.numbers, [])
        let encoded = try TolerantJSON.makeEncoder().encode(value)
        XCTAssertEqual(try TolerantJSON.makeDecoder().decode(Settings.self, from: encoded), value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((object["numbers"] as? [Any])?.count, 0)
    }

    func testEnumCaseReplacementIsNotMerged() {
        let base: [String: Any] = ["action": ["revealHidden": [String: Any]()]]
        let stored: [String: Any] = ["action": ["applyScene": ["id": "X"]]]
        let merged = TolerantJSON.merge(base, stored) as? [String: Any]
        let action = merged?["action"] as? [String: Any]
        XCTAssertEqual(action?.keys.sorted(), ["applyScene"])
    }

    func testFutureOnlySectionCanKeepKnownDefaults() throws {
        let json = Data(#"{"section":{"future":1}}"#.utf8)
        XCTAssertThrowsError(try TolerantJSON.decode(Settings.self, from: json, defaults: Settings()))
        XCTAssertEqual(try TolerantJSON.decode(Settings.self, from: json, defaults: Settings(), mergeDisjointObjects: true), Settings())
    }
}
