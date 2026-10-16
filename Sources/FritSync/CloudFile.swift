import Foundation
import FritCore

#if os(macOS) || os(iOS)
public enum CloudFileError: Error, Equatable, Sendable {
    case invalidFileURL
    case notDownloaded
    case documentTooLarge(Int)
    case coordinationDidNotRun
}

/// 最小协调文件层；不查询账号/位置，不处理冲突版本、迁移或同步会话。
/// 来源：stox@5e54ee1 CloudFile.swift 的协调读-合并-写，补充目的格式与占位保护。
public final class CloudFile<Content: SyncContent>: @unchecked Sendable {
    public typealias Document = SyncDocument<Content>
    public typealias Reconcile = @Sendable (_ base: Content?, _ proposed: Document, _ current: Document?) throws -> Document

    public let url: URL
    public let maxDocumentBytes: Int
    private let unknownDevice: String
    private let queue = DispatchQueue(label: "FritSync.CloudFile." + UUID().uuidString)

    public init(at url: URL, maxDocumentBytes: Int = 8 * 1024 * 1024, unknownDevice: String = "") throws {
        guard url.isFileURL, !url.hasDirectoryPath, url.query == nil, url.fragment == nil else {
            throw CloudFileError.invalidFileURL
        }
        self.url = url
        self.maxDocumentBytes = min(max(maxDocumentBytes, 1), Int.max - 1)
        self.unknownDevice = unknownDevice
    }

    /// 不存在返回nil；占位、损坏、未知格式和协调错误仍是错误。
    public func read() async throws -> Document? {
        try await perform { [self] in
            try requireDownloaded(at: url)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            var error: NSError?
            var result: Result<Document?, Error>?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { readURL in
                result = Result { try self.load(at: readURL) }
            }
            if let error { throw error }
            guard let result else { throw CloudFileError.coordinationDidNotRun }
            return try result.get()
        }
    }

    /// 合并函数必须由App提供；在同一个写协调区重新读目的文件，成功编码后才原子替换。
    /// 不自动按时间覆盖，也不清理NSFileVersion；完整冲突/Engine阶段交付前不能替换App同步。
    @discardableResult
    public func update(_ proposed: Document, base: Content?, reconcile: @escaping Reconcile) async throws -> Document {
        try await perform { [self] in
            _ = try encode(proposed) // 无效本机格式不创建文件夹。
            try requireDownloaded(at: url)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var error: NSError?
            var result: Result<Document, Error>?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &error) { writeURL in
                result = Result {
                    let current = try self.load(at: writeURL)
                    let merged = try reconcile(base, proposed, current)
                    let data = try self.encode(merged)
                    try data.write(to: writeURL, options: .atomic)
                    return merged
                }
            }
            if let error { throw error }
            guard let result else { throw CloudFileError.coordinationDidNotRun }
            return try result.get()
        }
    }

    /// 独立Dispatch worker等协调IO；continuation仅在操作真正结束后返回。
    /// 调用前取消不入队；接纳后不提前报告取消，也不声称已撤销文件副作用。
    private func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: operation)) }
        }
    }

    private func requireDownloaded(at url: URL) throws {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw CloudFileError.notDownloaded
        }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus == .notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw CloudFileError.notDownloaded
        }
    }

    private func load(at url: URL) throws -> Document? {
        try requireDownloaded(at: url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        // 单次读入也有上限，不先把不可信的大文件全部加载到内存。
        while true {
            let remaining = maxDocumentBytes + 1 - data.count
            let chunk = try handle.read(upToCount: min(remaining, 64 * 1024)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count <= maxDocumentBytes else { throw CloudFileError.documentTooLarge(maxDocumentBytes) }
        }
        return try Document.decode(data, unknownDevice: unknownDevice)
    }

    private func encode(_ document: Document) throws -> Data {
        let data = try document.encoded()
        guard data.count <= maxDocumentBytes else { throw CloudFileError.documentTooLarge(maxDocumentBytes) }
        return data
    }
}
#endif
