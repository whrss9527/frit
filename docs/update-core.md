# 公共更新逻辑

FritCore 只依赖 Foundation，支持 Linux、macOS 13 和 iOS 17。这里的 API 记在 Unreleased，随下一次 0.2.0 定版加入；0.1.0 标签的边界仍只有 `AppVersion` 和已有发布流程。

## 发布、通道和附件

`ReleaseFeed.parse(_:)` 接受 GitHub 的单个发布对象或数组，返回 `nil` 表示格式无法读取。草稿和坏的列表元素被跳过，预发布信息保留。`newest(_:channel:)` 和 `releases(_:after:upTo:channel:)` 排除无效版本；正式版通道还排除 GitHub 的 prerelease 标记或版本号中的预发布后缀。

`GitHubRelease` 保留标签、页面地址、说明、日期、草稿和预发布标记，以及所有可读附件。`asset(named:publishedBy:)` 只认 `https://github.com/<owner>/<repo>/releases/download/<tag>/` 下的附件，拒绝其他仓库、标签、主机和路径穿越。

```swift
import FritCore

let releases = ReleaseFeed.parse(data) ?? []
if let latest = ReleaseFeed.newest(releases, channel: .stable) {
    let candidate = UpdateCandidate(
        release: latest,
        naming: .fixed("Stox.zip"),
        architecture: .arm64,
        publishedBy: "whrss9527/stox"
    )
    // canInstall 表示有安装包和至少一个校验来源；安装前仍需真正校验文件。
    let canInstall = candidate.canInstall
}
```

| App | 附件命名 |
| --- | --- |
| Stox | `.fixed("Stox.zip")` |
| Meno | `.fixed("Meno.zip")`；旧改名包回退可用 `.custom` |
| Pop | `.versioned(prefix: "Pop-")`，先取带本版本号的包，再退回前缀匹配 |
| Proxi | `.perArchitecture(universal: "Proxi-macos.zip", thin: { "Proxi-macos-\($0.rawValue).zip" })` |

`ArchiveNaming.asset(in:architecture:)` 只按名称选择，方便已验证的测试源使用；正式源应使用带 `publishedBy` 的 `UpdateCandidate` 初始化器，它先过滤附件来源，外来同名链接不会抢占合法附件。`.custom` 只能返回传入列表中的附件。

`Asset.sha256` 只接受 `sha256:` 后的 64 位 ASCII 十六进制。`GitHubRelease.expectedSHA256(for:checksums:)` 优先采用它，否则使用 `Checksums.parse(_:)` 的 shasum 清单。清单支持空格文件名、二进制模式的 `*` 标记和 CRLF；同名但不同哈希的记录被拒绝。

## 安装位置

`InstallLocation.plan(bundle:appName:translocated:original:readOnly:relocates:folders:canWrite:)` 不访问文件系统。调用方传入实际的位置、磁盘状态、候选应用目录和可写判断。

- 正常可写的 `.app` 原地更新。
- `relocates: true` 保留 Stox、Pop、Proxi 的搬家规则：优先可写目录，没有时用第一个目录交给后续授权；原位置已在应用目录时在那里替换。
- `relocates: false` 保留 Meno 的规则：临时转移或只读时返回 `nil`，由 App 提示用户先移动程序。
- `appName` 可写 `Stox` 或 `Stox.app`；搬家计划的 `trashAfter` 表示更新成功之后才清理的旧位置。

## 说明和完整性

`ReleaseNotes.Style.stox(language:)` 提取“更新内容”，按 `### 中文` / `### English` 选择语言，没有翻译时保留已有内容。`.meno(language:)` 按独立的 `---` 行分隔英文和中文，并隐藏重复安装说明与已知限制。可通过 `Style` 自定义标题、隐藏章节和分隔符。

`blocks` 保留标题、列表和段落并合并折行；`highlights`、`combined`、`firstLines`、`headline` 保留 Stox 原有的摘要形式。所有语言选择都是参数，不读取 App 的全局设置。

`UpdateNotes` 收集当前版本之后到最新版本为止的说明，去重并从新到旧排序。读不到列表时只保留最新版本，`isComplete` 为 false。一页达到 100 条而没有覆盖当前版本时也为 false。调用方过滤过原始页时须传 `receivedCount`（接口原始条数），避免把过滤后的短列表当成最后一页。

## 来源与测试

| 来源提交 | 原文件 | 迁入内容 |
| --- | --- | --- |
| meno `51c118699e56454df23ffa8eee80ac1a4cfae457` | `Sources/MenoCore/Support/UpdateRelease.swift`、`UpdateNotes.swift` | Decodable 发布形状、附件来源限制、摘要回退、说明块与完整性 |
| 同上 | `Sources/MenoCore/Support/TolerantJSON.swift`、`LossyArray.swift` | 原样复制，保留行为和注释 |
| stox `d97ddd9a66ee86b131880ad5de583938c110c801` | `Sources/StoxCore/Update.swift` | 发布字段、区间、校验清单、安装位置、说明摘要 |
| pop `db38be6ab3ebac95cca484a33bfb1e6b3e855c15` | `Pop/Update/UpdateChecker.swift`、`UpdateInstaller.swift` | 列表或对象、测试版通道、版本附件名、校验和和安装位置 |
| proxi `f765bf4f2cbcb25c49bfd1c81997d5781c352529` | `Sources/ProxiEngine/System/UpdateChecker.swift`、`UpdateInstaller.swift` | 精简包回退、校验清单和安装位置 |

测试从 Meno 的 `UpdateReleaseTests.swift`、`UpdateNotesTests.swift`、`SettingsTests.swift`，Stox 的 `UpdateTests.swift`，Pop 的 `UpdateTests.swift`，Proxi 的 `Tests/ProxiTests/LogicTests.swift` 更新部分迁入。API 名称和参数按公共接口调整；App 专有的测试源、通知频率、UI 渲染、签名与文件替换测试仍留在对应 App，后续模块分别承接。

运行 `swift test`。既有 Linux/macOS CI 会自动运行全部 FritCore 测试；这一批不修改发布脚本或 App 的安装器。
