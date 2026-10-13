#if os(macOS) || os(Linux)
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct ShellResult: Equatable, Sendable {
    public let output: String
    public let status: Int32
    public var succeeded: Bool { status == 0 }
    public var trimmedOutput: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }

    public init(output: String, status: Int32) {
        self.output = output
        self.status = status
    }
}

public enum ShellError: LocalizedError, Equatable, Sendable {
    case timeout(String)
    case launchFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let name): return "\(name) 执行超时"
        case .launchFailed(let name, let reason): return "无法运行 \(name)：\(reason)"
        }
    }
}

/// 同步入口只等内部 Dispatch 状态机；结果不通过 Swift Task 传回。
private final class ShellResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<ShellResult, Error>?
    func store(_ value: Result<ShellResult, Error>) { lock.lock(); result = value; lock.unlock() }
    func value() throws -> ShellResult {
        lock.lock()
        defer { lock.unlock() }
        return try result!.get()
    }
}

public enum Shell {
    /// 事件读取有截止和容量上限；取消返回前关闭读取并回收直接子进程。
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) async throws -> ShellResult {
        let execution = FritShellExecution(executable: executable, arguments: arguments, timeout: timeout)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                execution.start { continuation.resume(with: $0) }
            }
        } onCancel: {
            execution.cancel()
        }
    }

    /// 同步入口会阻塞调用线程；界面和 async 代码应调用 run。
    public static func runSync(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) throws -> ShellResult {
        let result = ShellResultBox()
        let done = DispatchSemaphore(value: 0)
        let execution = FritShellExecution(executable: executable, arguments: arguments, timeout: timeout)
        execution.start {
            result.store($0)
            done.signal()
        }
        done.wait()
        return try result.value()
    }

    public static func lookPath(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for directory in directories {
            let path = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    public static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
