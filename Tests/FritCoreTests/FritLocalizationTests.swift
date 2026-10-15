import Foundation
import XCTest
@testable import FritCore

final class FritLocalizationTests: XCTestCase {
    func testTraditionalPreferenceFallsBackWhenAModuleOnlyHasSimplifiedResources() throws {
        let previous = FritLocalization.languageOverride
        defer { FritLocalization.languageOverride = previous }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.frit.localization", "CFBundleName": "Test", "CFBundleDevelopmentRegion": "en"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Info.plist"))
        let simplified = root.appendingPathComponent("zh-hans.lproj")
        try FileManager.default.createDirectory(at: simplified, withIntermediateDirectories: true)
        try "\"test\" = \"简体\";\n".write(to: simplified.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        let bundle = try XCTUnwrap(Bundle(url: root))
        for language in ["zh-TW", "zh-HK", "zh-Hant", "zh_hant_HK"] {
            FritLocalization.languageOverride = language
            let selected = try XCTUnwrap(FritLocalization.overriddenBundle(in: bundle), language)
            XCTAssertEqual(selected.localizedString(forKey: "test", value: nil, table: nil), "简体", language)
        }
    }
}
