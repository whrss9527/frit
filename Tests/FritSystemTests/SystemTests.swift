#if os(macOS) || os(Linux)
import XCTest
@testable import FritSystem

final class SystemTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("frit-system-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testShellArgumentsOutputAndExitStatus() async throws {
        let text = "spaces ' quotes $HOME\n中文"
        let result = try await Shell.run("/bin/sh", ["-c", "printf '%s' \"$1\"; printf ' error' >&2; exit 7", "test", text])
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.output, text + " error")
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(try Shell.runSync("/bin/sh", ["-c", "printf ' ok \\n'"]).trimmedOutput, "ok")
        let large = try await Shell.run("/bin/sh", ["-c", "head -c 262144 /dev/zero"], timeout: 5)
        XCTAssertEqual(large.output.utf8.count, 262_144)
    }

    func testShellLaunchFailureAndOwnSignalAreNotTimeouts() throws {
        XCTAssertThrowsError(try Shell.runSync("/nonexistent/frit-command", [])) { error in
            guard case ShellError.launchFailed("frit-command", _) = error else { return XCTFail("错误类型不对：\(error)") }
        }
        let signalled = try Shell.runSync("/bin/sh", ["-c", "kill -TERM $$"])
        XCTAssertFalse(signalled.succeeded)
    }

    func testShellTimeoutEscalatesWhenSIGTERMIsIgnored() async {
        let start = Date()
        do {
            _ = try await Shell.run("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.15)
            XCTFail("忽略 SIGTERM 的进程也必须结束")
        } catch {
            XCTAssertEqual(error as? ShellError, .timeout("sh"))
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testShellTimeoutClosesPipesHeldByChildProcesses() async {
        let start = Date()
        do {
            _ = try await Shell.run("/bin/sh", ["-c", "(trap '' TERM; while :; do sleep 1; done) & wait"], timeout: 0.2)
            XCTFail("子进程持有输出管道时也必须结束")
        } catch {
            XCTAssertEqual(error as? ShellError, .timeout("sh"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testQuotingAndLookPath() throws {
        let text = "/Applications/Pop's 中文.app\n$HOME"
        XCTAssertEqual(Shell.shellQuote("/Applications/Pop's.app"), "'/Applications/Pop'\\''s.app'")
        XCTAssertEqual(try Shell.runSync("/bin/sh", ["-c", "printf '%s' " + Shell.shellQuote(text)]).output, text)
        XCTAssertEqual(Shell.appleScriptString("say \"hi\" \\ bye"), "\"say \\\"hi\\\" \\\\ bye\"")
        XCTAssertNotNil(Shell.lookPath("sh"))
        XCTAssertEqual(Shell.lookPath("/bin/sh"), "/bin/sh")
        XCTAssertNil(Shell.lookPath("frit-nonexistent-command-\(UUID().uuidString)"))
    }

    func testFileLogRedactsPrefixAndTailFlushesQueuedMessages() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sub/log.txt")
        let log = FileLog(subsystem: "FritTests", fileURL: url,
                          redact: { $0.replacingOccurrences(of: "secret", with: "[redacted]") }, messagePrefix: "Pop 更新：secret ")
        log.info("first secret")
        let copy = log
        copy.error("second")
        let tail = log.tail(lines: 1)
        XCTAssertTrue(tail.contains("ERROR Pop 更新：[redacted] second"))
        XCTAssertFalse(tail.contains("secret"))
        XCTAssertEqual(log.tail(lines: -1), "")
        log.flush()
        let full = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(full.contains("INFO Pop 更新：[redacted] first [redacted]"))
        XCTAssertFalse(full.contains("secret"))
    }

    func testFileLogTruncatesExistingAndOversizedUnicodeMessages() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("log.txt")
        try Data(String(repeating: "old", count: 100).utf8).write(to: url)
        let log = FileLog(subsystem: "FritTests", fileURL: url, maxSize: 64)
        log.info("new")
        log.flush()
        XCTAssertFalse(log.tail().contains("old"))
        log.info(String(repeating: "中文", count: 100))
        log.flush()
        let data = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(data.count, 64)
        XCTAssertNotNil(String(data: data, encoding: .utf8))
        XCTAssertTrue(log.tail().contains("中文"))
        FileLog(subsystem: "FritTests").info("无文件时仍可写系统日志")
    }

    func testRelaunchScriptSyntax() throws {
        XCTAssertTrue(try Shell.runSync("/bin/bash", ["-n", "-c", RelaunchScript.text]).succeeded)
    }

    /// 测试里替换系统命令，生产脚本的 argv 和文件替换顺序保持不变。
    private func runRelaunchFixture(running: Bool, previous: Bool, opens: Bool = true) throws -> (URL, URL, URL, ShellResult) {
        let root = try temporaryDirectory()
        let app = root.appendingPathComponent("App's 中文 [1].app")
        let old = root.appendingPathComponent("previous copy.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "new".write(to: app.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        if previous {
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            try "old".write(to: old.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        }
        func command(_ name: String, _ body: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        let output = root.appendingPathComponent("opened.txt")
        let open = try command("fake-open", "printf '%s' \"$1\" > " + Shell.shellQuote(output.path) + (opens ? "\nexit 0" : "\nexit 1"))
        let sleep = try command("fake-sleep", "exit 0")
        let ps = try command("fake-ps", running ? "printf '%s\\n' " + Shell.shellQuote(app.path + "/Contents/MacOS/App") : "exit 0")
        let script = RelaunchScript.text.replacingOccurrences(of: "/usr/bin/open", with: Shell.shellQuote(open.path))
            .replacingOccurrences(of: "/bin/sleep", with: Shell.shellQuote(sleep.path))
            .replacingOccurrences(of: "/bin/ps", with: Shell.shellQuote(ps.path))
        let result = try Shell.runSync("/bin/sh", ["-c", script, app.path, "2147483647", previous ? old.path : ""], timeout: 10)
        return (root, app, old, result)
    }

    func testOrdinaryRelaunchPassesPathAsArgument() throws {
        let (root, app, _, result) = try runRelaunchFixture(running: false, previous: false)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(result.succeeded, result.output)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("opened.txt"), encoding: .utf8), app.path)
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8), "new")
    }

    func testSuccessfulUpdateLeavesPreviousCopyForAppCleanup() throws {
        let (root, app, old, result) = try runRelaunchFixture(running: true, previous: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(result.succeeded, result.output)
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func testFailedUpdateRestoresPreviousBundle() throws {
        let (root, app, old, result) = try runRelaunchFixture(running: false, previous: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(result.succeeded, result.output)
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: old.path + ".rejected").appendingPathComponent("marker"), encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testOpenFailureStillRestoresPreviousBundle() throws {
        let (root, app, _, result) = try runRelaunchFixture(running: false, previous: true, opens: false)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8), "old")
    }
}
#endif
