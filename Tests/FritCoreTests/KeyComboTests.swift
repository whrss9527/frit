import Foundation
import XCTest
@testable import FritCore

final class KeyComboTests: XCTestCase {
    func testEveryModifierCombinationRoundTripsCarbonAndCodable() throws {
        for value in UInt32(0)..<16 {
            let modifiers = KeyModifiers(rawValue: value)
            XCTAssertEqual(KeyModifiers(carbonFlags: modifiers.carbonFlags), modifiers)
            let old = try JSONDecoder().decode(KeyModifiers.self, from: Data("\(modifiers.carbonFlags)".utf8))
            XCTAssertEqual(old, modifiers)
            let encoded = try JSONEncoder().encode(modifiers)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: UInt32])
            XCTAssertEqual(object, ["rawValue": value])
            XCTAssertEqual(try JSONDecoder().decode(KeyModifiers.self, from: encoded), modifiers)
        }
        XCTAssertEqual(KeyModifiers.command.carbonFlags, 0x100)
        XCTAssertEqual(KeyModifiers.shift.carbonFlags, 0x200)
        XCTAssertEqual(KeyModifiers.option.carbonFlags, 0x800)
        XCTAssertEqual(KeyModifiers.control.carbonFlags, 0x1000)
    }

    func testFourExistingSettingsShapes() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "key-combos", withExtension: "json", subdirectory: "Fixtures"))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let stox = try XCTUnwrap(settings["stox"] as? [String: Any])
        let proxi = try XCTUnwrap(settings["proxi"] as? [String: Any])
        let pop = try XCTUnwrap(settings["pop"] as? [String: Any])
        let meno = try XCTUnwrap(settings["meno"] as? [String: Any])
        let proxiKey = try XCTUnwrap(proxi["toggleHotkey"] as? [String: Any])
        let popKeys = try XCTUnwrap(pop["pluginHotKeys"] as? [[String: Any]])
        let popKey = try XCTUnwrap(popKeys.first?["key"] as? [String: Any])
        let menoHotkeys = try XCTUnwrap(meno["hotkeys"] as? [String: Any])
        let bindings = try XCTUnwrap(menoHotkeys["bindings"] as? [String: Any])
        let menoKey = try XCTUnwrap(bindings["quickOpen"] as? [String: Any])
        let cases: [([String: Any], KeyCombo)] = [
            (stox, KeyCombo(keyCode: 1, modifiers: [.control, .option])),
            (proxiKey, KeyCombo(keyCode: 35, modifiers: [.control, .option])),
            (popKey, KeyCombo(keyCode: 17, modifiers: .option)),
            (menoKey, KeyCombo(keyCode: 1, modifiers: [.control, .option])),
        ]
        for (object, expected) in cases {
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertEqual(try JSONDecoder().decode(KeyCombo.self, from: data), expected)
        }
        // 与原 App Codable 的两个数据形状比较，不借用新模型产生输入。
        struct CarbonBinding: Encodable { let keyCode: UInt32; let modifiers: UInt32; let display: String }
        struct CompactModifiers: Encodable { let rawValue: UInt32 }
        struct MenoBinding: Encodable { let keyCode: UInt32; let modifiers: CompactModifiers }
        let originalStox = CarbonBinding(keyCode: 1, modifiers: 6144, display: "⌃⌥S")
        let originalProxi = CarbonBinding(keyCode: 35, modifiers: 6144, display: "⌃⌥P")
        for binding in [originalStox, originalProxi] {
            XCTAssertEqual(try JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(binding)),
                           KeyCombo(keyCode: binding.keyCode, modifiers: [.control, .option]))
        }
        let originalMeno = MenoBinding(keyCode: 1, modifiers: CompactModifiers(rawValue: 3))
        XCTAssertEqual(try JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(originalMeno)), cases[3].1)
    }

    func testCompactScalarsCarbonObjectsAndMalformedValues() throws {
        let decoder = JSONDecoder()
        for text in ["3", "{\"rawValue\":3}", "6144", "{\"rawValue\":6144}"] {
            XCTAssertEqual(try decoder.decode(KeyModifiers.self, from: Data(text.utf8)), [.control, .option])
        }
        for text in ["-1", "4294967296", "null", "\"6144\"", "{}", "1.5"] {
            XCTAssertThrowsError(try decoder.decode(KeyModifiers.self, from: Data(text.utf8)))
        }
        // 忽略旧 display，包括不可信或过时的文字。
        let combo = try decoder.decode(KeyCombo.self, from: Data(#"{"keyCode":35,"modifiers":6144,"display":"outdated"}"#.utf8))
        XCTAssertEqual(combo.displayString(), "⌃⌥P")
    }

    func testGlobalShortcutRequirementsAndMacOSOptionRestriction() {
        XCTAssertNil(KeyCombo(keyCode: 0, modifiers: .command).problem(osMajorVersion: 26))
        XCTAssertEqual(KeyCombo(keyCode: 0, modifiers: []).problem(osMajorVersion: 26), .needsModifier)
        XCTAssertEqual(KeyCombo(keyCode: 0, modifiers: .shift).problem(osMajorVersion: 26), .needsModifier)
        XCTAssertNil(KeyCombo(keyCode: 0, modifiers: .shift).problem(osMajorVersion: 26, minimum: .any))
        XCTAssertNil(KeyCombo(keyCode: 0x7A, modifiers: []).problem(osMajorVersion: 26))
        XCTAssertEqual(KeyCombo(keyCode: 0x7A, modifiers: []).problem(osMajorVersion: 26, minimum: .commandOrControl), .needsCommandOrControl)
        for modifiers: KeyModifiers in [.option, [.option, .shift]] {
            let optionSpace = KeyCombo(keyCode: 0x31, modifiers: modifiers)
            XCTAssertNil(optionSpace.problem(osMajorVersion: 14))
            XCTAssertEqual(optionSpace.problem(osMajorVersion: 15), .needsCommandOrControl)
            XCTAssertEqual(optionSpace.problem(osMajorVersion: 14, minimum: .commandOrControl), .needsCommandOrControl)
        }
        XCTAssertNil(KeyCombo(keyCode: 0x31, modifiers: [.option, .control]).problem(osMajorVersion: 26))
        XCTAssertNil(KeyCombo(keyCode: 0x31, modifiers: [.option, .command]).problem(osMajorVersion: 26, minimum: .commandOrControl))
    }

    func testDisplayAndLayoutIndependentNames() {
        let combo = KeyCombo(keyCode: 0x2E, modifiers: [.command, .control, .option, .shift])
        XCTAssertEqual(combo.displayString(), "⌃⌥⇧⌘M")
        XCTAssertEqual(KeyCombo(keyCode: 0x2E, modifiers: .command).displayString(keyName: "Ь"), "⌘Ь")
        XCTAssertEqual(KeyCombo(keyCode: 999, modifiers: .option).displayString(), "⌥#999")
        for code: UInt32 in [0x7A, 0x78, 0x5A] {
            XCTAssertTrue(KeyCodeNames.isFunctionKey(code))
            XCTAssertTrue(KeyCodeNames.isLayoutIndependent(code))
        }
        XCTAssertFalse(KeyCodeNames.isFunctionKey(0x2E))
        XCTAssertFalse(KeyCodeNames.isLayoutIndependent(0x2E))
        XCTAssertTrue(KeyCodeNames.isLayoutIndependent(0x31))
        XCTAssertEqual(KeyCodeNames.name(for: 0x4C), "⌤")
        XCTAssertNil(KeyCodeNames.name(for: 999))
        XCTAssertEqual(Set([combo, combo]).count, 1)
    }
}
