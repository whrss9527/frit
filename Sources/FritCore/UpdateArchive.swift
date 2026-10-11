import Foundation

/// 四个 App 的历史附件名。选择名字与验证下载源分开，测试源由调用方处理。
public enum ArchiveNaming: Sendable {
    case fixed(String)
    case versioned(prefix: String, suffix: String = ".zip")
    case perArchitecture(universal: String, thin: @Sendable (Architecture) -> String)
    case custom(@Sendable ([GitHubRelease.Asset], AppVersion, Architecture) -> GitHubRelease.Asset?)

    public func asset(in release: GitHubRelease, architecture: Architecture) -> GitHubRelease.Asset? {
        switch self {
        case .fixed(let name):
            return release.assets.first { $0.name == name }
        case .versioned(let prefix, let suffix):
            guard let version = release.version else { return nil }
            let archives = release.assets.filter {
                $0.name.lowercased().hasPrefix(prefix.lowercased()) && $0.name.lowercased().hasSuffix(suffix.lowercased())
            }
            return archives.first { $0.name == prefix + version.description + suffix }
                ?? archives.first { $0.name.contains(version.description) }
                ?? archives.first
        case .perArchitecture(let universal, let thin):
            return release.assets.first { $0.name == thin(architecture) }
                ?? release.assets.first { $0.name == universal }
        case .custom(let select):
            guard let version = release.version, let asset = select(release.assets, version, architecture),
                  release.assets.contains(asset) else { return nil }
            return asset
        }
    }
}

public struct UpdateCandidate: Equatable, Sendable {
    public let release: GitHubRelease
    public let archive: GitHubRelease.Asset?
    public let checksums: GitHubRelease.Asset?
    public var canInstall: Bool { archive != nil && (archive?.sha256 != nil || checksums != nil) }

    /// 调用方已验证附件来源时使用，例如受限制的本地端到端测试源。
    public init(release: GitHubRelease, archive: GitHubRelease.Asset?, checksums: GitHubRelease.Asset?) {
        self.release = release
        self.archive = archive
        self.checksums = checksums
    }

    /// 正式发布只从本仓库、本标签的附件中选择，防止外来链接抢占同名附件。
    public init(release: GitHubRelease, naming: ArchiveNaming, architecture: Architecture,
                publishedBy repository: String, checksumsName: String = "SHA256SUMS.txt") {
        let owned = GitHubRelease(tagName: release.tagName, htmlURL: release.htmlURL,
                                  assets: release.assets.filter { release.owns($0, publishedBy: repository) },
                                  body: release.body, publishedAt: release.publishedAt,
                                  isDraft: release.isDraft, isPrerelease: release.isPrerelease)
        self.init(release: release, archive: naming.asset(in: owned, architecture: architecture),
                  checksums: owned.asset(named: checksumsName, publishedBy: repository))
    }
}

/// shasum -a 256 的文本格式：哈希、空白和文件名，也认二进制模式的 * 标记。
public enum Checksums {
    static func validHash(_ text: String) -> String? {
        let hex = text.lowercased()
        return hex.count == 64 && hex.allSatisfy({ "0123456789abcdef".contains($0) }) ? hex : nil
    }

    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var conflicts: Set<String> = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let hash = validHash(String(fields[0])) else { continue }
            var name = fields[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard !name.isEmpty, !conflicts.contains(name) else { continue }
            if let existing = result[name], existing != hash {
                result.removeValue(forKey: name)
                conflicts.insert(name)
            } else {
                result[name] = hash
            }
        }
        return result
    }
}
