import Foundation

public struct InstallPlan: Equatable, Sendable {
    public var target: URL
    public var trashAfter: URL?
    public var relocating: Bool

    public init(target: URL, trashAfter: URL?, relocating: Bool) {
        self.target = target
        self.trashAfter = trashAfter
        self.relocating = relocating
    }

    public static func == (a: InstallPlan, b: InstallPlan) -> Bool {
        a.target.standardizedFileURL.path == b.target.standardizedFileURL.path
            && a.trashAfter?.standardizedFileURL.path == b.trashAfter?.standardizedFileURL.path
            && a.relocating == b.relocating
    }
}

public enum InstallLocation {
    /// appName 可带 .app 后缀。relocates=false 保留 Meno 拒绝临时或只读位置的行为。
    public static func plan(bundle: URL, appName: String, translocated: Bool, original: URL?, readOnly: Bool,
                            relocates: Bool = true, folders: [URL], canWrite: (URL) -> Bool) -> InstallPlan? {
        guard bundle.isFileURL, bundle.pathExtension == "app" else { return nil }
        guard translocated || readOnly else {
            return InstallPlan(target: bundle, trashAfter: nil, relocating: false)
        }
        guard relocates else { return nil }
        guard !appName.isEmpty, !appName.contains("/"), appName != ".", appName != ".." else { return nil }
        if let original, original.isFileURL, original.pathExtension == "app" {
            let parent = original.deletingLastPathComponent().standardizedFileURL.path
            if folders.contains(where: { $0.isFileURL && $0.standardizedFileURL.path == parent }) {
                return InstallPlan(target: original, trashAfter: nil, relocating: false)
            }
        }
        let folders = folders.filter(\.isFileURL)
        guard let first = folders.first else { return nil }
        let folder = folders.first(where: canWrite) ?? first
        let filename = appName.hasSuffix(".app") ? appName : appName + ".app"
        let target = folder.appendingPathComponent(filename, isDirectory: true).standardizedFileURL
        let trash = original.flatMap { $0.standardizedFileURL.path == target.path ? nil : $0 }
        return InstallPlan(target: target, trashAfter: trash, relocating: true)
    }
}
