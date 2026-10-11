import Foundation

/// 从当前版本到最新版本之间的说明，以及列表是否覆盖整个区间。
public struct UpdateNotes: Equatable, Sendable {
    public static let pageSize = 100
    public typealias Block = ReleaseNotes.Block

    public struct Version: Equatable, Sendable {
        public let version: AppVersion
        public let date: Date?
        public let blocks: [Block]

        public init(version: AppVersion, date: Date?, blocks: [Block]) {
            self.version = version
            self.date = date
            self.blocks = blocks
        }
    }

    public let current: AppVersion
    public let latest: GitHubRelease
    public var tagName: String { latest.tagName }
    public let versions: [Version]
    public let isComplete: Bool

    /// receivedCount 是接口原始页的条数；过滤草稿或坏元素之后应传入它，避免误认为已到末页。
    public init(current: AppVersion, latest: GitHubRelease, releases: [GitHubRelease]?,
                style: ReleaseNotes.Style = .meno(), channel: UpdateChannel = .stable, receivedCount: Int? = nil) {
        self.current = current
        self.latest = latest
        var versions: [Version] = []
        if let newest = latest.version {
            for release in ReleaseFeed.releases([latest] + (releases ?? []), after: current, upTo: newest, channel: channel) {
                guard let version = release.version, !versions.contains(where: { $0.version == version }) else { continue }
                versions.append(Version(version: version, date: release.publishedAt,
                                        blocks: ReleaseNotes.blocks(release.body ?? "", style: style)))
            }
        }
        self.versions = versions
        if let releases, latest.version != nil {
            isComplete = (receivedCount ?? releases.count) < Self.pageSize || releases.contains { release in
                !release.isDraft && release.version.map { $0 <= current } == true
            }
        } else {
            isComplete = false
        }
    }
}
