#if os(macOS)
import Foundation
import FritCore
import FritSystem
import XCTest
@testable import FritUpdate

/// 每个测试独占目录、端口和环境变量；服务器不访问外网。
private final class UpdateFixture: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("frit update's \(UUID().uuidString)")
    let prefix = "FRIT_TEST_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let server = Process()
    let base: URL
    let defaults: UserDefaults
    let suite = "FritUpdateTests." + UUID().uuidString
    var target: URL { root.appendingPathComponent("Applications/Sample.app") }
    var feed: URL { base.appendingPathComponent("latest.json") }

    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pipe = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", """
        import http.server, os, socketserver, sys, time
        os.chdir(sys.argv[1])
        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                if self.path == '/slow':
                    self.send_response(200)
                    self.send_header('Content-Length', '1048576')
                    self.end_headers()
                    try:
                        for _ in range(256):
                            self.wfile.write(b'x' * 4096)
                            self.wfile.flush()
                            time.sleep(0.02)
                    except (BrokenPipeError, ConnectionResetError): pass
                else: super().do_GET()
        class Server(socketserver.ThreadingTCPServer):
            daemon_threads = True
        server = Server(('127.0.0.1', 0), Handler)
        print(server.server_address[1], flush=True)
        server.serve_forever()
        """, root.path]
        server.standardOutput = pipe
        server.standardError = FileHandle.nullDevice
        try server.run()
        var line = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) {
            line.append(byte)
            if line.count > 20 { break }
        }
        guard let port = Int(String(decoding: line, as: UTF8.self)),
              let address = URL(string: "http://127.0.0.1:\(port)/") else {
            server.terminate()
            throw UpdateError.badResponse
        }
        base = address
        setenv(prefix + "_UPDATE_URL", feed.absoluteString, 1)
    }
    func cleanup() {
        unsetenv(prefix + "_UPDATE_URL")
        if server.isRunning { server.terminate(); server.waitUntilExit() }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    func makeApp(at url: URL, version: String, signed: Bool = true) async throws {
        let executable = url.appendingPathComponent("Contents/MacOS/Sample")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: executable)
        let plist = ["CFBundleIdentifier": "test.frit.Sample", "CFBundleExecutable": "Sample",
                     "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        if signed {
            let result = try await Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
            guard result.succeeded else { throw UpdateError.install(result.output) }
        }
    }
    func writeFeed(version: String = "2.0.0", digest: String = String(repeating: "a", count: 64), size: Int = 3) throws {
        let release: [String: Any] = ["tag_name": "v" + version, "html_url": "https://github.com/test/sample/releases/tag/v" + version,
                                    "body": "### 新增\n- 测试更新", "assets": [["name": "Sample.zip", "size": size,
                                    "browser_download_url": base.appendingPathComponent("Sample.zip").absoluteString,
                                    "digest": "sha256:" + digest]]]
        try JSONSerialization.data(withJSONObject: release).write(to: root.appendingPathComponent("latest.json"))
    }
    @MainActor func configuration() -> UpdateConfiguration {
        var config = UpdateConfiguration(repository: "test/sample", appName: "Sample")
        config.environmentPrefix = prefix
        config.defaults = defaults
        config.defaultsKeyPrefix = "sample."
        config.bundleURL = target
        config.currentVersion = "1.0.0"
        config.expectedIdentifier = "test.frit.Sample"
        config.signer = .any
        config.log = UpdateLogger(info: { _ in }, error: { _ in })
        config.relaunch = { _, _ in true }
        return config
    }
}

private final class RecordedProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var fractions: [Double?] = []
    func append(_ value: Double?) { lock.lock(); fractions.append(value); lock.unlock() }
    var values: [Double?] { lock.lock(); defer { lock.unlock() }; return fractions }
}

@MainActor
final class MacUpdateTests: XCTestCase {
    private let abcSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func testChecksumUsesDigestBeforeFetchingAndRejectsCorruption() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }
        let archive = f.root.appendingPathComponent("Sample.zip")
        try Data("abc".utf8).write(to: archive)
        try f.writeFeed(digest: abcSHA256)
        let release = try XCTUnwrap(ReleaseFeed.parse(Data(contentsOf: f.root.appendingPathComponent("latest.json")))?.first)
        let candidate = f.configuration().candidate(for: release, architecture: .arm64)
        try await UpdateInstaller.verify(archive: archive, candidate: candidate, fetch: { _ in
            throw UpdateError.server(500)
        })
        try Data("changed".utf8).write(to: archive)
        do { try await UpdateInstaller.verify(archive: archive, candidate: candidate, fetch: { _ in Data() }); XCTFail("应拒绝损坏的包") }
        catch { XCTAssertEqual(error as? UpdateError, .checksumMismatch) }
    }

    func testChecksumFallsBackToUniqueSHA256SUMSEntry() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }
        let archive = f.root.appendingPathComponent("Sample.zip")
        try Data("abc".utf8).write(to: archive)
        let asset = GitHubRelease.Asset(name: "Sample.zip", downloadURL: f.base.appendingPathComponent("Sample.zip"))
        let sums = GitHubRelease.Asset(name: "SHA256SUMS.txt", downloadURL: f.base.appendingPathComponent("SHA256SUMS.txt"))
        let release = GitHubRelease(tagName: "v2.0.0", htmlURL: f.base, assets: [asset, sums])
        let candidate = UpdateCandidate(release: release, archive: asset, checksums: sums)
        let hash = abcSHA256
        try await UpdateInstaller.verify(archive: archive, candidate: candidate, fetch: { _ in Data("\(hash) *Sample.zip\n".utf8) })
        do {
            try await UpdateInstaller.verify(archive: archive, candidate: candidate, fetch: { _ in
                Data("\(hash) Sample.zip\n\(String(repeating: "a", count: 64)) Sample.zip\n".utf8)
            })
            XCTFail("不应接受冲突的校验和")
        } catch { XCTAssertEqual(error as? UpdateError, .checksumsMissing) }
    }

    func testDownloadChecksSizeProgressHTTPStatusAndCancellation() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }
        let bytes = Data(repeating: 42, count: 1024 * 1024)
        try bytes.write(to: f.root.appendingPathComponent("Sample.zip"))
        let output = f.root.appendingPathComponent("download/result.zip")
        let progress = RecordedProgress()
        let options = URLSessionConfiguration.ephemeral
        options.timeoutIntervalForResource = 17
        try await UpdateInstaller.download(f.base.appendingPathComponent("Sample.zip"), expectedSize: bytes.count, to: output,
                                           session: options, progress: { progress.append($0) })
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertEqual(options.timeoutIntervalForResource, 17)
        XCTAssertEqual(progress.values.compactMap { $0 }.last, 1)
        do {
            try await UpdateInstaller.download(f.base.appendingPathComponent("Sample.zip"), expectedSize: 3, to: output)
            XCTFail("应拒绝大小不符")
        } catch { XCTAssertEqual(error as? UpdateError, .sizeMismatch) }
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        do { try await UpdateInstaller.download(f.base.appendingPathComponent("missing"), expectedSize: nil, to: output); XCTFail("应拒绝 404") }
        catch { XCTAssertEqual(error as? UpdateError, .server(404)) }
        let cancelled = f.root.appendingPathComponent("cancelled.zip")
        let task = Task { try await UpdateInstaller.download(f.base.appendingPathComponent("slow"), expectedSize: nil, to: cancelled) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { try await task.value; XCTFail("应取消下载") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
    }

    func testValidationChecksVersionIdentifierAndSignerPolicies() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }
        let app = f.root.appendingPathComponent("signed/Sample.app")
        try await f.makeApp(at: app, version: "2.0.0")
        let version = try XCTUnwrap(AppVersion("2.0.0"))
        try await UpdateInstaller.validate(app: app, expectedVersion: version, expectedIdentifier: "test.frit.Sample", signer: [.any])
        XCTAssertTrue(CodeSignature.satisfies(app, requirement: nil))
        XCTAssertNil(CodeSignature.teamIdentifier(of: app))
        XCTAssertFalse(CodeSignature.isSigned(app, byTeam: "ABCDE12345"))
        XCTAssertNil(CodeSignature.requirementText(teamIdentifier: "bad\" or true"))
        do { try await UpdateInstaller.validate(app: app, expectedVersion: version, signer: [.team("ABCDE12345")]); XCTFail("应拒绝其他签名") }
        catch { XCTAssertEqual(error as? UpdateError, .wrongSigner) }
        try await UpdateInstaller.validate(app: app, expectedVersion: version, signer: [.team("ABCDE12345"), .any])
        do { try await UpdateInstaller.validate(app: app, expectedVersion: version, expectedIdentifier: "other", signer: [.any]); XCTFail("应拒绝其他 App") }
        catch { guard case .wrongApp = error as? UpdateError else { return XCTFail("\(error)") } }
        do { try await UpdateInstaller.validate(app: app, expectedVersion: AppVersion("3.0.0")!, signer: [.any]); XCTFail("应拒绝版本不符") }
        catch { guard case .wrongApp = error as? UpdateError else { return XCTFail("\(error)") } }
            do { try await UpdateInstaller.validate(app: app, expectedVersion: version, signer: [.any], strict: StrictChecks(rawValue: 1 << 31)); XCTFail("不能忽略未知检查") }
        catch { XCTAssertEqual(error as? UpdateError, .unsupportedChecks) }
        try Data("tampered".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertFalse(CodeSignature.satisfies(app, requirement: nil))
    }

    // 来自 Proxi 的替换/新建测试，以及 Pop、Proxi 的权限错误分类测试。
    func testInstallReplacesAndCreates() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }
        try await f.makeApp(at: f.target, version: "1.0.0", signed: false)
        let new = f.root.appendingPathComponent("download/Sample.app")
        try await f.makeApp(at: new, version: "2.0.0", signed: false)
        let previous = try await UpdateInstaller.install(newApp: new, replacing: f.target)
        XCTAssertNil(previous)
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.target.deletingLastPathComponent().path), ["Sample.app"])
        let fresh = f.root.appendingPathComponent("Home/Applications/Sample.app")
        let another = f.root.appendingPathComponent("second/Sample.app")
        try await f.makeApp(at: another, version: "3.0.0", signed: false)
        try await UpdateInstaller.install(newApp: another, replacing: fresh)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testPermissionErrorMapping() {
        func cocoa(_ posix: Int32) -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(posix))])
        }
        XCTAssertTrue(UpdateInstaller.needsAdmin(cocoa(EACCES)))
        XCTAssertFalse(UpdateInstaller.isBlockedBySystem(cocoa(EACCES)))
        XCTAssertTrue(UpdateInstaller.isBlockedBySystem(cocoa(EPERM)))
        XCTAssertFalse(UpdateInstaller.needsAdmin(cocoa(EPERM)))
        XCTAssertTrue(UpdateInstaller.needsAdmin(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        XCTAssertFalse(UpdateInstaller.needsAdmin(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
    }

    func testCheckSkipDefaultsAndRouteFallback() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }
        try f.writeFeed()
        var config = f.configuration()
        config.routeName = { _, index in index == 0 ? "首选" : "备用" }
        config.sessions = { _ in
            let failed = URLSessionConfiguration.ephemeral
            failed.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 1]
            // 首选线路用协议明确失败，避免系统绕过回环代理后造成假通过。
            failed.protocolClasses = [UnavailableProtocol.self]
            return [failed, .ephemeral]
        }
        let updater = Updater(configuration: config)
        var notified = 0
        updater.notify = { _ in notified += 1 }
        let item = await updater.check(manual: false)
        XCTAssertEqual(item?.release.version, AppVersion("2.0.0"))
        XCTAssertEqual(updater.route, "备用")
        XCTAssertEqual(notified, 1)
        updater.skipAvailableVersion()
        let skipped = await updater.check(manual: false)
        XCTAssertNil(skipped)
        guard case .skipped = updater.phase else { return XCTFail("应跳过这个版本") }
        _ = await updater.check(manual: true)
        guard case .available = updater.phase else { return XCTFail("手动检查应显示跳过的版本") }
        updater.automaticChecks = false
        updater.includePrereleases = true
        XCTAssertFalse(f.defaults.bool(forKey: "sample.automaticChecks"))
        XCTAssertTrue(f.defaults.bool(forKey: "sample.includePrereleases"))
        XCTAssertNotNil(updater.lastChecked)
        XCTAssertNil(updater.checkError)
    }

    func testFullUpdatePipelineExtractsValidatesReplacesAndRelaunches() async throws {
        for strategy in [InstallStrategy.staged, .atomicSwap] {
            let f = try UpdateFixture(); defer { f.cleanup() }
            try await f.makeApp(at: f.target, version: "1.0.0")
            let next = f.root.appendingPathComponent("new/Sample.app")
            try await f.makeApp(at: next, version: "2.0.0")
            let archive = f.root.appendingPathComponent("Sample.zip")
            let zip = try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", next.path, archive.path])
            XCTAssertTrue(zip.succeeded, zip.output)
            let size = try XCTUnwrap(archive.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            try f.writeFeed(digest: UpdateInstaller.sha256(of: archive), size: size)
            var config = f.configuration()
            config.installStrategy = strategy
            var relaunched = false
            config.relaunch = { target, previous in
                XCTAssertEqual(target.standardizedFileURL, f.target.standardizedFileURL)
                if strategy == .atomicSwap { XCTAssertNotNil(previous) }
                else { XCTAssertNil(previous) }
                relaunched = true
                return true
            }
            let updater = Updater(configuration: config)
            await updater.checkAndInstall()
            guard case .relaunching = updater.phase else { return XCTFail("\(updater.phase), \(String(describing: updater.lastFailure))") }
            XCTAssertTrue(relaunched)
            let plist = try Data(contentsOf: f.target.appendingPathComponent("Contents/Info.plist"))
            let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
            XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "2.0.0")
            XCTAssertTrue(CodeSignature.satisfies(f.target, requirement: nil))
            _ = Updater.finishPreviousUpdate(bundle: f.target)
        }
    }

    func testChannelFilteringCheckFailureAndCancellation() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }
        try f.writeFeed()
        let path = f.root.appendingPathComponent("latest.json")
        let stable = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var beta = stable
        beta["tag_name"] = "v3.0.0-rc.1"
        beta["prerelease"] = true
        try JSONSerialization.data(withJSONObject: [beta, stable]).write(to: path)
        let updater = Updater(configuration: f.configuration())
        let stableItem = await updater.check(manual: true)
        XCTAssertEqual(stableItem?.release.version, AppVersion("2.0.0"))
        updater.includePrereleases = true
        let betaItem = await updater.check(manual: true)
        XCTAssertEqual(betaItem?.release.version, AppVersion("3.0.0-rc.1"))
        try Data("broken json".utf8).write(to: path)
        let failed = await updater.check(manual: true)
        XCTAssertNil(failed)
        XCTAssertNotNil(updater.checkError)
        guard case .available = updater.phase else { return XCTFail("检查失败应保留上次版本") }
        setenv(f.prefix + "_UPDATE_URL", f.base.appendingPathComponent("slow").absoluteString, 1)
        // 取消可以发生在第一次挂起后、请求还没有交给 Foundation 的时刻。
        for _ in 0..<20 {
            let check = Task { await updater.check(manual: true) }
            while updater.phase != .checking { await Task.yield() }
            updater.cancel()
            let cancelled = await check.value
            XCTAssertNil(cancelled)
        }
        guard case .available = updater.phase else { return XCTFail("取消应恢复之前状态") }
        XCTAssertNil(updater.checkError)
    }

    func testMissingAssetsReportsFailureWithoutChangingCurrentApp() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }
        try await f.makeApp(at: f.target, version: "1.0.0")
        let release: [String: Any] = ["tag_name": "v2.0.0", "html_url": f.feed.absoluteString, "assets": []]
        try JSONSerialization.data(withJSONObject: release).write(to: f.root.appendingPathComponent("latest.json"))
        let updater = Updater(configuration: f.configuration())
        await updater.checkAndInstall()
        XCTAssertEqual(updater.lastFailure, .noArchive)
        guard case .failed(_, .noArchive) = updater.phase else { return XCTFail("\(updater.phase)") }
        XCTAssertTrue(CodeSignature.satisfies(f.target, requirement: nil))
    }

    func testFinishPreviousUpdateReturnsRejectedVersionAndCleansOwnDirectories() async throws {
        let f = try UpdateFixture(); defer { f.cleanup() }
        try await f.makeApp(at: f.target, version: "1.0.0", signed: false)
        let backup = f.target.deletingLastPathComponent().appendingPathComponent(".Sample.app.previous")
        let rejected = URL(fileURLWithPath: backup.path + ".rejected")
        try await f.makeApp(at: backup, version: "1.0.0", signed: false)
        try await f.makeApp(at: rejected, version: "2.0.0", signed: false)
        XCTAssertEqual(Updater.finishPreviousUpdate(bundle: f.target), "2.0.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.target.path))
    }
}

private final class UnavailableProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
    override func stopLoading() { }
}
#endif
