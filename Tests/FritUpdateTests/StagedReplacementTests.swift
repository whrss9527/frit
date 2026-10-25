#if os(macOS) || os(Linux)
import Foundation
import XCTest
@testable import FritUpdate

final class UpdateReplacementTests: XCTestCase {
    private final class DeniedMove: FileManager, @unchecked Sendable {
        let deniedSource: URL
        init(_ source: URL) { deniedSource = source; super.init() }
        override func moveItem(at source: URL, to destination: URL) throws {
            if source == deniedSource { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
            try super.moveItem(at: source, to: destination)
        }
    }
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stox update's \(UUID().uuidString)")
        var target: URL { root.appendingPathComponent("Stox.app") }
        var staged: URL { root.appendingPathComponent(".Stox.app.update") }
        var backup: URL { root.appendingPathComponent(".Stox.app.previous") }
        var newApp: URL { root.appendingPathComponent("download/New Stox.app") }
        func write(_ value: String, at url: URL) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try value.write(to: url.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        }
        func value(_ url: URL) throws -> String { try String(contentsOf: url.appendingPathComponent("marker"), encoding: .utf8) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
    private func execute(_ script: String, environment: [String: String]? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }
    private func script(_ f: Fixture, source: URL) -> String {
        StagedReplacement.privilegedScript(source: source, target: f.target, staged: f.staged, backup: f.backup)
    }

    func testDirectRetryWithAlreadyStagedSource() throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.write("new", at: f.staged); try f.write("old", at: f.target)
        try StagedReplacement.swap(newApp: f.staged, target: f.target, staged: f.staged, backup: f.backup)
        XCTAssertEqual(try f.value(f.target), "new")
    }

    func testSourceEqualToTargetCannotDeleteCurrentApp() throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.write("current", at: f.target)
        XCTAssertThrowsError(try StagedReplacement.swap(newApp: f.target, target: f.target, staged: f.staged, backup: f.backup))
        XCTAssertEqual(try f.value(f.target), "current")
    }

    func testRetainingPreviousForAtomicFallbackAndAuthorization() throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.write("new", at: f.newApp); try f.write("old", at: f.target)
        try StagedReplacement.swap(newApp: f.newApp, target: f.target, staged: f.staged, backup: f.backup, retainPrevious: true)
        XCTAssertEqual(try f.value(f.target), "new")
        XCTAssertEqual(try f.value(f.backup), "old")
        try f.write("newer", at: f.staged)
        let script = StagedReplacement.privilegedScript(source: f.staged, target: f.target, staged: f.staged,
                                                       backup: f.backup, retainPrevious: true)
        XCTAssertEqual(try execute(script), 0)
        XCTAssertEqual(try f.value(f.target), "newer")
        XCTAssertEqual(try f.value(f.backup), "new")
    }

    func testPermissionFailureAfterStagingRetainsNewAppForFallback() throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.write("new", at: f.newApp); try f.write("old", at: f.target)
        XCTAssertThrowsError(try StagedReplacement.swap(newApp: f.newApp, target: f.target, staged: f.staged, backup: f.backup, fileManager: DeniedMove(f.target))) { error in
            XCTAssertEqual((error as NSError).code, Int(EACCES))
        }
        let source = StagedReplacement.source(newApp: f.newApp, staged: f.staged)
        XCTAssertEqual(source, f.staged)
        XCTAssertEqual(try f.value(f.target), "old")
        XCTAssertEqual(try execute(script(f, source: source)), 0)
        XCTAssertEqual(try f.value(f.target), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backup.path))
    }

    func testFreshDownloadWinsOverResidualStagedAndBackup() throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.write("new", at: f.newApp); try f.write("old", at: f.target)
        try f.write("stale staged", at: f.staged); try f.write("stale backup", at: f.backup)
        let source = StagedReplacement.source(newApp: f.newApp, staged: f.staged)
        XCTAssertEqual(source, f.newApp)
        XCTAssertEqual(try execute(script(f, source: source)), 0)
        XCTAssertEqual(try f.value(f.target), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.staged.path))
    }

    func testSymlinkAliasOfStagedIsNotRemoved() throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.write("new", at: f.staged); try f.write("old", at: f.target)
        let alias = f.root.appendingPathComponent("staged alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.staged)
        XCTAssertEqual(alias.resolvingSymlinksInPath().path, f.staged.resolvingSymlinksInPath().path)
        XCTAssertEqual(try execute(script(f, source: alias)), 0)
        XCTAssertEqual(try f.value(f.target), "new")
    }

    func testFailedFinalMoveRestoresOnlyRemainingBackup() throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.write("new", at: f.staged); try f.write("old", at: f.backup)
        let bin = f.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("mv")
        // 替代的 mv 仅使新包→目标失败，其他移动由真实 mv 完成。
        try "#!/bin/sh\nif [ \"$1\" = \"$UPDATE_STAGE\" ] && [ \"$2\" = \"$UPDATE_TARGET\" ]; then exit 1; fi\nexec /bin/mv \"$@\"\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = bin.path + ":/usr/bin:/bin"
        env["UPDATE_STAGE"] = f.staged.path; env["UPDATE_TARGET"] = f.target.path
        XCTAssertNotEqual(try execute(script(f, source: f.staged), environment: env), 0)
        XCTAssertEqual(try f.value(f.target), "old")
        XCTAssertEqual(try f.value(f.staged), "new")
    }
}

#endif
