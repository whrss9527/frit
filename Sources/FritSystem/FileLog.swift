#if os(macOS) || os(Linux)
import Foundation
#if canImport(os)
import os
#endif

/// 副本共享一条串行队列；格式化和文件读写都在这条队列内完成。
public struct FileLog: Sendable {
    private let storage: Storage

    public init(subsystem: String, fileURL: URL? = nil, maxSize: Int = 1 << 20,
                redact: @escaping @Sendable (String) -> String = { $0 }, messagePrefix: String = "") {
        storage = Storage(subsystem: subsystem, fileURL: fileURL, maxSize: max(maxSize, 1),
                          redact: redact, prefix: messagePrefix)
    }

    public func info(_ message: String) { storage.append("INFO", message) }
    public func error(_ message: String) { storage.append("ERROR", message) }
    public func flush() { storage.queue.sync {} }
    public func tail(lines: Int = 200) -> String { storage.tail(lines: max(lines, 0)) }

    /// 可变状态全部限于 queue；其他成员初始化后不变。
    private final class Storage: @unchecked Sendable {
        let queue: DispatchQueue
        let fileURL: URL?
        let maxSize: Int
        let redact: @Sendable (String) -> String
        let prefix: String
        let formatter: DateFormatter
        #if canImport(os)
        let logger: Logger
        #endif

        init(subsystem: String, fileURL: URL?, maxSize: Int, redact: @escaping @Sendable (String) -> String, prefix: String) {
            queue = DispatchQueue(label: subsystem + ".log")
            self.fileURL = fileURL
            self.maxSize = maxSize
            self.redact = redact
            self.prefix = prefix
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
            queue.async { [self] in
                guard let url = fileURL else { return }
                let line = "\(formatter.string(from: Date())) \(level) \(message)\n"
                var data = Data(line.utf8)
                // 单条过大的日志也不能突破上限，切分点跳过 UTF-8 延续字节。
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
        }

        func tail(lines maxLines: Int) -> String {
            queue.sync {
                guard let fileURL, let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
                return content.split(separator: "\n").suffix(maxLines).joined(separator: "\n")
            }
        }
    }
}
#endif
