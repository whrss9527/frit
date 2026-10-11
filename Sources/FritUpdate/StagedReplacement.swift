#if os(macOS) || os(Linux)
import Foundation

/// 同目录暂存、失败回滚，以及管理员路径复用的脚本；不执行授权对话框。
enum StagedReplacement {
    /// 原包仍在时优先选它：暂存目录可能只是上次失败留下的旧包。
    static func source(newApp: URL, staged: URL, fileManager: FileManager = .default) -> URL {
        fileManager.fileExists(atPath: newApp.path) ? newApp : staged
    }

    static func swap(newApp: URL, target: URL, staged: URL, backup: URL, fileManager: FileManager = .default,
                     retainPrevious: Bool = false) throws {
        let sourcePath = newApp.standardizedFileURL.resolvingSymlinksInPath().path
        guard sourcePath != target.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let alreadyStaged = sourcePath == staged.standardizedFileURL.resolvingSymlinksInPath().path
        if !alreadyStaged { try? fileManager.removeItem(at: staged) }
        let hadTarget = fileManager.fileExists(atPath: target.path)
        // 上一步回滚失败、旧包只剩备份时，不能先把唯一的旧包删掉。
        if hadTarget { try? fileManager.removeItem(at: backup) }
        if !alreadyStaged { try fileManager.moveItem(at: newApp, to: staged) }
        if hadTarget { try fileManager.moveItem(at: target, to: backup) }
        do {
            try fileManager.moveItem(at: staged, to: target)
        } catch {
            if fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: target)
            }
            throw error
        }
        if !retainPrevious { try? fileManager.removeItem(at: backup) }
    }

    static func privilegedScript(source: URL, target: URL, staged: URL, backup: URL, retainPrevious: Bool = false) -> String {
        let (s, t, b) = (quote(staged.path), quote(target.path), quote(backup.path))
        var script = "mkdir -p \(quote(target.deletingLastPathComponent().path))"
        // /var 与 /private/var 等路径写法不同也可能指向同一份暂存包。
        if source.standardizedFileURL.resolvingSymlinksInPath().path != staged.standardizedFileURL.resolvingSymlinksInPath().path {
            script += " && rm -rf \(s) && mv \(quote(source.path)) \(s)"
        }
        script += " && { [ ! -e \(t) ] || { rm -rf \(b) && mv \(t) \(b); }; }"
            + " && { mv \(s) \(t) || { [ ! -e \(b) ] || mv \(b) \(t); exit 1; }; }"
        if !retainPrevious { script += " && rm -rf \(b)" }
        return script
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

#endif
