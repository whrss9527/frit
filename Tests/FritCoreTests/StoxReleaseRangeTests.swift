import XCTest
@testable import FritCore

final class StoxReleaseRangeTests: XCTestCase {
    private func release(_ version: String, _ notes: String) -> GitHubRelease {
        GitHubRelease(tagName: "v" + version, htmlURL: URL(string: "https://github.com/whrss9527/stox/releases/tag/v" + version)!, body: notes)
    }

    private var range: [GitHubRelease] {
        [release("0.38.0", "## 更新内容\n\n- 五日图下面画上成交量\n- README 换了截图\n\n## 安装\n\n1. 下载"),
         release("0.37.0", "## 更新内容\n\n- 盈亏日历"),
         release("0.36.0", "## 安装\n\n1. 下载"),
         release("0.35.0", "## 更新内容\n\n* 资金流向")]
    }

    func testCombinesTheNotes() {
        XCTAssertEqual(ReleaseNotes.combined(Array(range.prefix(2)), limit: 5),
                       "**0.38.0**\n- 五日图下面画上成交量\n- README 换了截图\n\n**0.37.0**\n- 盈亏日历")
        XCTAssertEqual(ReleaseNotes.combined(range, limit: 2).components(separatedBy: "\n\n").last,
                       "还有 2 个更早的版本，见发布页")
        XCTAssertTrue(ReleaseNotes.combined(range, limit: 3).contains("**0.36.0**\n这个版本没有写更新内容"))
        XCTAssertEqual(ReleaseNotes.firstLines(range, limit: 3), [
            "- **0.38.0** 五日图下面画上成交量",
            "- **0.37.0** 盈亏日历",
            "- **0.36.0** 这个版本没有写更新内容",
            "- 还有 1 个更早的版本",
        ])
        XCTAssertEqual(ReleaseNotes.firstLines(Array(range.suffix(1)), limit: 3), ["- **0.35.0** 资金流向"])
    }

    func testHeadlines() {
        XCTAssertEqual(ReleaseNotes.headline("盈亏日历：排序菜单里的“盈亏日历…”按月列出每个交易日的今日盈亏"), "盈亏日历")
        XCTAssertEqual(ReleaseNotes.headline("A 股个股和 ETF 展开后多了“资金”：左边是主力净流入"), "A 股个股和 ETF 展开后多了“资金”")
        XCTAssertEqual(ReleaseNotes.headline("列表里每一行在现价左边画一条当天的迷你分时，虚线是昨收，一眼看出今天是怎么走的。"),
                       "列表里每一行在现价左边画一条当天的迷你分时")
        XCTAssertEqual(ReleaseNotes.headline("命令行工具多了 `stox-cli flow`，打印当天的资金流向。"), "命令行工具多了 `stox-cli flow`")
        XCTAssertEqual(ReleaseNotes.headline("修复了一些问题"), "修复了一些问题")
        XCTAssertEqual(ReleaseNotes.headline(String(repeating: "长", count: 50)), String(repeating: "长", count: 36) + "…")
        XCTAssertEqual(ReleaseNotes.headline("：开头就是冒号的不算"), "：开头就是冒号的不算")
        XCTAssertEqual(ReleaseNotes.headline("长标题", maxLength: -1), "…")
    }

    func testEnglishSummaryUsesEnglishFallbacks() {
        let item = release("1.0", "## 更新内容\n### English\n- Alerts: improved\n### 中文\n- 提醒：改进")
        XCTAssertEqual(ReleaseNotes.firstLines([item], limit: 1, style: .stox(language: .english)), ["- **1.0** Alerts"])
        XCTAssertTrue(ReleaseNotes.combined(range, limit: 1, style: .stox(language: .english)).contains("3 earlier releases"))
        XCTAssertTrue(ReleaseNotes.combined([range[2]], limit: 1, style: .stox(language: .english)).contains("This release has no notes."))
    }
}
