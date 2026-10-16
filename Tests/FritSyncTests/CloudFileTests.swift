#if os(macOS)
import Foundation
import XCTest
import FritCore
@testable import FritSync

private enum FixtureError: Error, Equatable { case innerVersion, rejected }

/// 合成兼容夹具，不是用户导出；业务字段合并仍属于App。
private struct FileContent: SyncContent {
    static let format = 1
    var schema: Int
    var values: [String: Int]
    var isEmptyForSync: Bool { values.isEmpty }
    init(_ values: [String: Int]) { schema = 1; self.values = values }
    func merging(cloud: Self) -> Self { Self(values.merging(cloud.values) { _, remote in remote }) }
    enum CodingKeys: CodingKey { case schema, values }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        guard schema <= 1 else { throw FixtureError.innerVersion }
        values = try container.decode([String: Int].self, forKey: .values)
    }
}

final class CloudFileTests: XCTestCase {
    private typealias Document = SyncDocument<FileContent>
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func document(_ values: [String: Int]) -> Document {
        Document(updatedAt: Date(timeIntervalSince1970: 1700000000), device: "fixture", content: FileContent(values))
    }

    func testMissingRoundTripAndReconcileRunOnBackgroundWorker() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try CloudFile<FileContent>(at: root.appendingPathComponent("sub/sync.json"))
        let missing = try await file.read()
        XCTAssertNil(missing)
        let original = document(["中文": 1])
        let written = try await file.update(original, base: nil) { base, proposed, current in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertNil(base); XCTAssertNil(current)
            return proposed
        }
        let read = try await file.read()
        XCTAssertEqual(written, original); XCTAssertEqual(read, original)
    }

    func testPurposeDocumentIsReadAgainInsideWriteCoordination() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sync.json")
        let first = try CloudFile<FileContent>(at: url)
        let second = try CloudFile<FileContent>(at: url)
        try await first.update(document(["base": 1]), base: nil) { _, proposed, _ in proposed }
        let initialValue = try await first.read()
        let initial = try XCTUnwrap(initialValue)
        try await second.update(document(["base": 1, "remote": 2]), base: nil) { _, proposed, _ in proposed }
        let result = try await first.update(document(["base": 1, "local": 3]), base: initial.content) { base, proposed, current in
            XCTAssertEqual(base?.values, ["base": 1])
            let remote = try XCTUnwrap(current)
            XCTAssertEqual(remote.content.values["remote"], 2)
            var merged = proposed
            merged.content = proposed.content.merging(cloud: remote.content)
            return merged
        }
        XCTAssertEqual(result.content.values, ["base": 1, "local": 3, "remote": 2])
    }

    func testIndependentInstancesSerializeConcurrentReadModifyWrites() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sync.json")
        let files = try [CloudFile<FileContent>(at: url), CloudFile<FileContent>(at: url)]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                let proposed = document(["key-\(index)": index])
                group.addTask {
                    _ = try await files[index % 2].update(proposed, base: nil) { _, proposed, current in
                        var merged = proposed
                        if let current { merged.content = proposed.content.merging(cloud: current.content) }
                        return merged
                    }
                }
            }
            try await group.waitForAll()
        }
        let readValue = try await files[0].read()
        let read = try XCTUnwrap(readValue)
        XCTAssertEqual(read.content.values.count, 20)
        for index in 0..<20 { XCTAssertEqual(read.content.values["key-\(index)"], index) }
    }

    func testUnreadableOuterInnerAndMalformedDocumentsAreNeverOverwritten() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sync.json")
        let file = try CloudFile<FileContent>(at: url)
        let proposed = document(["local": 1])
        for text in [#"{"format":2,"content":"future"}"#,
                     #"{"format":1,"content":{"schema":2,"values":{}}}"#,
                     "broken-json"] {
            let data = Data(text.utf8)
            try data.write(to: url)
            do { _ = try await file.update(proposed, base: nil) { _, proposed, _ in
                XCTFail("读不懂目的文档时不能进入合并"); return proposed
            }; XCTFail("必须拒绝覆盖") } catch { }
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testPlaceholderAndOversizedFilesAreRetained() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sync.json")
        let placeholder = root.appendingPathComponent(".sync.json.icloud")
        let file = try CloudFile<FileContent>(at: url, maxDocumentBytes: 512)
        try Data("placeholder".utf8).write(to: placeholder)
        do { _ = try await file.read(); XCTFail("占位不是空文件") }
        catch { XCTAssertEqual(error as? CloudFileError, .notDownloaded) }
        do { try await file.update(document([:]), base: nil) { _, proposed, _ in proposed }; XCTFail("不能覆盖占位") }
        catch { XCTAssertEqual(error as? CloudFileError, .notDownloaded) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: placeholder, encoding: .utf8), "placeholder")
        try FileManager.default.removeItem(at: placeholder)
        let data = Data(repeating: 65, count: 513); try data.write(to: url)
        do { try await file.update(document([:]), base: nil) { _, proposed, _ in proposed }; XCTFail("不能覆盖超限文件") }
        catch { XCTAssertEqual(error as? CloudFileError, .documentTooLarge(512)) }
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testRejectedMergeAndFutureOutputPreserveExistingBytes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sync.json")
        let old = document(["old": 1]); try old.encoded().write(to: url)
        let bytes = try Data(contentsOf: url)
        let file = try CloudFile<FileContent>(at: url)
        do { try await file.update(document(["new": 2]), base: nil) { _, _, _ in throw FixtureError.rejected }; XCTFail() }
        catch { XCTAssertEqual(error as? FixtureError, .rejected) }
        do { try await file.update(document(["new": 2]), base: nil) { _, proposed, _ in
            var future = proposed; future.format = 2; return future
        }; XCTFail() } catch { XCTAssertEqual(error as? SyncDocumentError, .newerFormat(2)) }
        do { try await file.update(document(["new": 2]), base: nil) { _, proposed, _ in
            var future = proposed; future.content.schema = 2; return future
        }; XCTFail() } catch { XCTAssertEqual(error as? FixtureError, .innerVersion) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let missing = root.appendingPathComponent("never-created/sync.json")
        let newFile = try CloudFile<FileContent>(at: missing)
        var future = document([:]); future.content.schema = 2
        do { try await newFile.update(future, base: nil) { _, proposed, _ in proposed }; XCTFail() }
        catch { XCTAssertEqual(error as? FixtureError, .innerVersion) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
    }

    func testAtomicWriteFailureDoesNotRemoveOriginal() async throws {
        let root = try directory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("sync.json")
        let old = document(["old": 1]); try old.encoded().write(to: url)
        let bytes = try Data(contentsOf: url)
        let file = try CloudFile<FileContent>(at: url)
        do { try await file.update(document(["new": 2]), base: nil) { _, proposed, _ in
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
            return proposed
        }; XCTFail("只读目录不能原子替换") } catch { }
        let permissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o500) // 确认实际进入回调，不能用更早的错误冒充原子写失败。
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testPreCancelledOperationNeverCreatesFile() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sync.json")
        let file = try CloudFile<FileContent>(at: url)
        let proposed = document(["local": 1])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await file.update(proposed, base: nil) { _, proposed, _ in proposed }
        }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try CloudFile<FileContent>(at: URL(string: "https://example.com/sync.json")!))
    }
}
#endif
