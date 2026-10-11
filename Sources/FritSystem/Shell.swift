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

/// 读写都受锁保护；Process 自己的退出信号不能被误判成计时器超时。
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func set() { lock.lock(); fired = true; lock.unlock() }
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}

public enum Shell {
    /// 阻塞的管道读取在 Dispatch 工作线程上完成，不占用 Swift 协作线程池。
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try runSync(executable, arguments, timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// 同步入口会阻塞调用线程；界面和 async 代码应调用 run。
    public static func runSync(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() }
        catch { throw ShellError.launchFailed((executable as NSString).lastPathComponent, error.localizedDescription) }
        let fired = TimeoutFlag()
        let pid = process.processIdentifier
        // Foundation 通常为子进程建立独立进程组；只在确实属于该组时结束整组。
        // 否则 shell 的子进程可能一直持有管道，父进程退出也读不到 EOF。
        let ownsGroup = getpgid(pid) == pid
        let escalation = DispatchWorkItem { [process] in
            if ownsGroup { kill(-pid, SIGKILL) }
            else if process.isRunning { kill(pid, SIGKILL) }
        }
        let timer = DispatchWorkItem { [process] in
            guard process.isRunning else { return }
            fired.set()
            if ownsGroup { kill(-pid, SIGTERM) } else { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: escalation)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + (timeout.isFinite ? max(timeout, 0) : 20), execute: timer)
        // 先读输出，否则管道写满时子进程和 waitUntilExit 会互相等待。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        escalation.cancel()
        if fired.value { throw ShellError.timeout((executable as NSString).lastPathComponent) }
        return ShellResult(output: String(decoding: data, as: UTF8.self), status: process.terminationStatus)
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
