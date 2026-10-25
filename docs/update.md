# 一键更新核心

`FritUpdate` 依赖 `FritCore` 和最小 `FritSystem`。网络、签名和替换 API 只在 macOS 13 及以上提供；Linux 可以测试暂存替换与授权脚本，但不能验证 Security、AppKit 和 URLSession 下载委托的 macOS 行为。

```swift
import FritUpdate

var configuration = UpdateConfiguration(repository: "owner/app", appName: "Sample")
configuration.archive = .fixed("Sample.zip")
configuration.signer = .sameTeamAsCurrent
configuration.environmentPrefix = "SAMPLE"
configuration.defaultsKeyPrefix = "sample.update."
let updater = Updater(configuration: configuration) // 在 MainActor 中创建和使用
```

默认每六小时检查一次，自动检查启动后先等五秒；`startAutomaticChecks(enabled:)` 的闭包由 App 控制发行渠道、联网状态等条件。`stopAutomaticChecks()` 可以停止。`check(manual:)` 只检查，`install()` 启动安装，`checkAndInstall()` 会等安装结束。自动检查尊重跳过版本且同版本只通知一次；手动检查显示已跳过的版本。`automaticChecks`、`includePrereleases`、最后检查时间、跳过和通知版本保存在配置的 UserDefaults 和键前缀下。

检查、下载和验证阶段允许取消。替换开始后不再允许取消，防止把 App 留在中间状态。取消后恢复可安装状态；晚到的网络或进度回调不能覆盖新的状态。`notesSinceCurrent` 先给最新版本说明，再尝试取得跨版本内容。`routeName(url,index)` 可以给 `sessions(url)` 中的线路起名；缺省没有线路名。

## 下载与校验

`sessions` 返回按优先级尝试的 URLSessionConfiguration，检查、发布说明、校验文件与安装包都使用这些配置。配置会复制后使用，不改调用方的超时设置。下载接受预期大小和进度回调；HTTP 错误、大小不符、取消均不会把临时下载放到目标文件。校验优先使用 GitHub 的有效 SHA-256 digest；否则从 `SHA256SUMS.txt` 取唯一且没有冲突的文件名条目。不提供其中任意一种校验信息的发布只用于提示手动下载。

正式附件必须属于配置仓库和对应 GitHub 标签。`<PREFIX>_UPDATE_URL` 用于假发布测试：附件只允许与 feed 同源且在 feed 目录下。`<PREFIX>_TEST_TRANSLOCATED=1` 模拟搬到应用程序目录；`<PREFIX>_UPDATE_AUTO_INSTALL=1` 在自动检查发现可安装版本后直接安装。

## 签名与安装

`validate` 核对版本、可选 bundle identifier、`codesign --verify --deep --strict` 及配置的签名策略。`.team` 要求 Apple 信任链与指定 Team ID，`.sameTeamAsCurrent` 使用当前团队，`.designatedRequirementOfCurrent` 使用当前指定要求。开发用 ad-hoc 宿主没有团队或指定要求时，后两种仍要求新包签名有效；无法读取宿主身份则拒绝安装。`.any` 也要求有效签名。`alsoAccept` 添加过渡签名策略，不跳过签名校验。

当前只有 `.staged`：同目录暂存新包，把现有 App 移到旧目录，再把暂存包放到目标，最后删除旧目录。最终移动失败会尝试恢复旧目录；已暂存的包在授权重试时不会被先删除，仍有原下载时优先使用原下载。EACCES 可请求管理员授权；EPERM 不反复弹授权框，而提示用户检查 App 管理权限。安装成功返回的 previous 为 nil，按 Stox 原语义重启。Meno 的原子替换、保留旧包观察启动及严格检查在 #21 实现；当前对任何非空 `StrictChecks` 明确失败。

`finishPreviousUpdate(bundle:)` 在 App 稳定启动后清理本模块命名的旧目录，并返回已拒绝版本的信息。调用方可注入 `relaunch`，以便测试不退出测试宿主。正式 App 默认使用 FritSystem 的重启 helper。

## 日志与验证

保留 Stox 更新脚本识别的文案：`检查更新：有新版本`、`开始更新到`、`更新包校验通过（SHA-256 …）`、`已更新到 …，重新启动`。`UpdateLogger` 的 info/error 闭包可接 App 原有日志或 FritSystem FileLog。

macOS 单元测试启动独立回环 HTTP 服务，走下载进度、大小、404、取消、摘要优先与校验文件回退；构建 ad-hoc App 验证身份和签名，用完整检查→解压→验证→替换→重启回调验证状态机。Stox 的来源选择与授权脚本回归、Proxi 的临时替换/新建、Pop 和 Proxi 的权限分类测试同时迁入。测试不执行管理员授权对话框。

来源：Stox `Sources/Stox/{Updater,UpdateInstaller}.swift`、`Sources/StoxCore/UpdateReplacement.swift`、`Tests/StoxCoreTests/UpdateReplacementTests.swift`（d97ddd9）；Proxi `Sources/Proxi/System/{CodeSignature,UpdateInstaller}.swift`、`Tests/ProxiTests/LogicTests.swift`（f765bf4）；Pop `Pop/Update/UpdateInstaller.swift`、`PopTests/UpdateTests.swift`（db38be6）。纯发布与安装位置逻辑已在 #12 迁入，重启 helper 已在 #13 迁入。
