#if os(macOS)
import AppKit
import Combine
import FritCore
import SwiftUI
import XCTest
@testable import FritUpdate

@MainActor
final class UpdateViewTests: XCTestCase {
    func testLanguageOverrideSwitchesWithoutChangingAppleLanguages() async throws {
        let before = UserDefaults.standard.object(forKey: "AppleLanguages") as? [String]
        defer { FritLocalization.languageOverride = nil }
        FritLocalization.languageOverride = "en-US"
        XCTAssertEqual(updateText("检查更新"), "Check for Updates")
        XCTAssertEqual(updateText("有新版本 %@", "2.0.0"), "New version 2.0.0")
        let englishError = UpdateError.checksumMismatch.localizedDescription
        FritLocalization.languageOverride = "zh-Hans"
        XCTAssertNotNil(FritLocalization.overriddenBundle(in: UpdateResources.bundle))
        XCTAssertEqual(updateText("检查更新"), "检查更新")
        XCTAssertEqual(updateText("有新版本 %@", "2.0.0"), "有新版本 2.0.0")
        XCTAssertNotEqual(UpdateError.checksumMismatch.localizedDescription, englishError)
        FritLocalization.languageOverride = "en"
        XCTAssertEqual(updateText("检查更新"), "Check for Updates")
        XCTAssertEqual(UserDefaults.standard.object(forKey: "AppleLanguages") as? [String], before)
        let revision = UpdateLanguage.shared.revision
        FritLocalization.languageOverride = "zh-Hans"
        for _ in 0..<20 where UpdateLanguage.shared.revision == revision { await Task.yield() }
        XCTAssertGreaterThan(UpdateLanguage.shared.revision, revision)
    }

    func testEveryStateBuildsBothViewsAndPreviewsHaveNoSideEffects() async throws {
        let version = GitHubRelease(tagName: "v2.0.0", htmlURL: URL(string: "https://github.com/test/sample/releases")!,
                                    assets: [], body: "### 新增\n- 测试 **更新**")
        let archive = GitHubRelease.Asset(name: "Sample.zip", downloadURL: URL(string: "https://github.com/test/sample/releases/download/v2.0.0/Sample.zip")!,
                                         size: 1_234_567, digest: "sha256:" + String(repeating: "a", count: 64))
        let item = UpdateCandidate(release: version, archive: archive, checksums: nil)
        var config = UpdateConfiguration(repository: "test/sample", appName: "Sample")
        config.bundleURL = URL(fileURLWithPath: "/Applications/Sample.app")
        config.sessions = { _ in [] }
        let states: [Updater.Phase] = [.idle, .checking, .upToDate, .skipped(item), .available(item),
            .downloading(item, nil), .downloading(item, 0.5), .verifying(item), .installing(item), .relaunching(item),
            .failed(item, .checksumMismatch), .failed(item, .appManagement)]
        for state in states {
            let updater = Updater.preview(configuration: config, phase: state)
            let host = NSHostingView(rootView: VStack {
                UpdateBanner(updater: updater, openDetails: {})
                UpdateSection(updater: updater, pageURLOpener: { _ in XCTFail("预览不应打开网址") })
            })
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
            host.layoutSubtreeIfNeeded()
            XCTAssertFalse(host.subviews.isEmpty)
            let candidate = await updater.check(manual: true)
            XCTAssertNil(candidate)
            updater.install()
            XCTAssertEqual(updater.phase, state)
        }
    }

    func testReleaseNotesRenderingKeepsMarkdownAndCleansLists() {
        XCTAssertEqual(UpdateReleaseNotes.cleaned("## 标题\r\n\n- **加粗**\n* 第二项"), "标题\n\n• **加粗**\n• 第二项")
        let text = UpdateReleaseNotes.attributed("- **更新**与[发布页](https://example.com)")
        XCTAssertEqual(String(text.characters), "• 更新与发布页")
    }
}
#endif
