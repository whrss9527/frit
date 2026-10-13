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

/// 直接子进程由本执行器创建独立进程组；保留退出 PID 到关闭 IO 后再回收。
/// 没有 Swift drain Task；等待直接子进程的 worker 不读取后代持有的管道。
final class FritShellExecution: @unchecked Sendable {
    // pipe→CLOEXEC 设置不是原子操作；本库并发启动不能继承另一执行的临时管道。
    private static let launchLock = NSLock()
    private let queue = DispatchQueue(label: "FritSystem.Shell", qos: .userInitiated)
    private let cancellation = ShellCancellation()
    private let executable: String
    private let arguments: [String]
    private let timeout: TimeInterval
    private var completion: (@Sendable (Result<ShellResult, Error>) -> Void)?
    private var reader: DispatchSourceRead?
    private var readerCancelled = false
    private var descriptor: Int32 = -1
    private var pid: pid_t = 0
    private var ownsGroup = false
    private var exited = false
    private var eof = false
    private var escalated = false
    private var finishing = false
    private var finished = false
    private var failure: Error?
    private var output = ShellOutput()
    private var timeoutItem: DispatchWorkItem?
    private var escalationItem: DispatchWorkItem?
    private var fallbackStatus: Int32?

    init(executable: String, arguments: [String], timeout: TimeInterval) {
        self.executable = URL(fileURLWithPath: executable).path
        self.arguments = arguments
        self.timeout = timeout.isFinite ? max(timeout, 0) : 20
    }

    func start(_ completion: @escaping @Sendable (Result<ShellResult, Error>) -> Void) {
        queue.async { self.begin(completion) }
    }

    func cancel() {
        cancellation.set()
        queue.async {
            guard self.completion != nil, !self.finishing, !self.finished else { return }
            if self.pid > 0 { self.stop(CancellationError()) }
            else { self.finish(.failure(CancellationError())) }
        }
    }

    private func error(_ code: Int32) -> ShellError {
        .launchFailed((executable as NSString).lastPathComponent, String(cString: strerror(code)))
    }

