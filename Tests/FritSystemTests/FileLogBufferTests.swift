import Foundation
import XCTest
@testable import FritSystem
#if os(macOS)
import OSLog
#endif

final class FileLogBufferTests: XCTestCase {
    func testActiveBatchSharesBudgetAndPendingErrorsSurviveInfoOverload() {
        let buffer = FileLogBuffer(bytes: 512, records: 3)
        XCTAssertTrue(buffer.append(Data("active".utf8), error: false))
        let active = buffer.take(limit: 1)
        XCTAssertFalse(buffer.append(Data("old-info".utf8), error: false))
        XCTAssertFalse(buffer.append(Data("error-one".utf8), error: true))
        XCTAssertFalse(buffer.append(Data("error-two".utf8), error: true))
        XCTAssertFalse(buffer.append(Data("new-info".utf8), error: false))
        XCTAssertEqual(buffer.droppedRecords, 2)
        XCTAssertEqual(buffer.retained.records, 3) // 含仍在写入的第一条。
        XCTAssertLessThanOrEqual(buffer.retained.bytes, 512)
        XCTAssertTrue(buffer.finish(active, reschedule: true))
        let next = buffer.take()
        XCTAssertEqual(next.records.map { String(decoding: $0.message, as: UTF8.self) }, ["error-one", "error-two"])
        XCTAssertEqual(next.drops.info, 2)
        XCTAssertEqual(next.drops.error, 0)
        XCTAssertFalse(buffer.finish(next, reschedule: true))
        XCTAssertEqual(buffer.retained.bytes, 0)
        XCTAssertTrue(buffer.append(Data(), error: false)) // 完成后可以启动新 drain。
    }

    func testByteBudgetEmptyRecordsAndAllErrorReplacementHaveExplicitCounts() {
        let bytes = FileLogBuffer(bytes: 256, records: 100)
        for _ in 0..<100 { _ = bytes.append(Data(repeating: 65, count: 100), error: true) }
        XCTAssertEqual(bytes.retained.records, 1)
        XCTAssertEqual(bytes.droppedRecords, 99)
        let batch = bytes.take()
        XCTAssertEqual(batch.drops.error, 99)
        _ = bytes.finish(batch, reschedule: true)
        let empty = FileLogBuffer(bytes: -1, records: 0)
        for _ in 0..<100 { _ = empty.append(Data(), error: false) }
        XCTAssertEqual(empty.retained.records, 1)
        XCTAssertEqual(empty.retained.bytes, 64)
        XCTAssertEqual(empty.droppedRecords, 99)
    }

    func testFlushSnapshotExcludesFutureRecordsAndRegularDrainsAreFinite() {
        let buffer = FileLogBuffer(bytes: 1 << 20, records: 100)
        for index in 0..<10 { _ = buffer.append(Data("before-\(index)".utf8), error: false) }
        let watermark = buffer.watermark
        for index in 0..<70 { _ = buffer.append(Data("after-\(index)".utf8), error: false) }
        let flush = buffer.take(upTo: watermark, limit: buffer.recordLimit)
        XCTAssertEqual(flush.records.count, 10)
        _ = buffer.finish(flush, reschedule: false)
        let regular = buffer.take()
        XCTAssertEqual(regular.records.count, 32)
        XCTAssertEqual(String(decoding: regular.records[0].message, as: UTF8.self), "after-0")
        XCTAssertTrue(buffer.finish(regular, reschedule: true))
        XCTAssertEqual(buffer.retained.records, 38)
    }

    func testInFlightErrorCannotBeEvictedAndRejectedErrorStillGetsSummary() {
        let buffer = FileLogBuffer(bytes: 128, records: 1)
        _ = buffer.append(Data("first-error".utf8), error: true)
        let active = buffer.take()
        _ = buffer.append(Data("second-error".utf8), error: true)
        XCTAssertEqual(buffer.droppedRecords, 1)
        XCTAssertTrue(buffer.finish(active, reschedule: true))
        let summary = buffer.take()
        XCTAssertTrue(summary.records.isEmpty)
        XCTAssertEqual(summary.drops.error, 1)
        XCTAssertFalse(buffer.finish(summary, reschedule: true))
    }

    func testConcurrentProducersStayWithinBothBudgetsAndAccountForEveryRecord() {
        let buffer = FileLogBuffer(bytes: 4096, records: 16)
        DispatchQueue.concurrentPerform(iterations: 1000) { index in
            _ = buffer.append(Data("record-\(index)".utf8), error: index % 10 == 0)
            XCTAssertLessThanOrEqual(buffer.retained.bytes, 4096)
            XCTAssertLessThanOrEqual(buffer.retained.records, 16)
        }
        let result = buffer.take(limit: 16)
        XCTAssertEqual(UInt64(result.records.count) + result.drops.info + result.drops.error, 1000)
        XCTAssertTrue(result.records.allSatisfy(\.error))
        XCTAssertEqual(result.records.map(\.sequence), result.records.map(\.sequence).sorted())
        XCTAssertFalse(buffer.finish(result, reschedule: true))
    }

