import XCTest
@testable import FritCore

final class ReleaseNotesTests: XCTestCase {
    func testBilingualNotesSelectTheInterfaceLanguage() {
        let notes = "## 更新内容\n\n### 中文\n- 价格提醒：改进\n\n### English\n- Price alerts: improved\n\n## 安装\n下载\n## Installation\nDownload"
        XCTAssertEqual(ReleaseNotes.highlights(notes, style: .stox(language: .chinese)), "- 价格提醒：改进")
        XCTAssertEqual(ReleaseNotes.highlights(notes, style: .stox(language: .english)), "- Price alerts: improved")
    }

    func testEnglishFallsBackToChineseForOldOrEmptyTranslations() {
        XCTAssertEqual(ReleaseNotes.highlights("## 更新内容\n- 同步改进", style: .stox(language: .english)), "- 同步改进")
        XCTAssertEqual(ReleaseNotes.highlights("## 更新内容\n### 中文\n- 同步改进\n### English\n  ", style: .stox(language: .english)), "- 同步改进")
        XCTAssertEqual(ReleaseNotes.highlights("## Installation\nDownload", style: .stox(language: .english)), "")
        XCTAssertEqual(ReleaseNotes.highlights("## 更新内容\r\n### English\r\n- Fixed", style: .stox(language: .chinese)), "- Fixed")
    }

    func testKeepsOnlyTheHighlights() {
        let notes = """
        ## 更新内容

        - 五日分时
        - 键盘操作

        ## 安装

        1. 下载 Stox.zip
        2. 拖进应用程序

        ## What's Changed
        * Add a five-day intraday chart by @whrss9527 in https://github.com/whrss9527/stox/pull/13

        **Full Changelog**: https://github.com/whrss9527/stox/compare/v0.10.0...v0.11.0
        """
        XCTAssertEqual(ReleaseNotes.highlights(notes), "- 五日分时\n- 键盘操作")
    }

    func testOlderNotesDropInstallSteps() {
        let notes = "## 安装\r\n\r\n1. 下载\r\n\r\n## What's Changed\r\n* Add holdings by @whrss9527\r\n\r\n**Full Changelog**: https://x"
        XCTAssertEqual(ReleaseNotes.highlights(notes), "")
        XCTAssertEqual(ReleaseNotes.highlights("修复了一些问题"), "修复了一些问题", "没有标题的说明原样显示")
    }
}