    private func begin(_ completion: @escaping @Sendable (Result<ShellResult, Error>) -> Void) {
        self.completion = completion
        guard !cancellation.requested else { finish(.failure(CancellationError())); return }
        Self.launchLock.lock()
        defer { Self.launchLock.unlock() }
        guard !cancellation.requested else { finish(.failure(CancellationError())); return }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { finish(.failure(error(errno))); return }
        // 调用方可能关闭了标准 FD；file actions 不能把管道误当作 stdin/stdout 关闭。
        for index in descriptors.indices where descriptors[index] <= STDERR_FILENO {
            let moved = fcntl(descriptors[index], F_DUPFD, STDERR_FILENO + 1)
            guard moved >= 0 else {
                let reason = error(errno)
                descriptors.forEach { close($0) }
                finish(.failure(reason)); return
            }
            close(descriptors[index])
            descriptors[index] = moved
        }
        descriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1,
              fcntl(writeDescriptor, F_SETFD, FD_CLOEXEC) != -1 else {
            let reason = error(errno)
            close(writeDescriptor)
            finish(.failure(reason)); return
        }
        if cancellation.requested {
            close(writeDescriptor)
            finish(.failure(CancellationError())); return
        }
        let launched = spawn(readDescriptor: descriptor, writeDescriptor: writeDescriptor)
        close(writeDescriptor)
        guard launched == 0 else { finish(.failure(error(launched))); return }
        ownsGroup = getpgid(pid) == pid
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        // handler 创建后保持不变；EOF 标记阻止再读取，最终只 cancel 一次。
        // FD 必须等 cancel handler 再关闭，不能通过复用句柄提前结束 source。
        reader.setEventHandler { [self] in readOutput(); completeIfReady() }
        reader.setCancelHandler { [self] in
            close(descriptor)
            descriptor = -1
            self.reader = nil
            if finishing { finishAfterClosingIO() }
            else { completeIfReady() }
        }
        self.reader = reader
        reader.resume()
        observeExit()
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stop(ShellError.timeout((self.executable as NSString).lastPathComponent))
        }
        timeoutItem = timer
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        if cancellation.requested { stop(CancellationError()) }
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
        var mask = sigset_t()
        var defaults = sigset_t()
        sigemptyset(&mask)
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL); sigdelset(&defaults, SIGSTOP)
        // 不继承 Swift runner 或调用方忽略/屏蔽的信号，保持独立命令的正常信号语义。
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

    private func observeExit() {
        let child = pid
        DispatchQueue.global(qos: .utility).async { [self] in
            var information = siginfo_t()
            var result: Int32
            repeat { result = waitid(P_PID, UInt32(child), &information, WEXITED | WNOWAIT) } while result == -1 && errno == EINTR
            let reason = result == 0 ? nil : errno
            queue.async {
                if let reason {
                    if reason == ECHILD {
                        // 其他代码回收了 child 时不能再用旧 PID 发信号。
                        self.pid = 0; self.ownsGroup = false; self.exited = true
                        self.finish(.failure(self.error(reason)))
                        return
                    }
                    self.stop(self.error(reason))
                    self.pollExitAfterWaitError()
                } else {
                    self.exited = true
                    self.completeIfReady()
                }
            }
        }
    }

    /// waitid 失败时仍用非阻塞 waitpid 回收；只在 queue 上回收，避免与信号并发。
    private func pollExitAfterWaitError() {
        guard !finished, !finishing else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result == -1 && errno == ECHILD) {
            fallbackStatus = result == pid ? status : 0
            pid = 0; ownsGroup = false; exited = true
            completeIfReady()
        } else {
            queue.asyncAfter(deadline: .now() + 0.01) { self.pollExitAfterWaitError() }
        }
    }

    private func signal(_ value: Int32) {
        guard pid > 0 else { return }
        // 正常路径还没有 waitpid：PID 仍保留，不会被新进程重用。
        if ownsGroup { kill(-pid, value) }
        else if !exited { kill(pid, value) }
    }

    private func stop(_ error: Error) {
        guard !finishing, !finished, failure == nil else { return }
        failure = error
        signal(SIGTERM)
        let escalation = DispatchWorkItem { [weak self] in
            guard let self, !self.finishing, !self.finished else { return }
            self.signal(SIGKILL)
            self.escalated = true
            self.completeIfReady()
        }
        escalationItem = escalation
        queue.asyncAfter(deadline: .now() + 2, execute: escalation)
    }

    private func readOutput() {
        guard !finishing, !finished, !eof else { return }
        var bytes = [UInt8](repeating: 0, count: 65536)
        for _ in 0..<16 {
            let count = read(descriptor, &bytes, bytes.count)
            if count > 0 { output.append(Data(bytes.prefix(count))) }
            else if count == 0 {
                eof = true
                return
            }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else { stop(error(errno)); return }
        }
        // 连续输出必须让出队列；可读 source 会再次触发，不另外堆积排空任务。
    }

    private func completeIfReady() {
        guard !finishing, !finished else { return }
        if failure == nil && cancellation.requested { stop(CancellationError()) }
        if let failure {
            if escalated && exited { finish(.failure(failure)) }
        } else if exited && eof {
            finish(nil)
        }
    }

    private var requestedResult: Result<ShellResult, Error>?
    private func closeReader() {
        guard let reader, !readerCancelled else { return }
        readerCancelled = true
        reader.cancel()
    }

    private func finish(_ result: Result<ShellResult, Error>?) {
        guard !finishing, !finished else { return }
        finishing = true
        requestedResult = result
        timeoutItem?.cancel(); escalationItem?.cancel()
        if reader != nil {
            closeReader()
        } else {
            if descriptor >= 0 { close(descriptor); descriptor = -1 }
            finishAfterClosingIO()
        }
    }

    /// cancel handler 确认没有读取回调后关闭 FD，再回收直接 child，最后恢复等待者。
    private func finishAfterClosingIO() {
        guard !finished else { return }
        var status = fallbackStatus ?? 0
        if pid > 0 {
            var result: pid_t
            repeat { result = waitpid(pid, &status, WNOHANG) } while result == -1 && errno == EINTR
            if result == 0 {
                queue.asyncAfter(deadline: .now() + 0.01) { self.finishAfterClosingIO() }
                return
            }
            if result == -1 && requestedResult == nil { requestedResult = .failure(error(errno)) }
            pid = 0
        }
        finished = true
        reader = nil
        let code = status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f
        let result = requestedResult ?? .success(ShellResult(output: output.text, status: code))
        let callback = completion
        completion = nil
        callback?(result)
    }
}
#endif
