#if os(macOS)
import Foundation

/// URLSession 可以在等待者注册之前完成（包括取消）；结果和 continuation 由锁保护。
final class AsyncResponse<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { waiting in
            lock.lock()
            if let result { lock.unlock(); waiting.resume(with: result) }
            else { continuation = waiting; lock.unlock() }
        }
    }
}
#endif
