import Foundation

/// App 切换界面语言时设置此钩子；不改系统 AppleLanguages 或主 Bundle。
public enum FritLocalization {
    public static let languageDidChange = Notification.Name("FritLocalization.languageDidChange")
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var language: String?
    }
    private static let storage = Storage()
    public static var languageOverride: String? {
        get { storage.lock.lock(); defer { storage.lock.unlock() }; return storage.language }
        set {
            storage.lock.lock()
            let changed = storage.language != newValue
            storage.language = newValue
            storage.lock.unlock()
            if changed { NotificationCenter.default.post(name: languageDidChange, object: nil) }
        }
    }
    public static var locale: Locale { languageOverride.map(Locale.init(identifier:)) ?? .current }

    /// 显式选择模块的 lproj，运行时切换不会依赖 Foundation 已缓存的首选语言。
    public static func overriddenBundle(in bundle: Bundle) -> Bundle? {
        guard let language = languageOverride else { return nil }
        let normalized = language.replacingOccurrences(of: "_", with: "-")
        var candidates = [normalized]
        if normalized.lowercased().hasPrefix("zh") { candidates.append("zh-Hans") }
        if let base = normalized.split(separator: "-").first { candidates.append(String(base)) }
        for language in candidates {
            if let path = bundle.path(forResource: language, ofType: "lproj"), let selected = Bundle(path: path) { return selected }
            // SwiftPM 会把 zh-Hans.lproj 规范化为 zh-hans.lproj；大小写不能阻断覆盖。
            if let root = bundle.resourceURL,
               let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil),
               let folder = folders.first(where: {
                   $0.pathExtension == "lproj" && $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(language) == .orderedSame
               }), let selected = Bundle(url: folder) { return selected }
        }
        return nil
    }
}
