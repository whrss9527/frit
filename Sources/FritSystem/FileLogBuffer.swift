#if os(macOS) || os(Linux)
import Foundation

/// 锁只保护内存，不在锁内调用脱敏、系统日志或文件写入。
final class FileLogBuffer: @unchecked Sendable {
    struct Record: Sendable {
        let sequence: UInt64
        let date: Date
        let error: Bool
        let message: Data
        // 同时按条数限制元数据开销；这不是对 Swift 分配器 RSS 的精确估计。
        var cost: Int { message.count + 64 }
    }

    struct Drops: Sendable {
        var info: UInt64 = 0
        var error: UInt64 = 0
        var any: Bool { info != 0 || error != 0 }
    }

    struct Batch: Sendable {
        let records: [Record]
        let drops: Drops
    }

    let byteLimit: Int
    let recordLimit: Int
    private let lock = NSLock()
    private var records: [Record] = []
    private var activeCount = 0
    private var retainedBytes = 0
    private var sequence: UInt64 = 0
    private var drops = Drops()
    private var totalDropped: UInt64 = 0
    private var scheduled = false

    init(bytes: Int, records: Int) {
        byteLimit = max(bytes, 64)
        recordLimit = max(records, 1)
    }

    var messageLimit: Int { min(byteLimit - 64, 64 * 1024) }

    /// 返回是否需要启动唯一的 drain；运行中批次仍占用预算，不能被淘汰。
    func append(_ message: Data, error: Bool) -> Bool {
        precondition(message.count <= messageLimit)
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        let record = Record(sequence: sequence, date: Date(), error: error, message: message)
        while records.count + activeCount >= recordLimit || retainedBytes > byteLimit - record.cost {
            let victim = records.firstIndex { !$0.error } ?? (error ? records.indices.first : nil)
            guard let victim else {
                dropped(error: error)
                return schedule()
            }
            let removed = records.remove(at: victim)
            retainedBytes -= removed.cost
            dropped(error: removed.error)
        }
        records.append(record)
        retainedBytes += record.cost
        return schedule()
    }

    private func schedule() -> Bool {
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    private func dropped(error: Bool) {
        if error { drops.error = drops.error == .max ? .max : drops.error + 1 }
        else { drops.info = drops.info == .max ? .max : drops.info + 1 }
        totalDropped = totalDropped == .max ? .max : totalDropped + 1
    }

    var watermark: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return sequence
    }

    var droppedRecords: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return totalDropped
    }

    /// 仅串行写队列调用；flush 固定水位与一次有界快照，不追赶后续生产者。
    func take(upTo watermark: UInt64 = .max, limit: Int = 32) -> Batch {
        lock.lock(); defer { lock.unlock() }
        precondition(activeCount == 0)
        let count = records.prefix { $0.sequence <= watermark }.prefix(limit).count
        let result = Array(records.prefix(count))
        records.removeFirst(count)
        activeCount = count
        let snapshot = drops
        drops = Drops()
        return Batch(records: result, drops: snapshot)
    }

    func finish(_ batch: Batch, reschedule: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        retainedBytes -= batch.records.reduce(0) { $0 + $1.cost }
        activeCount = 0
        if reschedule {
            if !records.isEmpty || drops.any { return true }
            scheduled = false
        }
        return false
    }

    // 供确定性的慢写入/在途预算测试使用，不作为公开性能指标。
    var retained: (bytes: Int, records: Int) {
        lock.lock(); defer { lock.unlock() }
        return (retainedBytes, records.count + activeCount)
    }
}
#endif
