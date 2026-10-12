# 最小 FritSystem

变更先记在 Unreleased，随下一次 0.2.0 定版提供 FritUpdate 需要的 Shell、Relauncher 和 FileLog。macOS 可用全部 API；Linux 编译 Shell、文件日志和回滚脚本测试；iOS 暂时编译为空模块。

## Shell

`Shell.run(_:_:timeout:) async throws -> ShellResult` 在 Dispatch 工作线程上运行进程、读取 stdout/stderr 和等待退出，Swift 协作线程只等待 continuation。同步入口 `runSync` 会阻塞调用线程，界面代码用异步入口。

参数直接交给 Process，不通过 shell 拼接。超时先发 SIGTERM，两秒后发 SIGKILL；Foundation 给子进程建立了独立进程组时会结束整组，避免 shell 子进程继续持有输出管道。不能确认独立组时只处理该进程。计时器使用加锁的标记，进程自行收到信号退出不会被误判为超时。

`ShellResult` 提供 `output`、`status`、`succeeded` 和 `trimmedOutput`。启动失败和超时分别抛 `ShellError.launchFailed` / `.timeout`。

`lookPath` 查 PATH 并补常见系统和 Homebrew 目录；也可验证指定路径。`shellQuote` 和 `appleScriptString` 用于确实需要脚本的场景，普通执行仍直接传 argv。

## FileLog

```swift
let log = FileLog(
    subsystem: "io.github.whrss9527.pop",
    fileURL: logURL,
    maxSize: 1 << 20,
    redact: { text in text.replacingOccurrences(of: "secret", with: "[redacted]") },
    messagePrefix: "Pop 更新："
)
log.info("开始检查")
log.error("检查失败")
log.flush()
let recent = log.tail(lines: 200)
```

macOS 的系统日志与文件使用同一份脱敏结果，前缀也脱敏。fileURL 为 nil 时只写系统日志。实例副本共享串行队列，DateFormatter 和文件操作限制在该队列上；`flush` 和 `tail` 会先等前面的写入完成。

默认上限 1 MiB：追加将超过上限时清空旧日志。单条过长日志保留末尾并避开 UTF-8 字符中间，文件大小仍受限制。文件无法写入时保留原来的尽力记录行为，系统日志继续可用。

## Relauncher

macOS 的 `@MainActor Relauncher.relaunch(bundle:previous:) -> Bool` 默认使用当前 bundle。只有 helper 启动成功才调用 NSApp.terminate；启动失败返回 false，App 继续运行。

helper 将 bundle、旧进程 ID 和旧副本路径作为 argv 传入 `/bin/sh`。等旧进程退出后打开目标 App；最多等一分钟，避免和没退出的旧进程并存。previous 为 nil 时普通重启；有旧副本时观察 45 秒，新进程没有启动或提前退出便把旧副本换回，失败版本留下 `.rejected`。成功后的旧副本由 App 的既有更新清理流程删除。

## 来源与验证

- Proxi `f765bf4f2cbcb25c49bfd1c81997d5781c352529`，`Sources/Proxi/System/Shell.swift` 和 `Log.swift`：进程输出、超时、查找命令、引用、系统日志、串行文件日志、脱敏和 tail。异步入口改为 Dispatch，脱敏函数和日志位置改为注入；不迁入 Proxi 的 Store。
- Meno `51c118699e56454df23ffa8eee80ac1a4cfae457`，`Sources/Meno/Support/Relauncher.swift`：helper 脚本保持原行为，公开 bundle 参数，替换 App 专有的 PID 和日志引用。

`swift test` 覆盖输出超过管道容量、参数引用、启动失败、自发信号、SIGTERM 忽略和子进程管道超时，日志脱敏、前缀、截断、UTF-8 和同步读取，以及 `bash -n` 与假 bundle 的正常重启、成功更新、未启动和 open 失败的回滚。Linux 验证脚本和通用逻辑；macOS CI 还编译实际 AppKit / os.Logger 入口并运行这些测试。
