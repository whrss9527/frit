#if os(macOS) || os(Linux)
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// 取消标记可从调用线程立即设置；其余可变状态全部限于 execution.queue。
private final class ShellCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var requested: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// 只保留有界的输出尾部；移除旧块而不是反复复制整个大缓冲。
private struct ShellOutput {
    static let capacity = 8 * 1024 * 1024
    private static let marker = "[输出已截断，仅保留末尾 8 MiB]\n"
    private var chunks: [Data] = []
    private var first = 0
    private var size = 0
    private var truncated = false

    mutating func append(_ data: Data) {
        chunks.append(data)
        size += data.count
        if size > Self.capacity { truncated = true }
        let limit = truncated ? Self.capacity - Self.marker.utf8.count : Self.capacity
        while size > limit {
            let remove = min(chunks[first].count, size - limit)
            if remove == chunks[first].count { chunks[first] = Data(); first += 1 }
            else { chunks[first] = Data(chunks[first].dropFirst(remove)) }
            size -= remove
        }
        if first >= 128 { chunks = Array(chunks.dropFirst(first)); first = 0 }
    }

    var text: String {
        var data = Data()
        data.reserveCapacity(size)
        for chunk in chunks.dropFirst(first) { data.append(chunk) }
        let aligned = truncated ? data.drop(while: { $0 & 0xc0 == 0x80 }) : data[...]
        var text = String(decoding: aligned, as: UTF8.self)
        // 原始字节未超限时非法字节也可能膨胀；两种情况都显示标记并限制返回值。
        guard truncated || text.utf8.count > Self.capacity else { return text }
        let limit = Self.capacity - Self.marker.utf8.count
        if text.utf8.count > limit {
            let tail = Array(text.utf8.suffix(limit)).drop(while: { $0 & 0xc0 == 0x80 })
            text = String(decoding: tail, as: UTF8.self)
        }
        return Self.marker + text
    }
}

/// 一个 Dispatch worker 同时观察直接 child、非阻塞 IO、取消和单调截止时间。
/// 没有 DispatchSource 的 FD 注册生命周期，也没有返回后排空输出的 Swift Task。
final class FritShellExecution: @unchecked Sendable {
    private static let launchLock = NSLock()
    private let queue = DispatchQueue(label: "FritSystem.Shell", qos: .userInitiated)
    private let cancellation = ShellCancellation()
    private let executable: String
    private let arguments: [String]
    private let timeout: TimeInterval
    private var pid: pid_t = 0 // 只在本次执行的 worker 内访问。

    init(executable: String, arguments: [String], timeout: TimeInterval) {
        self.executable = URL(fileURLWithPath: executable).path
        self.arguments = arguments
        self.timeout = timeout.isFinite ? max(timeout, 0) : 20
    }

