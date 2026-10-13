# 最小 FritSystem

macOS 可用全部 API；Linux 编译 Shell、文件日志和回滚脚本测试；iOS 暂时编译为空模块。

## Shell

`Shell.run(_:_:timeout:) async throws -> ShellResult` 用单个 Dispatch worker 同时观察进程退出、读取 stdout/stderr、取消和单调截止时间，Swift 协作线程只等待 continuation。同步入口 `runSync` 等待同一个 worker，会阻塞调用线程；界面代码用异步入口。

参数直接交给 `posix_spawn`，不通过 shell 拼接；stdin 为 `/dev/null`，stdout/stderr 合并。启动时为直接子进程建立独立组并确认 PGID；超时或运行中取消先发 SIGTERM，两秒后发 SIGKILL。只向已确认属于本次执行的组发信号，不能确认独立组时只处理直接子进程。直接子进程的退出先由 `waitid(WNOWAIT)` 观察；关闭读取后才 `waitpid` 回收，避免在信号清理期间 PID 被复用。自行收到信号退出仍返回非零 `status`，不会被误判为超时。

Task 在调用前已取消时不启动命令；运行中取消会抛 `CancellationError`，取消不会撤销已经完成的外部副作用。调用方若捕获后忽略取消，仍应自己决定是否继续业务流程。更新的文件替换事务不在中途插入取消。

读取使用非阻塞 FD，每轮最多读取 1 MiB，随后重新观察取消和截止时间；等待使用最长 50ms 的 POSIX poll，EOF 后等待时不再 poll 已关闭的输出流。每个正在执行的调用占用一个 Dispatch worker，空闲等待最多每秒醒来 20 次，取消通常最多 50ms 被观察到；24 个并发调用和 40 次并发退出/取消由真实 fixture 验证。即使后代创建新的 session/进程组并持有 stdout 或 stderr，超时或取消也会在两秒终止宽限后关闭本执行器的读取端、回收直接 child，再返回；不会等待逃逸后代的 EOF，也不追杀逃逸组或任意 PID。正常操作系统进程终止与调度下，等待上限为 `timeout + 2 秒` 加短 poll/调度延迟（取消则为请求被观察后两秒），不承诺清理已经逃逸的进程或撤销其副作用。没有返回后继续排空输出的 Swift Task 或 IO 回调。

`ShellResult` 提供 `output`、`status`、`succeeded` 和 `trimmedOutput`。启动失败和超时分别抛 `ShellError.launchFailed` / `.timeout`。

输出最多保留末尾 8 MiB，超过后在 `output` 开头显示 `[输出已截断，仅保留末尾 8 MiB]` 和换行；标记计入返回字符串的 UTF-8 容量，非法 UTF-8 替代字符膨胀后也再次限制容量。有效 Unicode 尾部不会从多字节字符中间开始。未超过上限的小输出保持完整。需要完整大文件的命令应自行写文件，此接口用于命令结果和诊断。

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

`swift test` 覆盖预取消、运行取消不续下一条命令、重复取消与退出竞态、直接 PID 回收、owned group 与其他进程隔离、分别逃逸 stdout/stderr 的硬截止、连续洪流、公平读取、24 个并发命令、8 MiB 尾部与非法 UTF-8、同步入口及重复执行后的 FD 关闭。独立 C fixture 在子进程内 fork/setsid，测试需要系统 C 编译器。既有日志、引用、启动失败、自发信号、SIGTERM 忽略、回滚脚本与假 bundle 测试继续执行；macOS CI 还编译实际 AppKit / os.Logger 入口并运行原生更新验证。
