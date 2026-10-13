#if os(macOS) || os(Linux)
import XCTest
@testable import FritSystem
#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class ShellLifecycleTests: XCTestCase {
    private struct Fixture: Sendable {
        let root: URL
        let executable: String
    }
    private static let compiledFixture: Result<Fixture, Error> = Result {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("frit-shell-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = Bundle.module.url(forResource: "ProcessFixture", withExtension: "c", subdirectory: "Fixtures")!
        let binary = root.appendingPathComponent("fixture").path
        guard let compiler = Shell.lookPath("cc") ?? Shell.lookPath("clang") else {
            throw ShellError.launchFailed("cc", "动态进程测试需要 C 编译器")
        }
        let result = try Shell.runSync(compiler, ["-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror", source.path, "-o", binary])
        guard result.succeeded else { throw ShellError.launchFailed("cc", result.output) }
        return Fixture(root: root, executable: binary)
    }

    private func directory() throws -> URL {
        let url = try Self.compiledFixture.get().root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func command() throws -> String { try Self.compiledFixture.get().executable }
    private func identity(_ root: URL, _ name: String = "parent.pid") throws -> (pid: pid_t, group: pid_t) {
        let values = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8).split(separator: " ")
        return (pid_t(values[0])!, pid_t(values[1].trimmingCharacters(in: .whitespacesAndNewlines))!)
    }
    private func ready(_ root: URL) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("parent.pid").path) {
            if Date() >= deadline { throw ShellError.timeout("fixture 启动") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private func assertReaped(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(kill(pid, 0), -1, "返回前必须回收直接 child", file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1, file: file, line: line)
        XCTAssertEqual(errno, ECHILD, file: file, line: line)
    }
    private func heartbeat(_ root: URL) throws -> UInt64 {
        let text = try String(contentsOf: root.appendingPathComponent("heartbeat"), encoding: .utf8)
        return try XCTUnwrap(UInt64(text))
    }
    private func assertEscapedAlive(_ root: URL, _ pid: pid_t) async throws {
        XCTAssertEqual(kill(pid, 0), 0)
        let before = try heartbeat(root)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(try heartbeat(root), before, "心跳必须继续，kill(0) 不能区分僵尸进程")
    }

    func testPreCancelledTaskNeverLaunches() async throws {
        let root = try directory(), executable = try command()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Shell.run(executable, ["hold", root.path])
        }
        do { _ = try await task.value; XCTFail("预取消应抛 CancellationError") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("parent.pid").path))
    }

    func testRunningCancellationKillsAndReapsAndDoesNotContinue() async throws {
        let root = try directory(), executable = try command()
        let next = root.appendingPathComponent("next").path
        let task = Task {
            _ = try await Shell.run(executable, ["hold", root.path], timeout: 10)
            return try await Shell.run("/usr/bin/touch", [next])
        }
        try await ready(root)
        let child = try identity(root)
        XCTAssertEqual(child.pid, child.group)
        XCTAssertNotEqual(child.group, getpgrp())
        let start = Date()
        for _ in 0..<20 { task.cancel() }
        do { _ = try await task.value; XCTFail("运行中取消应抛 CancellationError") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        assertReaped(child.pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: next))
        XCTAssertEqual(kill(getpid(), 0), 0)
    }

    func testCancellationCleansOnlyOwnedGroup() async throws {
        let root = try directory(), unrelatedRoot = try directory(), executable = try command()
        let unrelated = Task { try await Shell.run(executable, ["hold", unrelatedRoot.path], timeout: 20) }
        let owned = Task { try await Shell.run(executable, ["owned", root.path], timeout: 20) }
        try await ready(root); try await ready(unrelatedRoot)
        let parent = try identity(root), child = try identity(root, "child.pid"), other = try identity(unrelatedRoot)
        XCTAssertEqual(child.group, parent.pid)
        owned.cancel()
        do { _ = try await owned.value; XCTFail("应取消") } catch { XCTAssertTrue(error is CancellationError) }
        assertReaped(parent.pid)
        XCTAssertEqual(kill(child.pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(kill(other.pid, 0), 0, "另一个 runner 的进程不能被结束")
        unrelated.cancel()
        do { _ = try await unrelated.value; XCTFail("应取消") } catch { XCTAssertTrue(error is CancellationError) }
        assertReaped(other.pid)
    }

    func testEscapedStdoutAndStderrAreBoundedAndRemainOutsideOwnedGroup() async throws {
        for mode in ["escape-out", "escape-err"] {
            let root = try directory(), executable = try command()
            let start = Date()
            do {
                _ = try await Shell.run(executable, [mode, root.path], timeout: 0.15)
                XCTFail("逃逸后代持管道也应超时")
            } catch { XCTAssertEqual(error as? ShellError, .timeout("fixture")) }
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertGreaterThanOrEqual(elapsed, 2)
            XCTAssertLessThan(elapsed, 4)
            let parent = try identity(root), escaped = try identity(root, "child.pid")
            defer { kill(escaped.pid, SIGKILL) } // 仅清理本测试已记录的逃逸进程。
            assertReaped(parent.pid)
            XCTAssertEqual(escaped.pid, escaped.group)
            XCTAssertNotEqual(escaped.group, parent.group)
            try await assertEscapedAlive(root, escaped.pid)
        }
    }

    func testSyncDeadlineAlsoClosesEscapedPipe() throws {
        let root = try directory(), executable = try command()
        let start = Date()
        XCTAssertThrowsError(try Shell.runSync(executable, ["escape-err", root.path], timeout: 0.1)) {
            XCTAssertEqual($0 as? ShellError, .timeout("fixture"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        let escaped = try identity(root, "child.pid")
        defer { kill(escaped.pid, SIGKILL) }
        assertReaped(try identity(root).pid)
        XCTAssertEqual(kill(escaped.pid, 0), 0)
        let before = try heartbeat(root)
        usleep(100_000)
        XCTAssertGreaterThan(try heartbeat(root), before)
    }

    func testOwnedChildIsKilledAfterDirectParentExits() async throws {
        let root = try directory(), executable = try command()
        let start = Date()
        do { _ = try await Shell.run(executable, ["owned-exit", root.path], timeout: 0.15); XCTFail("应超时") }
        catch { XCTAssertEqual(error as? ShellError, .timeout("fixture")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        let parent = try identity(root), child = try identity(root, "child.pid")
        defer { kill(child.pid, SIGKILL) }
        XCTAssertEqual(child.group, parent.pid)
        assertReaped(parent.pid)
        let before = try heartbeat(root)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try heartbeat(root), before, "保留原 owned group 超时清理，心跳必须停止")
    }

    func testCancellationClosesEscapedPipeBeforeReturning() async throws {
        let root = try directory(), executable = try command()
        let task = Task { try await Shell.run(executable, ["escape-out", root.path], timeout: 10) }
        try await ready(root)
        let parent = try identity(root), escaped = try identity(root, "child.pid")
        defer { kill(escaped.pid, SIGKILL) }
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("应取消") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        assertReaped(parent.pid)
        try await assertEscapedAlive(root, escaped.pid)
    }

    func testFloodDoesNotStarveDeadline() async throws {
        let root = try directory(), executable = try command()
        let start = Date()
        do { _ = try await Shell.run(executable, ["flood", root.path], timeout: 0.15); XCTFail("应超时") }
        catch { XCTAssertEqual(error as? ShellError, .timeout("fixture")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        assertReaped(try identity(root).pid)
    }

    func testLargeCombinedOutputHasVisibleBoundAndValidUnicodeTail() async throws {
        let root = try directory(), executable = try command()
        for (mode, stream) in [("large", "both"), ("large", "out"), ("large", "err"), ("invalid", "both")] {
            let result = try await Shell.run(executable, [mode, root.path, stream], timeout: 10)
            XCTAssertEqual(result.status, 7)
            XCTAssertTrue(result.output.hasPrefix("[输出已截断，仅保留末尾 8 MiB]\n"))
            XCTAssertLessThanOrEqual(result.output.utf8.count, 8 * 1024 * 1024)
            if mode == "large" { XCTAssertFalse(result.output.contains("\u{FFFD}")) }
            XCTAssertTrue(result.output.contains("stdout-tail\n"))
            XCTAssertTrue(result.output.hasSuffix("stderr-tail\n"))
        }
        let small = try Shell.runSync(executable, ["small", root.path])
        XCTAssertEqual(small.output, String(repeating: "stdout 中文\nstderr 中文\n", count: 16))
        XCTAssertEqual(small.status, 7)
        for mode in ["invalid-exact", "invalid-small"] {
            let result = try await Shell.run(executable, [mode, root.path])
            XCTAssertEqual(result.status, 7)
            XCTAssertTrue(result.output.hasPrefix("[输出已截断，仅保留末尾 8 MiB]\n"))
            XCTAssertLessThanOrEqual(result.output.utf8.count, 8 * 1024 * 1024)
        }
    }

    func testConcurrentCommandsKeepStatusAndBothStreams() async throws {
        let executable = try command(), root = try directory()
        try await withThrowingTaskGroup(of: ShellResult.self) { group in
            for _ in 0..<24 { group.addTask { try await Shell.run(executable, ["small", root.path]) } }
            for try await result in group {
                XCTAssertEqual(result.status, 7)
                XCTAssertEqual(result.output, String(repeating: "stdout 中文\nstderr 中文\n", count: 16))
            }
        }
    }

    func testExitCancellationRaceCompletesExactlyOnce() async throws {
        let executable = try command()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                let root = try directory()
                group.addTask {
                let task = Task { try await Shell.run(executable, ["race", root.path], timeout: 5) }
                try await self.ready(root)
                let pid = try self.identity(root).pid
                try await Task.sleep(nanoseconds: UInt64(i % 4) * 10_000_000)
                task.cancel(); task.cancel()
                do { let result = try await task.value; XCTAssertEqual(result.output, "done"); XCTAssertEqual(result.status, 0) }
                catch { XCTAssertTrue(error is CancellationError) }
                self.assertReaped(pid)
            } }
            try await group.waitForAll()
        }
    }

    func testRepeatedCallsCloseReadDescriptorsBeforeReturning() throws {
        _ = try Shell.runSync("/bin/sh", ["-c", "printf warmup"])
        func descriptors() -> Set<Int32> {
            Set((0..<1024).compactMap { fcntl(Int32($0), F_GETFD) == -1 ? nil : Int32($0) })
        }
        let before = descriptors()
        for _ in 0..<100 { XCTAssertEqual(try Shell.runSync("/bin/sh", ["-c", "printf ok"]).output, "ok") }
        XCTAssertEqual(descriptors(), before)
    }
}
#endif
