# 严格检查与原子替换

Meno 配置 `.strictChecks = [.minimumSystemVersion, .hostArchitecture, .nestedCode]`、`.installStrategy = .atomicSwap`、`.relocatesWhenTranslocated = false`，并使用 `.designatedRequirementOfCurrent`、预期 bundle identifier 和安装前重新检查最新发布。正式下载地址的仓库/标签约束默认对所有 App 开启，来自 #12。

最低系统版本读取 LSMinimumSystemVersion；不能解析的值会拒绝。架构读取 Bundle 的可执行架构，硬件用 `hw.optional.arm64` 判断，避免 Rosetta 进程把 Apple 芯片误当成 Intel。嵌套代码用 `kSecCSCheckNestedCode` 验证，并核对签名 identifier 与预期 bundle identifier。未知严格检查位继续明确失败。

下载与解压使用目标所在卷的 `itemReplacementDirectory`。安装前把已验证的新包复制到权限为 0700 的私有兄弟目录，保证 renamex_np 的两个目录同卷。交换成功返回旧副本；卷不支持交换时采用两步 move，最后移动失败尝试恢复旧副本。恢复也失败时保留唯一旧包和原下载，不随错误清理。权限不足的暂存授权回退也保留旧包，默认 `.staged` 的原 Stox 语义不变。

旧副本留在私有兄弟目录而不是系统替换目录，沿用当前 Meno 的跨进程清理修复。FritSystem Relauncher 等旧进程退出、打开新 App、观察 45 秒：新 App 未启动或提前退出时把新包移到 `.rejected`，再把旧包放回。新 App 正常运行满启动宽限期后再调 `Updater.finishPreviousUpdate()`（Meno 原来等八秒），清理旧包以确认健康；如果回滚发生，返回被拒绝版本给 App 提示。

清理只处理当前 App 的同目录、名称匹配且带格式标记的更新目录，拒绝符号链接。当前 App 不在原位置时不删除保留的旧包。迁移前 Meno 的 `UpdateLeftovers` 清理约定由 App 接入 PR 处理；本模块不假设其他 App 的旧 defaults 键。

测试验证原生目录交换、两步回退、最后移动失败恢复、恢复失败保留、清理路径限制、严格系统与架构校验和签名 identifier；完整网络安装测试同时运行暂存和原子策略。Sample.app 的真实重启与提前退出回滚通过 #22 的集成测试验证后再合并本扩展。

来源：Meno `Sources/Meno/Support/{UpdateInstaller,CodeSigning}.swift` 和启动八秒后清理的 `UpdateChecker.swift`（51c118699e56454df23ffa8eee80ac1a4cfae457）。重启脚本已于 #13 从同一版本迁入。基础发布来源与纯安装位置测试已于 #12 迁入。
