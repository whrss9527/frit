import Foundation
import XCTest
@testable import FritCore

private struct ContentFixture: SyncContent {
    static let format = 3
    var values: [String]
    var isEmptyForSync: Bool { values.isEmpty }
    func merging(cloud: Self) -> Self {
        Self(values: cloud.values + values.filter { !cloud.values.contains($0) })
    }
}

// 模拟 Proxi 的 config 键和内层版本头，非真实用户导出。
private struct ConfigFixture: SyncContent {
    static let format = 3
    static let contentKey = "config"
    let format: Int
    var values: [String]
    var isEmptyForSync: Bool { values.isEmpty }
    init(format: Int = 1, values: [String]) { self.format = format; self.values = values }
    func merging(cloud: Self) -> Self { cloud }
    private enum CodingKeys: String, CodingKey { case format, values }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(Int.self, forKey: .format) ?? 1
        guard format <= Self.format else { throw SyncDocumentError.newerFormat(format) }
        values = try container.decode([String].self, forKey: .values)
    }
}

private struct InvalidKeyFixture: SyncContent {
    static let format = 1
    static let contentKey = "device"
    let value: String
    var isEmptyForSync: Bool { value.isEmpty }
    func merging(cloud: Self) -> Self { cloud }
}

final class SyncTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testContentAndLegacyConfigKeysRoundTripWithoutGlobalMutation() throws {
        let one = SyncDocument(updatedAt: date, device: "一号", content: ContentFixture(values: ["local"]))
        let two = SyncDocument(updatedAt: date, device: "二号", content: ConfigFixture(values: ["cloud"]))
        let dataOne = try one.encoded(), dataTwo = try two.encoded()
        let jsonOne = try XCTUnwrap(JSONSerialization.jsonObject(with: dataOne) as? [String: Any])
        let jsonTwo = try XCTUnwrap(JSONSerialization.jsonObject(with: dataTwo) as? [String: Any])
        XCTAssertNotNil(jsonOne["content"])
        XCTAssertNil(jsonOne["config"])
        XCTAssertNotNil(jsonTwo["config"])
        XCTAssertNil(jsonTwo["content"])
        XCTAssertEqual(jsonOne["updatedAt"] as? String, "2023-11-14T22:13:20Z")
        XCTAssertEqual(try SyncDocument<ContentFixture>.decode(dataOne), one)
        XCTAssertEqual(try SyncDocument<ConfigFixture>.decode(dataTwo), two)
    }

    func testMissingLegacyHeaderStaysVersionOneAndUsesCallerDeviceText() throws {
        let data = Data(#"{"content":{"values":["old"]}}"#.utf8)
        let value = try SyncDocument<ContentFixture>.decode(data, unknownDevice: "未知设备")
        XCTAssertEqual(value.format, 1)
        XCTAssertEqual(value.updatedAt, .distantPast)
        XCTAssertEqual(value.device, "未知设备")
        XCTAssertEqual(value.content.values, ["old"])
        XCTAssertEqual(try SyncDocument<ContentFixture>.decode(data).device, "")
        let legacy = try SyncDocument<ConfigFixture>.decode(Data(#"{"config":{"values":["legacy"]}}"#.utf8))
        XCTAssertEqual(legacy.format, 1)
        XCTAssertEqual(legacy.content.format, 1)
    }

    func testFutureOuterHeaderRejectsBeforeUnknownPayloadOrDateIsInterpreted() {
        let data = Data(#"{"format":4,"updatedAt":"future-date","content":"new-layout"}"#.utf8)
        XCTAssertThrowsError(try SyncDocument<ContentFixture>.decode(data)) {
            XCTAssertEqual($0 as? SyncDocumentError, .newerFormat(4))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(SyncDocument<ContentFixture>.self, from: data)) {
            XCTAssertEqual($0 as? SyncDocumentError, .newerFormat(4))
        }
    }

    func testFutureVersionCannotBeWrittenThroughEitherEncoderEntry() {
        let value = SyncDocument(format: 4, updatedAt: date, device: "Mac", content: ContentFixture(values: []))
        XCTAssertThrowsError(try value.encoded()) { XCTAssertEqual($0 as? SyncDocumentError, .newerFormat(4)) }
        XCTAssertThrowsError(try JSONEncoder().encode(value)) { XCTAssertEqual($0 as? SyncDocumentError, .newerFormat(4)) }
    }

    func testContentOwnedNestedFormatErrorIsPreserved() {
        let data = Data(#"{"format":1,"config":{"format":4,"values":"future-shape"}}"#.utf8)
        XCTAssertThrowsError(try SyncDocument<ConfigFixture>.decode(data)) {
            XCTAssertEqual($0 as? SyncDocumentError, .newerFormat(4))
        }
    }

    func testReservedPayloadKeyCannotOverwriteMetadata() {
        let value = SyncDocument(updatedAt: date, device: "Mac", content: InvalidKeyFixture(value: "x"))
        XCTAssertThrowsError(try value.encoded()) {
            XCTAssertEqual($0 as? SyncDocumentError, .invalidContentKey("device"))
        }
        XCTAssertThrowsError(try SyncDocument<InvalidKeyFixture>.decode(Data(#"{"format":1}"#.utf8))) {
            XCTAssertEqual($0 as? SyncDocumentError, .invalidContentKey("device"))
        }
    }

    func testMalformedKnownPayloadAndDatesFailInsteadOfBecomingEmptyContent() {
        for text in [#"{"format":1,"content":"broken"}"#,
                     #"{"format":1,"updatedAt":"not-a-date","content":{"values":[]}}"#,
                     #"{"format":1,"config":{"values":[]}}"#] {
            XCTAssertThrowsError(try SyncDocument<ContentFixture>.decode(Data(text.utf8)))
        }
    }

    func testNewestUsesTimeThenDeviceAndKeepsExactTieStable() {
        let old = SyncDocument(updatedAt: date, device: "Z", content: ContentFixture(values: ["old"]))
        let newer = SyncDocument(updatedAt: date.addingTimeInterval(1), device: "A", content: ContentFixture(values: ["new"]))
        let tie = SyncDocument(updatedAt: newer.updatedAt, device: "B", content: ContentFixture(values: ["tie"]))
        XCTAssertNil(SyncDocument<ContentFixture>.newest([]))
        XCTAssertEqual(SyncDocument.newest([newer, old]), newer)
        XCTAssertEqual(SyncDocument.newest([tie, newer]), tie)
        let sameDevice = SyncDocument(updatedAt: tie.updatedAt, device: "B", content: ContentFixture(values: ["other"]))
        XCTAssertEqual(SyncDocument.newest([tie, sameDevice]), tie)
    }

    func testThreeWayComparisonDoesNotUseTimestampsToInventEdits() {
        let base = ContentFixture(values: ["base"])
        let local = ContentFixture(values: ["local"])
        let remote = ContentFixture(values: ["remote"])
        XCTAssertFalse(SyncRules.shouldApply(remote: local, local: local, lastSynced: base))
        XCTAssertFalse(SyncRules.shouldApply(remote: base, local: local, lastSynced: base))
        XCTAssertTrue(SyncRules.shouldApply(remote: remote, local: local, lastSynced: base))
        XCTAssertTrue(SyncRules.shouldApply(remote: remote, local: local, lastSynced: nil))
        XCTAssertFalse(SyncRules.shouldPush(local: base, lastSynced: base))
        XCTAssertTrue(SyncRules.shouldPush(local: local, lastSynced: base))
        XCTAssertTrue(SyncRules.shouldPush(local: local, lastSynced: nil))
    }

    func testInitialChoiceRequiresDifferentNonemptyRemote() {
        let local = ContentFixture(values: ["local"])
        XCTAssertFalse(SyncRules.needsChoice(remote: nil, local: local))
        XCTAssertFalse(SyncRules.needsChoice(remote: local, local: local))
        XCTAssertFalse(SyncRules.needsChoice(remote: ContentFixture(values: []), local: local))
        XCTAssertTrue(SyncRules.needsChoice(remote: ContentFixture(values: ["remote"]), local: local))
    }

    func testConcurrentCodecsKeepKeysAndMissingDeviceTextIndependent() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let marker = "device-\(index)"
                    let one = try SyncDocument<ContentFixture>.decode(Data(#"{"content":{"values":[]}}"#.utf8), unknownDevice: marker)
                    let two = try SyncDocument<ConfigFixture>.decode(Data(#"{"config":{"values":[]}}"#.utf8), unknownDevice: marker)
                    XCTAssertEqual(one.device, marker)
                    XCTAssertEqual(two.device, marker)
                    XCTAssertEqual(try SyncDocument<ContentFixture>.decode(one.encoded()), one)
                    XCTAssertEqual(try SyncDocument<ConfigFixture>.decode(two.encoded()), two)
                }
            }
            try await group.waitForAll()
        }
    }
}
