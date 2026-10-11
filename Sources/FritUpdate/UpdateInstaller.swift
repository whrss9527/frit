#if os(macOS)
import CryptoKit
import Foundation
import FritCore
import FritSystem

public enum UpdateInstaller {
    public static func download(_ url: URL, expectedSize: Int?, to destination: URL,
                                session configuration: URLSessionConfiguration = .ephemeral,
                                userAgent: String = "FritUpdate", progress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        guard destination.isFileURL, expectedSize.map({ $0 >= 0 }) ?? true else { throw UpdateError.badResponse }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let delegate = DownloadDelegate(destination: destination, expectedSize: expectedSize, progress: progress)
        let options = configuration.copy() as! URLSessionConfiguration
        options.timeoutIntervalForRequest = 30
        options.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: options, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.begin(continuation)
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    public static func verify(archive: URL, candidate: UpdateCandidate,
                              fetch: @Sendable (URL) async throws -> Data, log: UpdateLogger = .osLog) async throws {
        guard let asset = candidate.archive else { throw UpdateError.noArchive }
        let expected: String
        if let digest = asset.sha256 { expected = digest }
        else if let url = candidate.checksums?.downloadURL {
            let text = String(decoding: try await fetch(url), as: UTF8.self)
            guard let hash = try? GitHubRelease.expectedSHA256(for: asset, checksums: text) else { throw UpdateError.checksumsMissing }
            expected = hash
        } else { throw UpdateError.noArchive }
        let actual = try await background { try sha256(of: archive) }
        try Task.checkCancellation()
        guard actual == expected else { throw UpdateError.checksumMismatch }
        log.info("更新包校验通过（SHA-256 \(actual.prefix(12))…）")
    }

    public static func extract(archive: URL, to directory: URL, appName: String? = nil) async throws -> URL {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path], timeout: 120)
        guard result.succeeded else { throw UpdateError.extract(result.trimmedOutput) }
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let filename = appName.map { $0.hasSuffix(".app") ? $0 : $0 + ".app" }
        guard let app = items.first(where: { $0.pathExtension == "app" && (filename == nil || $0.lastPathComponent == filename) }) else {
            throw UpdateError.appNotFound
        }
        _ = try? await Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    public static func validate(app: URL, expectedVersion: AppVersion, expectedIdentifier: String? = nil,
                                signer: [SignerPolicy] = [.sameTeamAsCurrent], strict: StrictChecks = []) async throws {
        guard strict.isEmpty else { throw UpdateError.unsupportedChecks }
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw UpdateError.wrongApp("读不到 Info.plist")
        }
        let identifier = plist["CFBundleIdentifier"] as? String ?? ""
        if let expectedIdentifier, identifier != expectedIdentifier { throw UpdateError.wrongApp("bundle identifier 是 \(identifier)") }
        guard let text = plist["CFBundleShortVersionString"] as? String, AppVersion(text) == expectedVersion else {
            throw UpdateError.wrongApp("版本不是 \(expectedVersion)")
        }
        let result = try await Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 120)
        guard result.succeeded else { throw UpdateError.wrongApp("签名校验失败：\(result.trimmedOutput)") }
        guard signer.contains(where: { CodeSignature.accepts(app, policy: $0) }) else { throw UpdateError.wrongSigner }
    }

    /// staged 复刻 Stox 的两步 move；管理员回退复用同一份脚本和来源选择。
    @discardableResult
    public static func install(newApp: URL, replacing target: URL, strategy: InstallStrategy = .staged,
                               log: UpdateLogger = .osLog) async throws -> URL? {
        try Task.checkCancellation()
        let parent = target.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".\(target.lastPathComponent).update")
        let backup = parent.appendingPathComponent(".\(target.lastPathComponent).previous")
        do {
            try await background { try StagedReplacement.swap(newApp: newApp, target: target, staged: staged, backup: backup) }
        } catch let error as NSError where isBlockedBySystem(error) {
            throw UpdateError.appManagement
        } catch let error as NSError where needsAdmin(error) {
            log.info("替换程序需要管理员权限，改用授权对话框（\(error.localizedDescription)）")
            let source = StagedReplacement.source(newApp: newApp, staged: staged)
            let script = StagedReplacement.privilegedScript(source: source, target: target, staged: staged, backup: backup)
            let appleScript = "do shell script " + Shell.appleScriptString(script) + " with administrator privileges"
            let result = try await Shell.run("/usr/bin/osascript", ["-e", appleScript], timeout: 300)
            guard result.succeeded else {
                if result.output.contains("-128") { throw UpdateError.cancelledByUser }
                if result.output.localizedCaseInsensitiveContains("Operation not permitted") { throw UpdateError.appManagement }
                throw UpdateError.install(result.trimmedOutput)
            }
        } catch {
            throw UpdateError.install(error.localizedDescription)
        }
        return nil
    }

    public static func posixCode(_ error: NSError) -> Int? {
        if error.domain == NSPOSIXErrorDomain { return error.code }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return posixCode(underlying) }
        return nil
    }
    public static func needsAdmin(_ error: NSError) -> Bool {
        if let code = posixCode(error) { return code == Int(EACCES) }
        return error.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code)
    }
    public static func isBlockedBySystem(_ error: NSError) -> Bool { posixCode(error) == Int(EPERM) }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// completion 受锁保护，其余值不可变；URLSession 的回调最多完成一次 continuation。
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let expectedSize: Int?
    let progress: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var completion: CheckedContinuation<Void, Error>?

    init(destination: URL, expectedSize: Int?, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.progress = progress
    }
    func begin(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock(); completion = continuation; lock.unlock()
    }
    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = completion
        completion = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Int64(expectedSize ?? 0)
        progress(total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(UpdateError.server(http.statusCode))); return
        }
        do {
            if let expectedSize {
                let actual = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard actual == expectedSize else { throw UpdateError.sizeMismatch }
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
        } else { finish(.failure(UpdateError.badResponse)) }
    }
}
#endif
