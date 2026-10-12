import Foundation

/// 发布说明的纯文本整理。App 决定语言和要隐藏的重复章节。
public enum ReleaseNotes {
    public enum Language: Sendable { case english, chinese }
    public enum Block: Equatable, Sendable {
        case heading(String)
        case item(String)
        case paragraph(String)
    }

    public struct Style: Sendable {
        public var highlightsHeading: String?
        /// 不带 Markdown 的 #，大小写不敏感。
        public var skippedHeadings: Set<String>
        public var bilingualSeparator: String?
        public var language: Language

        public init(highlightsHeading: String? = nil,
                    skippedHeadings: Set<String> = ["install", "install or update", "installation", "known limitations",
                                                   "安装", "安装与更新", "已知限制", "what's changed", "new contributors"],
                    bilingualSeparator: String? = nil, language: Language = .chinese) {
            self.highlightsHeading = highlightsHeading
            self.skippedHeadings = skippedHeadings
            self.bilingualSeparator = bilingualSeparator
            self.language = language
        }

        public static func stox(language: Language = .chinese) -> Style {
            Style(highlightsHeading: "更新内容", language: language)
        }

        public static func meno(language: Language = .english) -> Style {
            Style(bilingualSeparator: "---", language: language)
        }
    }

    public static func highlights(_ body: String, style: Style = .stox()) -> String {
        var kept: [String] = []
        var skipping = false
        var sawHighlights = false
        let skipped = Set(style.skippedHeadings.map { normalizedHeading($0) })
        for line in lines(body) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                let heading = normalizedHeading(trimmed)
                if let wanted = style.highlightsHeading, heading == normalizedHeading(wanted) {
                    sawHighlights = true
                    skipping = false
                    continue
                }
                skipping = sawHighlights || skipped.contains(heading)
                continue
            }
            if trimmed.hasPrefix("**Full Changelog**") { continue }
            if !skipping { kept.append(line) }
        }
        return localized(kept.joined(separator: "\n"), style: style).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 保留标题、列表项和段落；折行接到同一个块，空行另起段落。
    public static func blocks(_ body: String, style: Style = .meno()) -> [Block] {
        let selected = style.highlightsHeading == nil ? localized(body, style: style) : highlights(body, style: style)
        let skipped = Set(style.skippedHeadings.map { normalizedHeading($0) })
        var blocks: [Block] = []
        var skipping = false
        var afterBlank = true
        for raw in lines(selected) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { afterBlank = true; continue }
            let continues = !afterBlank
            afterBlank = false
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                skipping = skipped.contains(title.lowercased())
                if !skipping, !title.isEmpty { blocks.append(.heading(title)) }
                continue
            }
            if skipping || line == "中文说明见下方。" || line.hasPrefix("**Full Changelog**") { continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.item(line.dropFirst(2).trimmingCharacters(in: .whitespaces)))
                continue
            }
            switch blocks.last {
            case .item(let text)? where continues:
                blocks[blocks.count - 1] = .item(text + " " + line)
            case .paragraph(let text)? where continues:
                blocks[blocks.count - 1] = .paragraph(text + " " + line)
            default:
                blocks.append(.paragraph(line))
            }
        }
        return blocks
    }

    public static func combined(_ releases: [GitHubRelease], limit: Int, style: Style = .stox()) -> String {
        let shown = releases.prefix(max(limit, 1))
        var parts = shown.map { release in
            let text = highlights(release.body ?? "", style: style)
            return "**\(release.version?.description ?? release.tagName)**\n" + (text.isEmpty ? missingNotes(style) : text)
        }
        if releases.count > shown.count { parts.append(earlier(releases.count - shown.count, style: style)) }
        return parts.joined(separator: "\n\n")
    }

    public static func firstLines(_ releases: [GitHubRelease], limit: Int, style: Style = .stox()) -> [String] {
        let shown = releases.prefix(max(limit, 1))
        var result = shown.map { release in
            var first = highlights(release.body ?? "", style: style).split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            if first.hasPrefix("- ") || first.hasPrefix("* ") { first.removeFirst(2) }
            return "- **\(release.version?.description ?? release.tagName)** " + (first.isEmpty ? missingNotes(style) : headline(first))
        }
        if releases.count > shown.count {
            let count = releases.count - shown.count
            result.append(style.language == .chinese ? "- 还有 \(count) 个更早的版本" : "- \(count) earlier releases")
        }
        return result
    }

    /// 冒号前通常是功能名；没有冒号时取第一句，太长就加省略号。
    public static func headline(_ text: String, maxLength: Int = 36) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        let limit = max(maxLength, 0)
        for stops in [["：", ":"], ["，", "。", "；"]] as [[Character]] {
            if let index = text.firstIndex(where: { stops.contains($0) }), index > text.startIndex,
               text.distance(from: text.startIndex, to: index) <= limit { return String(text[..<index]) }
        }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private static func lines(_ body: String) -> [String] {
        body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    private static func normalizedHeading(_ heading: String) -> String {
        heading.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func localized(_ body: String, style: Style) -> String {
        let all = lines(body)
        if let separator = style.bilingualSeparator,
           let rule = all.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == separator }) {
            return (style.language == .chinese ? all[(rule + 1)...] : all[..<rule]).joined(separator: "\n")
        }
        // Stox 的旧说明用语言小标题；没有翻译时保留已有语言。
        guard all.contains(where: { ["### 中文", "### English"].contains($0.trimmingCharacters(in: .whitespaces)) }) else {
            return body
        }
        var chinese: [String] = [], english: [String] = []
        var inEnglish = false
        for line in all {
            let heading = line.trimmingCharacters(in: .whitespaces)
            if heading == "### 中文" { inEnglish = false; continue }
            if heading == "### English" { inEnglish = true; continue }
            if inEnglish { english.append(line) } else { chinese.append(line) }
        }
        let zh = chinese.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let en = english.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return style.language == .english ? (en.isEmpty ? zh : en) : (zh.isEmpty ? en : zh)
    }

    private static func missingNotes(_ style: Style) -> String {
        style.language == .chinese ? "这个版本没有写更新内容" : "This release has no notes."
    }

    private static func earlier(_ count: Int, style: Style) -> String {
        style.language == .chinese ? "还有 \(count) 个更早的版本，见发布页" : "\(count) earlier releases; see the release page."
    }
}
