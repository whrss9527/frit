#if os(macOS)
import Darwin
import Foundation

/// 旧包保留在私有兄弟目录，避免系统替换目录在新进程启动后无法清理。
enum AtomicReplacement {
    private struct Marker: Codable { let format: Int; let target: String }
    private static let markerName = ".FritUpdate.json"
    private static func prefix(_ target: URL) -> String { "." + target.lastPathComponent + ".update-" }

    @discardableResult
    static func swap(newApp: URL, target: URL, fileManager: FileManager = .default,
                     exchange: (URL, URL) -> Bool = exchange) throws -> URL {
        guard newApp.isFileURL, target.isFileURL, target.pathExtension == "app",
              newApp.standardizedFileURL.resolvingSymlinksInPath() != target.standardizedFileURL.resolvingSymlinksInPath() else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        let parent = target.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = parent.appendingPathComponent(prefix(target) + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let prepared = folder.appendingPathComponent(target.lastPathComponent)
        let previous = folder.appendingPathComponent("Previous.app")
        var retain = false
        defer { if !retain { try? fileManager.removeItem(at: folder) } }
        try JSONEncoder().encode(Marker(format: 1, target: target.lastPathComponent))
            .write(to: folder.appendingPathComponent(markerName), options: .atomic)
        try fileManager.copyItem(at: newApp, to: prepared)
        if !fileManager.fileExists(atPath: target.path) {
            try fileManager.moveItem(at: prepared, to: target)
            return previous
        }
        if exchange(prepared, target) { retain = true; return prepared }
        // 不支持交换的卷仍用两步 move，但保留旧包用于启动回滚。
        try fileManager.moveItem(at: target, to: previous)
        retain = true
        do { try fileManager.moveItem(at: prepared, to: target) }
        catch {
            do { try fileManager.moveItem(at: previous, to: target); retain = false }
            catch { /* 回滚失败：唯一旧包保留在 previous，不随错误删除。 */ }
            throw error
        }
        return previous
    }
    private static func exchange(_ source: URL, _ target: URL) -> Bool {
        renamex_np(source.path, target.path, UInt32(RENAME_SWAP)) == 0
    }

    /// 仅清理同目录、带格式标记且不是符号链接的私有更新目录。
    static func finish(bundle: URL, fileManager: FileManager = .default) -> String? {
        guard bundle.isFileURL, bundle.pathExtension == "app",
              fileManager.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path) else { return nil }
        let candidates = (try? fileManager.contentsOfDirectory(at: bundle.deletingLastPathComponent(),
                             includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        var rejectedVersion: String?
        for folder in candidates where folder.lastPathComponent.hasPrefix(prefix(bundle)) {
            guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  let data = try? Data(contentsOf: folder.appendingPathComponent(markerName)),
                  let marker = try? JSONDecoder().decode(Marker.self, from: data),
                  marker.format == 1, marker.target == bundle.lastPathComponent else { continue }
            let rejected = [folder.appendingPathComponent(bundle.lastPathComponent + ".rejected"),
                            folder.appendingPathComponent("Previous.app.rejected")]
            let version = rejected.compactMap { url -> String? in
                guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
                return info["CFBundleShortVersionString"] as? String
            }.first
            do { try fileManager.removeItem(at: folder); rejectedVersion = rejectedVersion ?? version }
            catch { /* 保留目录，下次稳定启动再清理。 */ }
        }
        return rejectedVersion
    }

    /// Meno 旧更新器留下的目录：仅在 Meno.app 内、同父目录和旧归档标记都匹配时处理。
    static func finishLegacyMeno(bundle: URL, defaults: UserDefaults = .standard) -> String? {
        guard bundle.lastPathComponent == "Meno.app", let path = defaults.string(forKey: "UpdateLeftovers") else { return nil }
        let folder = URL(fileURLWithPath: path).standardizedFileURL
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.path) else { defaults.removeObject(forKey: "UpdateLeftovers"); return nil }
        guard folder.deletingLastPathComponent().resolvingSymlinksInPath() == bundle.deletingLastPathComponent().resolvingSymlinksInPath(),
              folder.lastPathComponent.hasPrefix(".Meno-update-"),
              (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              manager.fileExists(atPath: folder.appendingPathComponent("Meno.zip").path),
              manager.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path) else { return nil }
        let rejected = [folder.appendingPathComponent("Unpacked/Meno.app.rejected"), folder.appendingPathComponent("Previous.app.rejected")]
        let version = rejected.compactMap { url -> String? in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            return info["CFBundleShortVersionString"] as? String
        }.first
        do { try manager.removeItem(at: folder); defaults.removeObject(forKey: "UpdateLeftovers"); return version }
        catch { return nil }
    }
}
#endif