    func start(_ completion: @escaping @Sendable (Result<ShellResult, Error>) -> Void) {
        queue.async {
            completion(Result { try self.execute() })
        }
    }
    func cancel() { cancellation.set() }
    private func error(_ code: Int32) -> ShellError {
        .launchFailed((executable as NSString).lastPathComponent, String(cString: strerror(code)))
    }
    private var now: TimeInterval { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    private func execute() throws -> ShellResult {
        let launched = try launch()
        var descriptor = launched.descriptor
        var ownsGroup = launched.ownsGroup
        defer { if descriptor >= 0 { close(descriptor) } }
        let deadline = now + timeout
        var cleanupDeadline: TimeInterval?
        var failure: Error?
        var exited = false
        var eof = false
        var escalated = false
        var fallbackWait = false
        var status: Int32 = 0
        var output = ShellOutput()
        var bytes = [UInt8](repeating: 0, count: 65536)

        func signal(_ value: Int32) {
            guard pid > 0 else { return }
            // 正常路径的 waitid(WNOWAIT) 保留 PID，最后回收前不会复用身份。
            if ownsGroup { kill(-pid, value) }
            else if !exited { kill(pid, value) }
        }
        func stop(_ reason: Error) {
            guard failure == nil else { return }
            failure = reason
            signal(SIGTERM)
            cleanupDeadline = now + 2
        }
        func observeExit() {
            guard !exited, pid > 0 else { return }
            if !fallbackWait {
                var information = siginfo_t()
                var result: Int32
                repeat {
                    result = waitid(P_PID, UInt32(pid), &information, WEXITED | WNOWAIT | WNOHANG)
                } while result == -1 && errno == EINTR
                if result == 0 {
                    exited = information.si_signo != 0
                    return
                }
                let reason = errno
                if reason == ECHILD {
                    // 外部代码已回收 child，旧 PID 不能再用于信号。
                    pid = 0; ownsGroup = false; exited = true
                    failure = failure ?? error(reason)
                    cleanupDeadline = now
                    return
                }
                // 不支持或失败的 waitid 改用 waitpid；提前回收后不再向旧组发信号。
                fallbackWait = true
                let owned = waitpid(pid, &status, WNOHANG)
                if owned == 0 { stop(error(reason)); return }
                if owned == pid || (owned == -1 && errno == ECHILD) {
                    pid = 0; ownsGroup = false; exited = true
                    stop(error(reason))
                    return
                }
                if owned == -1 && errno == EINTR { return }
                pid = 0; ownsGroup = false; exited = true
                failure = failure ?? error(reason)
                cleanupDeadline = now
                return
            }
            var result: pid_t
            repeat { result = waitpid(pid, &status, WNOHANG) } while result == -1 && errno == EINTR
            if result == pid || result == -1 {
                let reason = errno
                pid = 0; ownsGroup = false; exited = true
                if result == -1 { failure = failure ?? error(reason) }
            }
        }

        while true {
            observeExit()
            if cancellation.requested { stop(CancellationError()) }
            if now >= deadline { stop(ShellError.timeout((executable as NSString).lastPathComponent)) }
            if let cleanupDeadline, !escalated, now >= cleanupDeadline {
                signal(SIGKILL)
                escalated = true
            }
            if !eof {
                for _ in 0..<16 {
                    let count = read(descriptor, &bytes, bytes.count)
                    if count > 0 { output.append(Data(bytes.prefix(count))) }
                    else if count == 0 { eof = true; break }
                    else if errno == EINTR { continue }
                    else if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    else { eof = true; stop(error(errno)); break }
                }
            }
            // 短命命令的 EOF 与 child 退出通常相邻，避免不必要地再等一次 poll。
            if eof { observeExit() }
            if failure != nil {
                if escalated && exited { break }
            } else if exited && eof { break }

            let nextDeadline = failure == nil ? deadline : (escalated ? now + 0.05 : cleanupDeadline!)
            let milliseconds = Int32(max(0, min(50, ceil((nextDeadline - now) * 1000))))
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            // EOF 后不再 poll 可读 pipe，避免 HUP 空转；最多 50ms 再观察 child/取消。
            let result = poll(&event, eof ? 0 : 1, milliseconds)
            if result == -1 && errno != EINTR { eof = true; stop(error(errno)) }
            if result > 0 && event.revents & Int16(POLLNVAL) != 0 { eof = true; stop(error(EBADF)) }
        }

        // 没有其他 IO 回调：关闭 FD、回收直接 child 都在同一个 worker 内完成。
        close(descriptor); descriptor = -1
        if pid > 0 {
            var result: pid_t
            repeat {
                repeat { result = waitpid(pid, &status, WNOHANG) } while result == -1 && errno == EINTR
                if result == 0 {
                    var unused = pollfd()
                    _ = poll(&unused, 0, 50)
                }
            } while result == 0
            guard result == pid else {
                let reason = errno
                pid = 0
                throw error(reason)
            }
            pid = 0
        }
        if let failure { throw failure }
        let code = status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f
        return ShellResult(output: output.text, status: code)
    }

    private func launch() throws -> (descriptor: Int32, ownsGroup: Bool) {
        // 本库并发启动不能继承另一执行在 pipe→CLOEXEC 设置窗口中的临时管道。
        Self.launchLock.lock()
        defer { Self.launchLock.unlock() }
        guard !cancellation.requested else { throw CancellationError() }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw error(errno) }
        var launched = false
        defer {
            close(descriptors[1])
            if !launched { close(descriptors[0]) }
        }
        for index in descriptors.indices where descriptors[index] <= STDERR_FILENO {
            let moved = fcntl(descriptors[index], F_DUPFD, STDERR_FILENO + 1)
            guard moved >= 0 else { throw error(errno) }
            close(descriptors[index]); descriptors[index] = moved
        }
        guard fcntl(descriptors[0], F_SETFL, fcntl(descriptors[0], F_GETFL) | O_NONBLOCK) != -1,
              fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) != -1,
              fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) != -1 else { throw error(errno) }
        guard !cancellation.requested else { throw CancellationError() }
        let result = spawn(readDescriptor: descriptors[0], writeDescriptor: descriptors[1])
        guard result == 0 else { throw error(result) }
        launched = true
        return (descriptors[0], getpgid(pid) == pid)
    }

    private func spawn(readDescriptor: Int32, writeDescriptor: Int32) -> Int32 {
        guard !executable.utf8.contains(0), !arguments.contains(where: { $0.utf8.contains(0) }) else { return EINVAL }
#if os(macOS)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
#else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
#endif
        var code = posix_spawn_file_actions_init(&actions)
        guard code == 0 else { return code }
        defer { posix_spawn_file_actions_destroy(&actions) }
        code = posix_spawnattr_init(&attributes)
        guard code == 0 else { return code }
        defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL); sigdelset(&defaults, SIGSTOP)
        for value in [posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
                      posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDOUT_FILENO),
                      posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDERR_FILENO),
                      posix_spawn_file_actions_addclose(&actions, readDescriptor),
                      posix_spawn_file_actions_addclose(&actions, writeDescriptor),
                      posix_spawnattr_setpgroup(&attributes, 0),
                      posix_spawnattr_setsigmask(&attributes, &mask),
                      posix_spawnattr_setsigdefault(&attributes, &defaults),
                      posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))] where value != 0 {
            return value
        }
        var argv = ([executable] + arguments).map { strdup($0) }
        var environment = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) }
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else { return ENOMEM }
        argv.append(nil); environment.append(nil)
        return argv.withUnsafeMutableBufferPointer { arguments in
            environment.withUnsafeMutableBufferPointer { variables in
                posix_spawn(&pid, executable, &actions, &attributes, arguments.baseAddress!, variables.baseAddress!)
            }
        }
    }
}
#endif
