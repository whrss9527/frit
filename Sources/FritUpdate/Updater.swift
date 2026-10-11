#if os(macOS)
import Combine
import Foundation
import Darwin
import FritCore
import FritSystem

@MainActor
public final class Updater: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle, checking, upToDate
        case skipped(UpdateCandidate)
        case available(UpdateCandidate)
        case downloading(UpdateCandidate, Double?)
        case verifying(UpdateCandidate)
        case installing(UpdateCandidate)
        case relaunching(UpdateCandidate)
        case failed(UpdateCandidate, UpdateError)
    }

    public let configuration: UpdateConfiguration
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var lastChecked: Date?
    @Published public private(set) var checkError: String?
    @Published public private(set) var lastFailure: UpdateError?
    @Published public private(set) var notesSinceCurrent: UpdateNotes?
    @Published public private(set) var route: String?
    @Published public var automaticChecks: Bool {
        didSet { configuration.defaults.set(automaticChecks, forKey: key("automaticChecks")) }
    }
    @Published public var includePrereleases: Bool {
        didSet { configuration.defaults.set(includePrereleases, forKey: key("includePrereleases")) }
    }
    public var notify: ((UpdateCandidate) -> Void)?
    public var onRelaunch: (() -> Void)?
    private var installTask: Task<Void, Never>?
    private var notesTask: Task<Void, Never>?
    private var automaticTask: Task<Void, Never>?
    private var activeSessions: [UUID: URLSession] = [:]
    private var generation = 0
    private var beforeCheck: Phase = .idle
    private var isPreview = false
    private var notesReleases: [GitHubRelease]?
    private var notesReceivedCount: Int?

    public init(configuration: UpdateConfiguration) {
        self.configuration = configuration
        let defaults = configuration.defaults
        let prefix = configuration.defaultsKeyPrefix
        automaticChecks = defaults.object(forKey: prefix + "automaticChecks") as? Bool ?? true
        includePrereleases = defaults.object(forKey: prefix + "includePrereleases") as? Bool ?? (configuration.channel == .includePrereleases)
        lastChecked = defaults.object(forKey: prefix + "lastChecked") as? Date
    }

    deinit {
        installTask?.cancel()
        notesTask?.cancel()
        automaticTask?.cancel()
    }

    public var candidate: UpdateCandidate? {
        switch phase {
        case .available(let item), .downloading(let item, _), .verifying(let item), .installing(let item),
             .relaunching(let item), .failed(let item, _): return item
        default: return nil
        }
    }
    /// Sample 和 SwiftUI 预览使用；预览对象的检查与安装入口不会执行网络或文件操作。
    public static func preview(configuration: UpdateConfiguration, phase: Phase, lastChecked: Date? = nil) -> Updater {
        let updater = Updater(configuration: configuration)
        updater.isPreview = true
        updater.phase = phase
        updater.lastChecked = lastChecked
        if case .failed(_, let error) = phase { updater.lastFailure = error }
        return updater
    }
    public var localizedNotes: UpdateNotes? {
        guard let notes = notesSinceCurrent else { return nil }
        return UpdateNotes(current: notes.current, latest: notes.latest, releases: notesReleases,
                           style: requestConfiguration.notes, channel: requestConfiguration.channel,
                           receivedCount: notesReceivedCount)
    }
    public var isInstalling: Bool {
        switch phase { case .downloading, .verifying, .installing, .relaunching: return true; default: return false }
    }
    public var canCancel: Bool {
        switch phase { case .checking, .downloading, .verifying: return true; default: return false }
    }
    public var plan: InstallPlan? {
        let bundle = configuration.bundleURL
        let testing = ProcessInfo.processInfo.environment[configuration.environmentPrefix + "_TEST_TRANSLOCATED"] == "1"
        let translocated = testing || Translocation.isTranslocated(bundle)
        let original = testing ? bundle.standardizedFileURL : (translocated ? Translocation.originalURL(of: bundle) : nil)
        let manager = FileManager.default
        let cannotReplace = configuration.installStrategy == .atomicSwap && !configuration.relocatesWhenTranslocated
            && (!manager.isWritableFile(atPath: bundle.path) || !manager.isWritableFile(atPath: bundle.deletingLastPathComponent().path))
        let readOnly = ((try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false) || cannotReplace
        return InstallLocation.plan(bundle: bundle, appName: configuration.appName, translocated: translocated,
                                    original: original, readOnly: readOnly, relocates: configuration.relocatesWhenTranslocated,
                                    folders: configuration.applicationsFolders, canWrite: Self.canWrite)
    }
    public var installProblem: String? {
        guard plan == nil else { return nil }
        return configuration.bundleURL.pathExtension == "app"
            ? updateText("请先把 %@ 移到应用程序后更新", configuration.appName)
            : updateText("不是从 %@.app 运行的，没法在程序里更新", configuration.appName)
    }
    public var relocationNote: String? {
        guard let plan, plan.relocating else { return nil }
        let folder = FileManager.default.displayName(atPath: plan.target.deletingLastPathComponent().path)
        return updateText("现在是从下载文件夹这类临时位置运行的，这次会装进%@", folder)
            + (plan.trashAfter == nil ? "" : updateText("，旧的那份移到废纸篓"))
    }

    public func startAutomaticChecks(enabled: @escaping @MainActor () -> Bool) {
        automaticTask?.cancel()
        let interval = configuration.checkInterval.isFinite ? min(max(configuration.checkInterval, 1), 365 * 86400) : 6 * 3600
        automaticTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                while !Task.isCancelled {
                    guard self != nil else { return }
                    await self?.automaticCheck(enabled: enabled)
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
            } catch { }
        }
    }
    public func stopAutomaticChecks() { automaticTask?.cancel(); automaticTask = nil }
    private func automaticCheck(enabled: @MainActor () -> Bool) async {
        guard automaticChecks, enabled(), lastChecked.map({ Date().timeIntervalSince($0) >= configuration.checkInterval }) ?? true else { return }
        if let item = await check(manual: false), ProcessInfo.processInfo.environment[configuration.environmentPrefix + "_UPDATE_AUTO_INSTALL"] == "1" {
            if item.canInstall { install() }
        }
    }

    @discardableResult
    public func check(manual: Bool) async -> UpdateCandidate? {
        guard !isPreview else { return nil }
        guard !isInstalling else { return candidate }
        if case .checking = phase { return nil }
        generation += 1
        let token = generation
        let previous = phase
        beforeCheck = previous
        phase = .checking
        checkError = nil
        notesTask?.cancel()
        do {
            guard let current = AppVersion(configuration.currentVersion) else { throw UpdateError.wrongApp("无法确定当前版本") }
            let config = requestConfiguration
            let latest = try await latestRelease(config)
            try Task.checkCancellation()
            guard generation == token else { return nil }
            lastChecked = Date()
            configuration.defaults.set(lastChecked, forKey: key("lastChecked"))
            guard let latest, let version = latest.version, current < version else {
                phase = .upToDate
                notesSinceCurrent = nil
                configuration.log.info("检查更新：当前 \(current) 已是最新")
                return nil
            }
            let item = config.candidate(for: latest, architecture: Self.machineArchitecture)
            if !manual, configuration.defaults.string(forKey: key("skippedVersion")) == version.description {
                phase = .skipped(item)
                return nil
            }
            phase = .available(item)
            configuration.log.info("检查更新：有新版本 \(version)（当前 \(current)）")
            notesSinceCurrent = UpdateNotes(current: current, latest: latest, releases: nil, style: config.notes, channel: config.channel)
            notesReleases = nil
            notesReceivedCount = nil
            notesTask = Task { [weak self] in await self?.loadNotes(current: current, latest: latest, config: config, token: token) }
            if !manual, configuration.defaults.string(forKey: key("notifiedVersion")) != version.description {
                configuration.defaults.set(version.description, forKey: key("notifiedVersion"))
                notify?(item)
            }
            return item
        } catch {
            guard generation == token else { return nil }
            phase = previous
            if !(error is CancellationError) {
                configuration.log.error("检查更新失败：\(error.localizedDescription)")
                if manual { checkError = updateText("检查更新失败：%@", error.localizedDescription) }
            }
            return nil
        }
    }

    public func skipAvailableVersion() {
        guard case .available(let item) = phase, let version = item.release.version else { return }
        configuration.defaults.set(version.description, forKey: key("skippedVersion"))
        phase = .skipped(item)
    }
    public func showSkippedVersion() {
        guard case .skipped(let item) = phase else { return }
        phase = .available(item)
    }

    public func install() {
        guard !isPreview else { return }
        guard let item = candidate, !isInstalling, installTask == nil else { return }
        if let problem = installProblem { phase = .failed(item, .notInstallable(problem)); return }
        guard item.canInstall else { phase = .failed(item, .noArchive); return }
        generation += 1
        let token = generation
        lastFailure = nil
        notesTask?.cancel()
        phase = .verifying(item)
        installTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.installTask = nil } }
            do { try await self.perform(item, token: token) }
            catch {
                guard self.generation == token else { return }
                if error is CancellationError { self.phase = .available(item) }
                else {
                    let failure = error as? UpdateError ?? .install(error.localizedDescription)
                    self.lastFailure = failure
                    self.phase = .failed(self.candidate ?? item, failure)
                    self.configuration.log.error("更新失败：\(failure.localizedDescription)")
                }
            }
        }
    }

    public func cancel() {
        guard canCancel else { return }
        let item = candidate
        generation += 1
        installTask?.cancel()
        installTask = nil
        notesTask?.cancel()
        for session in activeSessions.values { session.invalidateAndCancel() }
        phase = item.map(Phase.available) ?? beforeCheck
    }
    public func checkAndInstall() async {
        if case .skipped = phase { showSkippedVersion() }
        if candidate == nil { _ = await check(manual: true) }
        install()
        await installTask?.value
    }

    private var requestConfiguration: UpdateConfiguration {
        var config = configuration
        config.channel = includePrereleases ? .includePrereleases : .stable
        if let language = FritLocalization.languageOverride {
            config.notes.language = language.lowercased().hasPrefix("zh") ? .chinese : .english
        }
        return config
    }
    private func key(_ suffix: String) -> String { configuration.defaultsKeyPrefix + suffix }

    private func fetch(_ url: URL, config: UpdateConfiguration) async throws -> Data {
        let token = generation
        var failure: Error = UpdateError.badResponse
        for (index, options) in config.sessions(url).enumerated() {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            route = config.routeName(url, index)
            let session = URLSession(configuration: options)
            let id = UUID()
            activeSessions[id] = session
            defer { activeSessions[id] = nil; session.invalidateAndCancel() }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await session.data(for: request)
                if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) { throw UpdateError.server(response.statusCode) }
                return data
            } catch {
                if Task.isCancelled || generation != token || error is CancellationError { throw CancellationError() }
                failure = error
            }
        }
        throw failure
    }
    private func fetchAttachment(_ url: URL) async throws -> Data {
        try await fetch(url, config: configuration)
    }
    private func latestRelease(_ config: UpdateConfiguration) async throws -> GitHubRelease? {
        guard let url = config.latestURL, let all = ReleaseFeed.parse(try await fetch(url, config: config)) else { throw UpdateError.badResponse }
        return ReleaseFeed.newest(all, channel: config.channel)
    }
    private func loadNotes(current: AppVersion, latest: GitHubRelease, config: UpdateConfiguration, token: Int) async {
        guard let url = config.overrideURL ?? URL(string: "https://api.github.com/repos/\(config.repository)/releases?per_page=100") else { return }
        do {
            let data = try await fetch(url, config: config)
            guard let releases = ReleaseFeed.parse(data), generation == token, !Task.isCancelled else { return }
            let count = (try? JSONSerialization.jsonObject(with: data) as? [Any])?.count ?? releases.count
            notesReleases = releases
            notesReceivedCount = count
            notesSinceCurrent = UpdateNotes(current: current, latest: latest, releases: releases, style: config.notes,
                                            channel: config.channel, receivedCount: count)
        } catch {
            if !Task.isCancelled { configuration.log.info("取各个版本的更新内容失败：\(error.localizedDescription)") }
        }
    }

    private func perform(_ original: UpdateCandidate, token: Int) async throws {
        let config = requestConfiguration
        var item = original
        if config.refetchLatestBeforeInstall {
            guard let latest = try await latestRelease(config), let version = latest.version,
                  let current = AppVersion(config.currentVersion), current < version else { throw UpdateError.badResponse }
            item = config.candidate(for: latest, architecture: Self.machineArchitecture)
        }
        try Task.checkCancellation()
        guard generation == token, let plan, let archiveAsset = item.archive, item.canInstall else { throw UpdateError.noArchive }
        guard let version = item.release.version else { throw UpdateError.badResponse }
        guard !archiveAsset.name.isEmpty, !archiveAsset.name.contains("/"), archiveAsset.name != ".", archiveAsset.name != ".." else { throw UpdateError.badResponse }
        let manager = FileManager.default
        let work = try UpdateInstaller.workspace(replacing: plan.target, strategy: config.installStrategy)
        defer { try? manager.removeItem(at: work) }
        let archive = work.appendingPathComponent(archiveAsset.name)
        phase = .downloading(item, nil)
        config.log.info("开始更新到 \(version)：下载 \(archiveAsset.downloadURL.absoluteString)")
        let progressItem = item
        var downloaded = false
        var downloadFailure: Error = UpdateError.badResponse
        for (index, options) in config.sessions(archiveAsset.downloadURL).enumerated() {
            route = config.routeName(archiveAsset.downloadURL, index)
            do {
                try await UpdateInstaller.download(archiveAsset.downloadURL, expectedSize: archiveAsset.size, to: archive,
                                                    session: options, userAgent: config.userAgent) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.generation == token, case .downloading = self.phase else { return }
                        self.phase = .downloading(progressItem, fraction)
                    }
                }
                downloaded = true
                break
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                downloadFailure = error
            }
        }
        guard downloaded else { throw downloadFailure }
        try Task.checkCancellation()
        phase = .verifying(item)
        try await UpdateInstaller.verify(archive: archive, candidate: item, fetch: { [self] url in try await fetchAttachment(url) }, log: config.log)
        let app = try await UpdateInstaller.extract(archive: archive, to: work.appendingPathComponent("extracted"), appName: config.appName)
        try await UpdateInstaller.validate(app: app, expectedVersion: version, expectedIdentifier: config.expectedIdentifier,
                                           signer: [config.signer] + config.alsoAccept, strict: config.strictChecks)
        try Task.checkCancellation()
        phase = .installing(item)
        let previous = try await UpdateInstaller.install(newApp: app, replacing: plan.target, strategy: config.installStrategy, log: config.log)
        if let old = plan.trashAfter {
            do { try manager.trashItem(at: old, resultingItemURL: nil); config.log.info("已把旧版本 \(old.path) 移到废纸篓") }
            catch { config.log.error("旧版本 \(old.path) 没能移到废纸篓：\(error.localizedDescription)") }
        }
        config.log.info("已更新到 \(version)（\(plan.target.path)），重新启动")
        phase = .relaunching(item)
        onRelaunch?()
        guard config.relaunch(plan.target, previous) else { throw UpdateError.install("无法重新打开程序") }
    }

    nonisolated public static var machineArchitecture: Architecture {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1 ? .arm64 : .x86_64
    }
    private static func canWrite(_ folder: URL) -> Bool {
        var directory: ObjCBool = false
        let manager = FileManager.default
        if manager.fileExists(atPath: folder.path, isDirectory: &directory) { return directory.boolValue && manager.isWritableFile(atPath: folder.path) }
        return manager.isWritableFile(atPath: folder.deletingLastPathComponent().path)
    }

    /// 在 App 稳定启动后调用。暂存策略只清理自有名称的旧目录，不触碰仍在运行的安装。
    @discardableResult
    public static func finishPreviousUpdate(bundle: URL = Bundle.main.bundleURL) -> String? {
        guard bundle.isFileURL, bundle.pathExtension == "app", FileManager.default.fileExists(atPath: bundle.path) else { return nil }
        let atomicRejected = AtomicReplacement.finish(bundle: bundle)
        let legacyRejected = AtomicReplacement.finishLegacyMeno(bundle: bundle)
        let parent = bundle.deletingLastPathComponent()
        let backup = parent.appendingPathComponent(".\(bundle.lastPathComponent).previous")
        let rejected = URL(fileURLWithPath: backup.path + ".rejected")
        var rolledBack: String?
        if let data = try? Data(contentsOf: rejected.appendingPathComponent("Contents/Info.plist")),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            rolledBack = info["CFBundleShortVersionString"] as? String
        }
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.removeItem(at: rejected)
        return rolledBack ?? atomicRejected ?? legacyRejected
    }
}
#endif