    private final class WriteGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var first = true
        private(set) var timedOut = false
        func beforeWrite() {
            lock.lock()
            let block = first
            first = false
            lock.unlock()
            if block {
                entered.signal()
                let timeout = resume.wait(timeout: .now() + 5) == .timedOut
                lock.lock(); timedOut = timeout; lock.unlock()
            }
        }
    }

    func testSlowRealWriterPreservesErrorRedactionAndSharedFlush() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("log.txt")
        let gate = WriteGate()
        // 失败也释放实际写队列；不用固定 sleep 猜测慢写入是否已经开始。
        defer { gate.resume.signal() }
        let log = FileLog(fileURL: url, pendingBytes: 1024, pendingRecords: 4,
                          redact: { $0.replacingOccurrences(of: "secret", with: "[redacted]") },
                          beforeFileWrite: { gate.beforeWrite() })
        log.info("first secret 中文")
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        for index in 0..<1000 { log.info("overload-\(index) secret 中文") }
        let copy = log
        copy.error("last-error secret 中文")
        XCTAssertGreaterThan(log.droppedRecords, 0)
        gate.resume.signal()
        copy.flush()
        let text = log.tail()
        XCTAssertFalse(gate.timedOut)
        XCTAssertTrue(text.contains("INFO first [redacted] 中文"))
        XCTAssertTrue(text.contains("ERROR last-error [redacted] 中文"))
        XCTAssertTrue(text.contains("FileLog dropped INFO="))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertEqual(log.droppedRecords, copy.droppedRecords)
    }

    func testTinyPendingByteBudgetClipsOnlyRedactedUTF8Tail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("log.txt")
        let log = FileLog(subsystem: "FritTests", fileURL: url,
                          redact: { $0.replacingOccurrences(of: "secret", with: "[redacted]") },
                          pendingBytes: 80, pendingRecords: 1)
        log.error(String(repeating: "secret中文", count: 100_000))
        let text = log.tail()
        XCTAssertTrue(text.contains("中文"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertLessThanOrEqual(text.utf8.count, 27 + 16)
        XCTAssertEqual(log.droppedRecords, 0)
    }

    func testEmptyAndFourByteTailStayValidWithMinimalBudgets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = FileLog(subsystem: "FritTests", fileURL: root.appendingPathComponent("empty.log"), pendingBytes: 64)
        empty.info("")
        XCTAssertTrue(empty.tail().hasSuffix("INFO "))
        let emoji = FileLog(subsystem: "FritTests", fileURL: root.appendingPathComponent("emoji.log"), pendingBytes: 70)
        emoji.error("🙂🙂") // 6字节的尾部从延续字节开始，只保留一个完整字符。
        XCTAssertTrue(emoji.tail().hasSuffix("ERROR 🙂"))
        let bridged = NSString(format: "%@", String(repeating: "外部字符串🙂", count: 1000)) as String
        emoji.error(bridged)
        XCTAssertTrue(emoji.tail(lines: 1).hasSuffix("ERROR 🙂"))
    }

    func testColdTailBoundsOversizedExistingFileWithoutRewritingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("old.log")
        let content = String(repeating: "中文🙂\n", count: 100_000)
        try content.write(to: url, atomically: true, encoding: .utf8)
        let log = FileLog(subsystem: "FritTests", fileURL: url, maxSize: 64)
        let tail = log.tail()
        XCTAssertFalse(tail.isEmpty)
        XCTAssertTrue(tail.hasSuffix("中文🙂"))
        XCTAssertLessThanOrEqual(tail.utf8.count, 64)
        XCTAssertEqual(try Data(contentsOf: url).count, content.utf8.count)
        XCTAssertEqual(log.tail(lines: 1), "中文🙂")
        XCTAssertEqual(log.tail(lines: 0), "")
    }

    #if os(macOS)
    func testActualSystemAndFileOutputsBothReceiveRedactedMessage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let subsystem = "io.github.frit.tests." + UUID().uuidString
        let marker = "redaction-" + UUID().uuidString
        let log = FileLog(subsystem: subsystem, fileURL: root.appendingPathComponent("log.txt"),
                          redact: { $0.replacingOccurrences(of: "secret", with: "[redacted]") })
        log.error(marker + " secret 中文")
        XCTAssertTrue(log.tail().contains(marker + " [redacted] 中文"))
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(timeIntervalSinceLatestBoot: 0)
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        var message: String?
        repeat {
            message = try store.getEntries(at: position, matching: predicate)
                .compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
                .first { $0.contains(marker) }
            if message != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        XCTAssertEqual(try XCTUnwrap(message), marker + " [redacted] 中文")
    }
    #endif
}
