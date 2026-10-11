#if os(macOS)
import Foundation
import FritCore
import FritSystem

public enum SignerPolicy: Equatable, Sendable {
    case sameTeamAsCurrent
    case team(String)
    case designatedRequirementOfCurrent
    case any
}

public enum InstallStrategy: Sendable { case staged }

/// 后续严格检查用的扩展点；当前版本对未知位明确失败，不静默忽略。
public struct StrictChecks: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

public struct UpdateLogger: Sendable {
    private let writeInfo: @Sendable (String) -> Void
    private let writeError: @Sendable (String) -> Void
    public init(info: @escaping @Sendable (String) -> Void, error: @escaping @Sendable (String) -> Void) {
        writeInfo = info
        writeError = error
    }
    public func info(_ message: String) { writeInfo(message) }
    public func error(_ message: String) { writeError(message) }
    public static var osLog: UpdateLogger {
        let log = FileLog(subsystem: Bundle.main.bundleIdentifier ?? "FritUpdate")
        return UpdateLogger(info: { log.info($0) }, error: { log.error($0) })
    }
}

public struct UpdateConfiguration {
    public var repository: String
    public var appName: String
    public var archive: ArchiveNaming
    public var checksumsName = "SHA256SUMS.txt"
    public var channel: UpdateChannel = .stable
    public var signer: SignerPolicy = .sameTeamAsCurrent
    public var alsoAccept: [SignerPolicy] = []
    public var sessions: @Sendable (URL) -> [URLSessionConfiguration] = { _ in [.ephemeral] }
    public var routeName: (URL, Int) -> String? = { _, _ in nil }
    public var environmentPrefix: String
    public var defaults: UserDefaults = .standard
    public var defaultsKeyPrefix = "update."
    public var checkInterval: TimeInterval = 6 * 3600
    public var relocatesWhenTranslocated = true
    public var installStrategy: InstallStrategy = .staged
    public var strictChecks: StrictChecks = []
    public var refetchLatestBeforeInstall = true
    public var notes: ReleaseNotes.Style = .stox()
    public var log: UpdateLogger = .osLog
    public var bundleURL: URL = Bundle.main.bundleURL
    public var currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    public var expectedIdentifier: String? = Bundle.main.bundleIdentifier
    public var userAgent: String
    public var applicationsFolders: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
    ]
    /// 测试可替换重启入口，避免退出 XCTest；正常 App 用实际 helper。
    public var relaunch: @MainActor (URL, URL?) -> Bool = { Relauncher.relaunch(bundle: $0, previous: $1) }

    public init(repository: String, appName: String, archive: ArchiveNaming? = nil) {
        self.repository = repository
        self.appName = appName
        self.archive = archive ?? .fixed(appName + ".zip")
        environmentPrefix = appName.uppercased()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        userAgent = appName + "/" + version + " (macOS)"
    }

    public var releasesURL: URL? { URL(string: "https://github.com/\(repository)/releases") }
    public var overrideURL: URL? {
        ProcessInfo.processInfo.environment[environmentPrefix + "_UPDATE_URL"].flatMap(URL.init(string:))
    }
    var latestURL: URL? {
        overrideURL ?? URL(string: "https://api.github.com/repos/\(repository)/releases"
                          + (channel == .stable ? "/latest" : "?per_page=100"))
    }

    /// 测试源的附件必须在 feed 同源目录下；正式源使用 Core 的仓库和标签限制。
    func candidate(for release: GitHubRelease, architecture: Architecture) -> UpdateCandidate {
        guard let source = overrideURL else {
            return UpdateCandidate(release: release, naming: archive, architecture: architecture,
                                   publishedBy: repository, checksumsName: checksumsName)
        }
        let directory = source.deletingLastPathComponent().path
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        let owned = release.assets.filter { asset in
            let url = asset.downloadURL
            return url.scheme == source.scheme && url.host == source.host && url.port == source.port
                && url.user == nil && url.password == nil && url.path.hasPrefix(prefix)
                && !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        }
        let filtered = GitHubRelease(tagName: release.tagName, htmlURL: release.htmlURL, assets: owned,
                                     body: release.body, publishedAt: release.publishedAt,
                                     isDraft: release.isDraft, isPrerelease: release.isPrerelease)
        return UpdateCandidate(release: release, archive: archive.asset(in: filtered, architecture: architecture),
                               checksums: owned.first { $0.name == checksumsName })
    }
}

public enum UpdateError: LocalizedError, Equatable, Sendable {
    case server(Int)
    case badResponse
    case noArchive
    case checksumsMissing
    case checksumMismatch
    case sizeMismatch
    case extract(String)
    case appNotFound
    case wrongApp(String)
    case notInstallable(String)
    case install(String)
    case cancelledByUser
    case appManagement
    case wrongSigner
    case unsupportedChecks

    public var errorDescription: String? {
        switch self {
        case .server(let code): return updateText("服务器返回了 %lld", Int64(code))
        case .badResponse: return updateText("读不懂服务器返回的内容")
        case .noArchive: return updateText("这个版本没有可以直接安装和校验的附件，请到发布页手动下载")
        case .checksumsMissing: return updateText("校验文件里没有唯一的附件校验和")
        case .checksumMismatch: return updateText("下载的文件校验和不对，可能没下载完整或被篡改")
        case .sizeMismatch: return updateText("下载的文件大小不对")
        case .extract(let reason): return updateText("解压失败：%@", reason)
        case .appNotFound: return updateText("压缩包里没有可安装的 .app")
        case .wrongApp(let reason): return updateText("下载的程序不对：%@", reason)
        case .notInstallable(let reason): return reason
        case .install(let reason): return updateText("替换程序失败：%@", reason)
        case .cancelledByUser: return updateText("已取消授权，程序没有改动")
        case .appManagement: return updateText("macOS 不允许替换程序。到系统设置的隐私与安全性 → App 管理中允许后重试")
        case .wrongSigner: return updateText("新版本不是允许的开发者签名的，为了安全没有安装")
        case .unsupportedChecks: return updateText("此版本尚不支持要求的严格检查")
        }
    }
}
#endif
