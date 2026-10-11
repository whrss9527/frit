import Foundation

/// GitHub 发布信息。保留所有附件，选择安装包时另行核对仓库和标签。
public struct GitHubRelease: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        public let downloadURL: URL
        public let size: Int?
        public let digest: String?

        public init(name: String, downloadURL: URL, size: Int? = nil, digest: String? = nil) {
            self.name = name
            self.downloadURL = downloadURL
            self.size = size
            self.digest = digest
        }

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case downloadURL = "browser_download_url"
        }

        /// 只接受 64 位十六进制 SHA-256，不把其他摘要当作校验和。
        public var sha256: String? {
            guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
            return Checksums.validHash(String(digest.dropFirst(7)))
        }
    }

    public let tagName: String
    public let htmlURL: URL
    public let body: String?
    public let publishedAt: Date?
    public let isDraft: Bool
    public let isPrerelease: Bool
    public let assets: [Asset]
    public var version: AppVersion? { AppVersion(tagName) }

    public init(tagName: String, htmlURL: URL, assets: [Asset] = [], body: String? = nil,
                publishedAt: Date? = nil, isDraft: Bool = false, isPrerelease: Bool = false) {
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.assets = assets
        self.body = body
        self.publishedAt = publishedAt
        self.isDraft = isDraft
        self.isPrerelease = isPrerelease
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body, assets
        case publishedAt = "published_at"
        case isDraft = "draft"
        case isPrerelease = "prerelease"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        guard !tagName.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .tagName, in: container, debugDescription: "发布标签不能为空")
        }
        htmlURL = try container.decode(URL.self, forKey: .htmlURL)
        assets = (try? container.decode(DecodedList<Asset>.self, forKey: .assets).values) ?? []
        body = try? container.decodeIfPresent(String.self, forKey: .body)
        let published = try? container.decodeIfPresent(String.self, forKey: .publishedAt)
        publishedAt = published.flatMap { ISO8601DateFormatter().date(from: $0) }
        isDraft = (try? container.decodeIfPresent(Bool.self, forKey: .isDraft)) ?? false
        isPrerelease = (try? container.decodeIfPresent(Bool.self, forKey: .isPrerelease)) ?? false
    }

    /// 只认 HTTPS GitHub 上属于本仓库、本标签的附件。
    public func asset(named name: String, publishedBy repository: String) -> Asset? {
        assets.first { $0.name == name && owns($0, publishedBy: repository) }
    }

    func owns(_ asset: Asset, publishedBy repository: String) -> Bool {
        let url = asset.downloadURL
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "github.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        let repoParts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard repoParts.count == 2, repoParts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !tagName.isEmpty else { return false }
        let prefix = "/\(repository)/releases/download/\(tagName)/"
        guard url.path.hasPrefix(prefix), url.path.count > prefix.count else { return false }
        return !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    public enum ChecksumFailure: Error { case unavailable }

    /// GitHub 摘要优先；回退到校验文件时，重复而冲突的文件名不能用于安装。
    public static func expectedSHA256(for archive: Asset, checksums: String? = nil) throws -> String {
        if let digest = archive.sha256 { return digest }
        guard let checksums, let hash = Checksums.parse(checksums)[archive.name] else {
            throw ChecksumFailure.unavailable
        }
        return hash
    }
}

public enum UpdateChannel: Sendable { case stable, includePrereleases }
public enum Architecture: String, Sendable { case arm64, x86_64 }

/// Pop 的列表和其他 App 的单个 latest 对象共用一个入口。
public enum ReleaseFeed {
    public static func parse(_ data: Data) -> [GitHubRelease]? {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode(DecodedList<GitHubRelease>.self, from: data) {
            return list.values.filter { !$0.isDraft }
        }
        if let release = try? decoder.decode(GitHubRelease.self, from: data) {
            return release.isDraft ? [] : [release]
        }
        return nil
    }

    public static func newest(_ releases: [GitHubRelease], channel: UpdateChannel = .stable) -> GitHubRelease? {
        eligible(releases, channel: channel).max { $0.version! < $1.version! }
    }

    /// 排除草稿、无效版本和超出区间的发布，按版本降序返回。
    public static func releases(_ all: [GitHubRelease], after since: AppVersion, upTo latest: AppVersion,
                                channel: UpdateChannel = .stable) -> [GitHubRelease] {
        eligible(all, channel: channel).filter { since < $0.version! && $0.version! <= latest }
            .sorted { $1.version! < $0.version! }
    }

    private static func eligible(_ releases: [GitHubRelease], channel: UpdateChannel) -> [GitHubRelease] {
        releases.filter { release in
            guard !release.isDraft, let version = release.version else { return false }
            return channel == .includePrereleases || (!release.isPrerelease && !version.isPrerelease)
        }
    }
}

/// superDecoder 先前进再解码，坏元素不会阻止后面的发布或附件。
private struct DecodedList<Element: Decodable>: Decodable {
    let values: [Element]
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Element] = []
        while !container.isAtEnd {
            let elementDecoder = try container.superDecoder()
            if let value = try? Element(from: elementDecoder) { values.append(value) }
        }
        self.values = values
    }
}
