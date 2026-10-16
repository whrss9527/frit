#if os(macOS) || os(Linux)
import Foundation
#if canImport(os)
import os
#endif

/// 副本共享有界缓冲与串行写队列；过载优先淘汰待写的较旧 INFO，并记录计数摘要。
public struct FileLog: Sendable {
    private let storage: Storage

    public init(subsystem: String, fileURL: URL? = nil, maxSize: Int = 1 << 20,
                redact: @escaping @Sendable (String) -> String = { $0 }, messagePrefix: String = "",
                pendingBytes: Int = 256 * 1024, pendingRecords: Int = 256) {
        storage = Storage(subsystem: subsystem, fileURL: fileURL, maxSize: max(maxSize, 1),
                          redact: redact, prefix: messagePrefix, pendingBytes: pendingBytes,
                          pendingRecords: pendingRecords)
    }

    public func info(_ message: String) { storage.append("INFO", message) }
    public func error(_ message: String) { storage.append("ERROR", message) }
    /// 累计过载丢弃条数（饱和计数）；文件轮转和写入失败不在此计数内。
    public var droppedRecords: UInt64 { storage.buffer.droppedRecords }
    public func flush() { storage.flush() }
    public func tail(lines: Int = 200) -> String { storage.tail(lines: max(lines, 0)) }

    // 仅测试用于确定性地阻塞实际文件写入，不扩展公开的日志回调接口。
    init(fileURL: URL, pendingBytes: Int, pendingRecords: Int,
         redact: @escaping @Sendable (String) -> String = { $0 },
         beforeFileWrite: @escaping @Sendable () -> Void) {
        storage = Storage(subsystem: "FritTests", fileURL: fileURL, maxSize: 1 << 20,
                          redact: redact, prefix: "",
                          pendingBytes: pendingBytes, pendingRecords: pendingRecords, beforeFileWrite: beforeFileWrite)
    }

    /// buffer 有自己的锁；formatter 与文件操作限于 queue。
    private final class Storage: @unchecked Sendable {
        let queue: DispatchQueue
        let fileURL: URL?
        let maxSize: Int
        let redact: @Sendable (String) -> String
        let prefix: String
        let formatter: DateFormatter
        let buffer: FileLogBuffer
        let beforeFileWrite: (@Sendable () -> Void)?
        #if canImport(os)
        let logger: Logger
        #endif

        init(subsystem: String, fileURL: URL?, maxSize: Int, redact: @escaping @Sendable (String) -> String,
             prefix: String, pendingBytes: Int, pendingRecords: Int,
             beforeFileWrite: (@Sendable () -> Void)? = nil) {
            queue = DispatchQueue(label: subsystem + ".log")
            self.fileURL = fileURL
            self.maxSize = maxSize
            self.redact = redact
            self.prefix = prefix
            buffer = FileLogBuffer(bytes: pendingBytes, records: pendingRecords)
            self.beforeFileWrite = beforeFileWrite
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            #if canImport(os)
            logger = Logger(subsystem: subsystem, category: "app")
            #endif
        }

        func append(_ level: String, _ original: String) {
            // 前缀也经过脱敏，系统日志和文件使用同一份结果。
            let message = redact(prefix + original)
            #if canImport(os)
            if level == "ERROR" { logger.error("\(message, privacy: .public)") }
            else { logger.info("\(message, privacy: .public)") }
            #endif
            guard fileURL != nil else { return }
            // 只复制有限尾部；不把完整消息捕获在每条 queue.async 闭包里。
            var bytes = Array(message.utf8.suffix(min(maxSize, buffer.messageLimit)))
            let start = bytes.firstIndex(where: { $0 & 0xc0 != 0x80 }) ?? bytes.endIndex
            bytes.removeFirst(start)
            if buffer.append(Data(bytes), error: level == "ERROR") {
                queue.async { [self] in drain() }
            }
        }

        private func drain() {
            let batch = buffer.take()
            write(batch)
            if buffer.finish(batch, reschedule: true) {
                queue.async { [self] in drain() }
            }
        }

        private func write(_ batch: FileLogBuffer.Batch) {
            for record in batch.records {
                let level = record.error ? "ERROR" : "INFO"
                let message = String(decoding: record.message, as: UTF8.self)
                writeLine("\(formatter.string(from: record.date)) \(level) \(message)\n")
            }
            if batch.drops.any {
                writeLine("\(formatter.string(from: Date())) WARN FileLog dropped INFO=\(batch.drops.info) ERROR=\(batch.drops.error)\n")
            }
        }

        private func writeLine(_ line: String) {
            guard let url = fileURL else { return }
            beforeFileWrite?()
            var data = Data(line.utf8)
            // 最终文件仍遵守原 maxSize 与 UTF-8 尾部截断语义。
            if data.count > maxSize {
                var start = data.count - maxSize
                while start < data.count, data[start] & 0xc0 == 0x80 { start += 1 }
                data = Data(data[start...])
            }
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > maxSize - data.count { try? manager.removeItem(at: url) }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch { }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }

        func flush() {
            let watermark = buffer.watermark
            queue.sync { writeThrough(watermark) }
        }

        private func writeThrough(_ watermark: UInt64) {
            let batch = buffer.take(upTo: watermark, limit: buffer.recordLimit)
            write(batch)
            _ = buffer.finish(batch, reschedule: false)
        }

        func tail(lines maxLines: Int) -> String {
            let watermark = buffer.watermark
            return queue.sync {
                writeThrough(watermark)
                guard let fileURL, let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
                return content.split(separator: "\n").suffix(maxLines).joined(separator: "\n")
            }
        }
    }
}
#endif
