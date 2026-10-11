#if os(macOS)
import Foundation
import FritCore
import FritSystem
import XCTest
@testable import FritUpdate

@MainActor
final class AtomicUpdateTests: XCTestCase {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("atomic update's \(UUID().uuidString)")
        var target: URL { root.appendingPathComponent("Sample.app") }
        var source: URL { root.appendingPathComponent("download/Sample.app") }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func make(_ url: URL, version: String, minimum: String = "13.0") throws {
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = ["CFBundleShortVersionString": version, "CFBundleIdentifier": "test.frit.Sample",
                        "CFBundleExecutable": "Sample", "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": minimum]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        func version(_ app: URL) throws -> String? {
            let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            return (try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["CFBundleShortVersionString"] as? String
        }
    }
    private final class DeniedRestore: FileManager, @unchecked Sendable {
        let target: URL
        let restoreToo: Bool
        init(target: URL, restoreToo: Bool) { self.target = target; self.restoreToo = restoreToo; super.init() }
        override func moveItem(at source: URL, to destination: URL) throws {
            if destination == target && (restoreToo || source.lastPathComponent != "Previous.app") {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
            }
            try super.moveItem(at: source, to: destination)
        }
    }

    func testNativeSwapRetainsPreviousAndReportsRejectedVersion() throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.make(f.target, version: "1.0.0"); try f.make(f.source, version: "2.0.0")
        let previous = try AtomicReplacement.swap(newApp: f.source, target: f.target)
        XCTAssertEqual(try f.version(f.target), "2.0.0")
        XCTAssertEqual(try f.version(previous), "1.0.0")
        let rejected = URL(fileURLWithPath: previous.path + ".rejected")
        // 重启 helper 的恢复顺序：新包移到 rejected，再把旧包换回。
        try FileManager.default.moveItem(at: f.target, to: rejected)
        try FileManager.default.moveItem(at: previous, to: f.target)
        XCTAssertEqual(Updater.finishPreviousUpdate(bundle: f.target), "2.0.0")
        XCTAssertEqual(try f.version(f.target), "1.0.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
    }

    func testUnsupportedExchangeFallsBackAndFailureRestoresOriginal() throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.make(f.target, version: "1.0.0"); try f.make(f.source, version: "2.0.0")
        XCTAssertThrowsError(try AtomicReplacement.swap(newApp: f.source, target: f.target,
            fileManager: DeniedRestore(target: f.target, restoreToo: false), exchange: { _, _ in false }))
        XCTAssertEqual(try f.version(f.target), "1.0.0")
        XCTAssertEqual(try f.version(f.source), "2.0.0")
        let previous = try AtomicReplacement.swap(newApp: f.source, target: f.target, exchange: { _, _ in false })
        XCTAssertEqual(previous.lastPathComponent, "Previous.app")
        XCTAssertEqual(try f.version(previous), "1.0.0")
        XCTAssertEqual(try f.version(f.target), "2.0.0")
        _ = Updater.finishPreviousUpdate(bundle: f.target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
    }

    func testFailedRestorePreservesOnlyCopyAndCleanupDoesNotRemoveIt() throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.make(f.target, version: "1.0.0"); try f.make(f.source, version: "2.0.0")
        XCTAssertThrowsError(try AtomicReplacement.swap(newApp: f.source, target: f.target,
            fileManager: DeniedRestore(target: f.target, restoreToo: true), exchange: { _, _ in false }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.path))
        let folders = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
        let update = try XCTUnwrap(folders.first { $0.lastPathComponent.hasPrefix(".Sample.app.update-") })
        let previous = update.appendingPathComponent("Previous.app")
        XCTAssertEqual(try f.version(previous), "1.0.0")
        XCTAssertNil(Updater.finishPreviousUpdate(bundle: f.target))
        XCTAssertEqual(try f.version(previous), "1.0.0")
    }

    func testCleanupRequiresMarkerAndCannotFollowSiblingSymlink() throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.make(f.target, version: "1.0.0")
        let unrelated = f.root.appendingPathComponent(".Sample.app.update-unrelated")
        try f.make(unrelated, version: "other")
        let alias = f.root.appendingPathComponent(".Sample.app.update-link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: unrelated)
        XCTAssertNil(Updater.finishPreviousUpdate(bundle: f.target))
        XCTAssertEqual(try f.version(unrelated), "other")
        XCTAssertTrue(FileManager.default.fileExists(atPath: alias.path))
    }

    func testStrictSystemArchitectureNestedSignatureAndSigningIdentifier() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.make(f.source, version: "2.0.0", minimum: "9999.0")
        let version = try XCTUnwrap(AppVersion("2.0.0"))
        do { try await UpdateInstaller.validate(app: f.source, expectedVersion: version, signer: [.any], strict: [.minimumSystemVersion]); XCTFail("应拒绝更高系统要求") }
        catch { XCTAssertEqual(error as? UpdateError, .needsNewerMacOS("9999.0")) }
        do { try await UpdateInstaller.validate(app: f.source, expectedVersion: version, signer: [.any], strict: [.hostArchitecture]); XCTFail("应拒绝缺少本机架构") }
        catch { XCTAssertEqual(error as? UpdateError, .otherProcessor) }
        try f.make(f.source, version: "2.0.0")
        let executable = f.source.appendingPathComponent("Contents/MacOS/Sample")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: executable)
        let signed = try await Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", f.source.path])
        XCTAssertTrue(signed.succeeded, signed.output)
        try await UpdateInstaller.validate(app: f.source, expectedVersion: version, expectedIdentifier: "test.frit.Sample", signer: [.any], strict: .all)
        let resigned = try await Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "other.signature", f.source.path])
        XCTAssertTrue(resigned.succeeded, resigned.output)
        do { try await UpdateInstaller.validate(app: f.source, expectedVersion: version, expectedIdentifier: "test.frit.Sample", signer: [.any], strict: [.nestedCode]); XCTFail("签名标识必须一致") }
        catch { guard case .wrongApp = error as? UpdateError else { return XCTFail("\(error)") } }
    }

    func testLegacyMenoCleanupKeepsMigrationRollbackInformation() throws {
        let f = Fixture(); defer { f.cleanup() }
        let suite = "Frit.LegacyMeno." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bundle = f.root.appendingPathComponent("Meno.app")
        try f.make(bundle, version: "1.0.0")
        let folder = f.root.appendingPathComponent(".Meno-update-" + UUID().uuidString)
        try f.make(folder.appendingPathComponent("Previous.app.rejected"), version: "2.0.0")
        try Data().write(to: folder.appendingPathComponent("Meno.zip"))
        defaults.set(folder.path, forKey: "UpdateLeftovers")
        XCTAssertNil(AtomicReplacement.finishLegacyMeno(bundle: f.target, defaults: defaults))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(AtomicReplacement.finishLegacyMeno(bundle: bundle, defaults: defaults), "2.0.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(defaults.object(forKey: "UpdateLeftovers"))
    }
}
#endif
