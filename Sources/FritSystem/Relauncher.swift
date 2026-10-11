import Foundation
#if os(macOS)
import AppKit
import os

public enum Relauncher {
    /// 脚本启动成功才退出 App。旧副本在新版本启动失败或提前退出时换回。
    @MainActor
    @discardableResult
    public static func relaunch(bundle: URL = Bundle.main.bundleURL, previous: URL? = nil) -> Bool {
        guard bundle.isFileURL, bundle.pathExtension == "app" else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RelaunchScript.text, bundle.path, String(ProcessInfo.processInfo.processIdentifier), previous?.path ?? ""]
        do { try process.run() }
        catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "FritSystem", category: "relaunch")
                .error("重新启动失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
        NSApp.terminate(nil)
        return true
    }
}
#endif

#if os(macOS) || os(Linux)
enum RelaunchScript {
    // 路径走 argv：$0 是 App，$1 是旧进程，$2 是上一份副本。
    static let text = """
    i=0
    while /bin/kill -0 "$1" 2>/dev/null; do
      if [ "$i" -ge 600 ]; then exit 1; fi
      /bin/sleep 0.1
      i=$((i + 1))
    done
    running() {
      /bin/ps -A -o command= | P="$0/Contents/MacOS/" /usr/bin/awk 'index($0, ENVIRON["P"]) == 1 { found = 1 } END { exit !found }'
    }
    if /usr/bin/open "$0" || { /bin/sleep 1; /usr/bin/open "$0"; }; then
      [ -n "$2" ] || exit 0
      i=0
      started=0
      while [ -e "$2" ] && [ "$i" -lt 45 ]; do
        if running; then
          started=1
        elif [ "$started" -eq 1 ]; then
          break
        fi
        /bin/sleep 1
        i=$((i + 1))
      done
      if [ ! -e "$2" ] || running; then exit 0; fi
    fi
    [ -n "$2" ] && [ -d "$2" ] || exit 1
    /bin/mv "$0" "$2.rejected" || exit 1
    /bin/mv "$2" "$0" || { /bin/mv "$2.rejected" "$0"; exit 1; }
    /usr/bin/open "$0"
    """
}
#endif
