import Foundation

/// 点分隔的版本号，比如 `0.2.1`，用来判断一个发布是不是更新。
///
/// 开头的 `v` 会被忽略，缺的段按 0 算，所以 `v1.2` 等于 `1.2.0`。
/// `-` 后面是预发布标记（`1.2.0-beta.1`），同号时预发布版比正式版旧；`+` 后面的构建信息不参与比较。
public struct AppVersion: Comparable, CustomStringConvertible, Hashable, Sendable {
    /// 数字部分，比如 `1.2.0-beta.1` 是 `[1, 2, 0]`。
    public let components: [Int]
    /// 预发布标记，比如 `1.2.0-beta.1` 是 `beta.1`；正式版是 `nil`。
    public let prerelease: String?

    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "v" || trimmed.first == "V" {
            trimmed.removeFirst()
        }
        if let plus = trimmed.firstIndex(of: "+") {
            trimmed = String(trimmed[..<plus])
        }
        var core = trimmed
        var prerelease: String?
        if let dash = trimmed.firstIndex(of: "-") {
            core = String(trimmed[..<dash])
            let tag = String(trimmed[trimmed.index(after: dash)...])
            guard !tag.isEmpty else { return nil }
            prerelease = tag
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        components = parts.compactMap { $0 }
        self.prerelease = prerelease
    }

    public var isPrerelease: Bool { prerelease != nil }

    public var description: String {
        components.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (left?, right?): return left.compare(right, options: .numeric) == .orderedAscending
        }
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var numbers = components
        while numbers.last == 0 { numbers.removeLast() }
        hasher.combine(numbers)
        hasher.combine(prerelease)
    }

    /// `candidate` 比 `current` 新时返回 true；任意一个解析不了时返回 false。
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidate = AppVersion(candidate), let current = AppVersion(current) else { return false }
        return candidate > current
    }
}
