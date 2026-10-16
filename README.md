# Frit

[Pop](https://github.com/whrss9527/pop)、[Meno](https://github.com/whrss9527/meno)、[Stox](https://github.com/whrss9527/stox)、[Proxi](https://github.com/whrss9527/proxi) 共用的 Swift 库和发布流程。

Frit 是玻璃熔块，做玻璃之前先烧好的基础原料。这几个 App 都是玻璃质感的菜单栏工具，这里放它们共同的底子：一次写好、各处复用的代码，以及签名、公证、发版的流程。

## 里面有什么

| 部分 | 内容 | 状态 |
| --- | --- | --- |
| 发布流程 | 可复用的 GitHub Actions 工作流 `release-app.yml` 和 `scripts/release/` 里的脚本：从 CHANGELOG.md 定版本、打包、Developer ID 签名、苹果公证、钉票据、按芯片的精简包、校验和、草稿再公开的 Release，以及更新端到端测试用的假发布 | 可以用 |
| `FritCore` | 只依赖 Foundation 的纯逻辑，Linux 上也能测试：版本比较、发布与附件解析、校验和、安装位置、双语更新说明和容错 JSON；0.6.0 增加[同步基础类型](docs/sync.md) | 可以用；同步 Engine 与 App 接入另验收 |
| `FritUpdate` | macOS 一键更新核心及公共更新条/更新区、中英文语言覆盖、可选严格检查和保留旧包的原子替换 | 可以用 |
| `FritUI` | 三种玻璃表面、原生/磨砂按钮、浮动面板与首击/编辑快捷键，见[使用说明](docs/ui.md) | 从 0.5.0 提供；各 App 接入单独验收 |
| `FritSystem` | Shell、重启回滚和文件日志已提供；全局快捷键和录制控件、登录时启动、通知与权限待扩展 | 开发中 |
| `FritSync` | 显式URL的后台协调读写与App合并回调；目的格式/占位/大小保护，见[同步说明](docs/sync.md) | 0.7.0候选；冲突版本、迁移、Engine及App接入仍待 |

模块按功能平铺，统一用 `Frit` 前缀。当前的 FritCore 支持 macOS 13 和 iOS 17，CI 在 Linux/macOS 跑测试，并用 `xcodebuild -destination generic/platform=iOS` 编译验证。后续只在 macOS 上有意义的模块（一键更新、全局快捷键这些）将隔离平台实现。

### 版本号作为集合键

`AppVersion` 沿用 Foundation 的数字比较，因此 `1.2-beta.01` 与 `1.2.0-beta.1` 相等。哈希只使用去掉尾零的数字部分与是否为预发布版，以保持相等版本的 Set/Dictionary 查找正确，不改变比较或描述语义。同一数字版本下的不同预发布标记会共享哈希；大量这类键会增加碰撞和比较成本，不适合作为高吞吐索引。未来改进后缀哈希需要先证明与各平台 Foundation 的 Unicode/数字等价规则一致。

## 发布流程

### Frit 版本与引用

Frit 使用 `主版本.次版本.修订号`。修订版修复问题；次版本增加功能；1.0 以后不兼容的公共 API 或工作流输入变更升级主版本。0.x 阶段的不兼容变更升级次版本，并在 CHANGELOG 注明。`Unreleased` 保存尚未发布的变更，新版本合入 main 且该提交的完整 CI 通过后，由 `tag-version.yml` 创建 `v<版本>`，已有标签不会移动。手动运行也检查该提交的 CI；首次启用该工作流时创建当前的 `v0.1.0`。

Swift 包按版本引用，例如：

```swift
.package(url: "https://github.com/whrss9527/frit.git", .upToNextMinor(from: "0.1.0"))
```

0.x 阶段用 `upToNextMinor` 避免自动升级到可能破坏兼容性的次版本，并提交 `Package.resolved`。1.0 以后可用 `from:` 接收同一主版本内的兼容更新。

可复用工作流使用版本标签或完整提交 SHA，`uses: …@<ref>` 与 `frit-ref: <ref>` 必须相同。正式发版仍使用默认 `frit-ref: main` 会收到警告；框架无法从调用方的 GitHub 上下文可靠推断可复用工作流的引用。

在 App 仓库里加一个工作流，比如 `.github/workflows/release.yml`：

```yaml
name: release

on:
  workflow_run:
    workflows: [build]        # App 自己的 CI 在 main 上通过后
    types: [completed]
    branches: [main]
  workflow_dispatch:

permissions:
  contents: write

jobs:
  release:
    if: github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success'
    uses: whrss9527/Frit/.github/workflows/release-app.yml@<Frit 的提交或标签>
    with:
      app-name: Stox
      ref: ${{ github.event.workflow_run.head_sha || github.sha }}
      build-command: UNIVERSAL=1 scripts/build-app.sh && cd dist && ditto -c -k --keepParent Stox.app Stox.zip
      archives: dist/Stox.zip
      frit-ref: <和上面同一个提交或标签>
    secrets:
      MACOS_CERTIFICATE_P12: ${{ secrets.MACOS_CERTIFICATE_P12 }}
      MACOS_CERTIFICATE_PASSWORD: ${{ secrets.MACOS_CERTIFICATE_PASSWORD }}
      NOTARY_KEY_P8: ${{ secrets.NOTARY_KEY_P8 }}
      NOTARY_KEY_ID: ${{ secrets.NOTARY_KEY_ID }}
      NOTARY_ISSUER_ID: ${{ secrets.NOTARY_ISSUER_ID }}
      NOTARY_APPLE_ID: ${{ secrets.NOTARY_APPLE_ID }}
      NOTARY_PASSWORD: ${{ secrets.NOTARY_PASSWORD }}
      NOTARY_TEAM_ID: ${{ secrets.NOTARY_TEAM_ID }}
```

要发新版本时，在 CHANGELOG.md 最上面加一节（`## 0.46.0` 或 `## 0.46.0（2026-10-01）`）推到 main；CI 通过后，发现这个版本还没有标签，就自动打标签、打包、签名、公证并发布。

`build-command` 里能用这些环境变量：

| 变量 | 内容 |
| --- | --- |
| `VERSION` | 版本号，比如 `0.46.0`（不带 v） |
| `BUILD_NUMBER` | 提交数，可以用作 `CFBundleVersion` |
| `CODESIGN_IDENTITY`、`CODESIGN_KEYCHAIN`、`CODESIGN_NAME` | 配了证书时有值，签名用；没有时 ad-hoc 签名 |
| `FRIT_RELEASE` | Frit 发布脚本所在的目录，可以直接调用 `"$FRIT_RELEASE/sign.sh"`、`"$FRIT_RELEASE/thin-archives.sh"` |

其他参数（测试命令、发布说明、测试版、草稿恢复、必须公证、试运行）见 [`release-app.yml`](.github/workflows/release-app.yml) 开头的说明。0.2.0 起默认要求公证；只有开发自测才显式设 `require-notarization: false`。正式发布建议设置 `team-id` 为证书的 10 位团队 ID；每个归档的签名必须匹配。证书和公证凭据怎么配见 [docs/release.md](docs/release.md)。

升 Frit 次版本前必须通过一次四 App 下游矩阵。[downstream.yml](.github/workflows/downstream.yml) 可手动运行，也由完整 CI 在推送（含 main）时调用；版本标签等待包含矩阵的 CI。已接入的 App 使用当前 Frit 提交 SHA 编译、单测和更新 e2e，某列失败不会取消其他列。尚未声明 Frit Swift 包的 App 明确报告“未运行”，接入后自动生效，不能把该状态当成已验证。

已公开版本保持不变：核对附件、上传状态、原 `SHA256SUMS.txt` 和 GitHub 摘要后，完整发行只读跳过，不修改 notes、latest 或二进制；无 GitHub 摘要的旧附件会下载计算 SHA-256。公开发行缺件或摘要不一致时停止，要求发布新的补丁版本。`overwrite` 只用于标签已有的草稿，不能覆盖公开发行，也不会把公开发行转回草稿。脚本在发布锁内再次核验，定版本后已经由另一运行发出的版本也会跳过。

新发行与已有草稿上传前核对本次文件和校验和，上传后核对远端与本次清单一致，全部通过才公开。正式版公开前再次比较全部已公开的正式版，只有更高的版本才会标为 `latest`；旧标签的草稿恢复会显式设置 `latest=false`。预发布和草稿不参与比较。正式版标签无法解析或 GitHub 列表读取失败时停止发布，避免错误地改变更新入口。

### 发版前验证更新

0.3.0 起，调用方可设置 `update-e2e-command: scripts/update-e2e.sh`。命令在签名、公证、附件校验和完成后执行，可读取 `ARCHIVE_DIR`、`VERSION`、`SHA256SUMS_FILE` 和 `FRIT_RELEASE`；返回非零状态就停止，尚未打标签或发布。`dry-run` 同样执行这个命令。旧版下载、实际 App 启动与更新验证由调用方提供，接口约定见 [docs/release.md](docs/release.md)。

### 额外附件和归档别名

```yaml
extra-assets: dist/plugins-0.1.0.json dist/Plugins.zip
asset-aliases: dist/Proxi-macos.zip=dist/ProxySwitch-macos.zip
```

所有附件放在 `archives` 的同一个目录，路径用空格分隔，不支持文件名中的空格或特殊字符。额外附件只上传、计算校验和，不由 Frit 检查 `.app` 或公证；插件包仍需由调用方按自己的流程签名、公证。别名来源必须在 `archives` 里，目标必须是尚不存在的 zip；在苹果公证、钉票据并重新打包后才复制，因此别名与最终归档逐字节相同。

工作流输出 `assets` 是 JSON 数组，例如 `[{"name":"Proxi-macos.zip","sha256":"…"}]`，包含归档、额外附件、别名，不包含校验和文件本身。试运行也输出它，并上传上述附件、`SHA256SUMS.txt` 和 `release-assets.json`。未进行构建时输出为空。

### 脚本

都在 `scripts/release/`，本机也能直接用：

| 脚本 | 作用 |
| --- | --- |
| `sign.sh` | 签名：开 hardened runtime，有证书时带安全时间戳，可以带权限声明 |
| `import-certificate.sh` | 把 base64 的 .p12 导入临时钥匙串，给出签名身份 |
| `notarize.sh` | 提交公证、等结果、钉票据、重新打包；没通过时打印苹果的日志 |
| `thin-archives.sh` | 从通用二进制的 .app 打出 arm64、x86_64 两个精简包，重新签名 |
| `assets.sh` | 公证后复制别名，生成附件清单和校验和 |
| `plan.sh` | 判断是否发版；不存在或草稿发行在标签提交上恢复，公开发行只读核验 |
| `publish.sh` | 发布前核对标签与构建提交，上传全部附件后公开 Release |
| `check-release.py` | 核对本地/远端附件与校验和，保护已公开发行不被覆盖 |
| `changelog.sh` | 读 CHANGELOG.md 最上面的版本、取某个版本的一节 |
| `latest.py` | 比较全部正式版，防止重新打包旧版后 latest 倒退 |
| `fake-release.sh` | 更新端到端测试用：把 .app 改成 9.9.9，用本地 HTTP 服务器提供 GitHub 格式的 latest.json 和安装包 |
| `select-xcode.sh` | 在 GitHub 的 macOS runner 上切到最新的正式版 Xcode |

## 开发

公共更新逻辑的 API、各 App 对应的参数和迁移来源见 [docs/update-core.md](docs/update-core.md)。它们只整理数据；网络下载、签名验证、替换文件和界面由后续模块处理。

最小系统模块的线程、日志和重启约定见 [docs/system.md](docs/system.md)。

一键更新核心的配置、取消与安装语义见 [docs/update.md](docs/update.md)。

更新视图、语言覆盖和可打开的 Sample.app 见 [docs/update-views.md](docs/update-views.md)。

Meno 严格检查、原子替换和启动回滚配置见 [docs/atomic-update.md](docs/atomic-update.md)。

```bash
swift test                          # FritCore 单元测试（macOS 和 Linux）
python3 -m unittest discover -s Tests/release -p 'test_*.py' # 发布逻辑和附件清单测试
Tests/release/test-changelog.sh     # changelog.sh 测试（macOS 和 Linux）
Tests/release/test-update-e2e.sh    # 更新验证入口、失败传播和工作流顺序（macOS 和 Linux）
Tests/release/test-notarize.sh      # 公证超时与重试逻辑（替身命令，macOS 和 Linux）
Tests/release/test-publish.sh       # 发布竞态、失败恢复与附件完整性（macOS 和 Linux）
Tests/release/test-scripts.sh       # 发布脚本自测（macOS）：临时证书签名、精简包、假 xcrun 公证、假发布
```

CI 还会用一个示例 App 把 `release-app.yml` 从头到尾试运行一遍（不打标签、不发布）。

脚本要能在 macOS 自带的 bash 3.2 上运行：不用关联数组，`set -u` 下不展开空数组，变量后面紧跟中文或全角符号时写成 `${VAR}`。

## 许可证

MIT，见 [LICENSE](LICENSE)。

### 下游检查的源码与runner

下游工作流先在Linux只读发现四个App的已提交依赖声明，记录每个完整App SHA。只有已经声明Frit Swift包的列分配macOS，并在该精确SHA上继续固定依赖、编译、测试和更新e2e；其他列在Linux明确记录“未接入，原生未运行”。声明解析或检出失败会阻断发现，不视为未接入。四个App都保留独立来源摘要；整张矩阵绿色不表示四App均已迁移。该调度调整不改变Frit0.4.1的公开标签或App的发行流程。

公共玻璃、浮动面板和编辑快捷键见 [FritUI 使用说明](docs/ui.md)。该产品从 0.5.0 起提供；各 App 的实际接入和界面截图需单独验收。
