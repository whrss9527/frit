// 仅验收脚本：唯一合成消息，不读取用户日志；原生峰值另由 time -l 保存。
import Foundation

@main enum Probe {
    static func metric(_ key: String) -> Int {
        let text = (try? String(contentsOfFile: "/proc/self/status", encoding: .utf8)) ?? ""
        return text.split(separator: "\n").first(where: { $0.hasPrefix(key + ":") })
            .flatMap { Int($0.split(whereSeparator: { $0 == " " || $0 == "\t" })[1]) } ?? -1
    }
    static func main() throws {
        let count = Int(CommandLine.arguments[1])!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bounded-file.log")
        let limit = 64 * 1024
        let log = FileLog(subsystem: "portfolio.synthetic.filelog", fileURL: url, maxSize: limit)
        let baseline = metric("VmRSS")
        let began = DispatchTime.now().uptimeNanoseconds
        let payload = String(repeating: "x", count: 8192)
        for index in 0..<count { log.info(payload + " synthetic-record=\(index)") }
        let submitted = DispatchTime.now().uptimeNanoseconds
        let queuedRSS = metric("VmRSS")
        log.flush()
        let flushed = DispatchTime.now().uptimeNanoseconds
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        let result: [String: Any] = ["records": count, "message_bytes_at_least": payload.utf8.count,
            "file_limit_bytes": limit, "actual_file_bytes": size,
            "baseline_rss_kb": baseline, "rss_after_submit_kb": queuedRSS, "peak_rss_kb": metric("VmHWM"),
            "submit_ms": Double(submitted - began) / 1e6, "synchronous_flush_ms": Double(flushed - submitted) / 1e6,
            "dropped_records": log.droppedRecords,
            "platform": "synthetic burst; /proc metrics are Linux-only (-1 elsewhere); native RSS from time -l"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
