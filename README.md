# Frit

[Pop](https://github.com/whrss9527/pop)、[Meno](https://github.com/whrss9527/meno)、[Stox](https://github.com/whrss9527/stox)、[Proxi](https://github.com/whrss9527/proxi) 共用的 Swift 库和发布流程。

Frit 是玻璃熔块，做玻璃之前先烧好的基础原料。这几个 App 都是玻璃质感的菜单栏工具，这里放它们共同的底子：一次写好、各处复用的代码，以及签名、公证、发版的流程。

## 里面有什么

| 部分 | 内容 | 状态 |
| --- | --- | --- |
| 发布流程 | 可复用的 GitHub Actions 工作流 `release-app.yml` 和 `scripts/release/` 里的脚本：从 CHANGELOG.md 定版本、打包、Developer ID 签名、苹果公证、钉票据、按芯片的精简包、校验和、草稿再公开的 Release，以及更新端到端测试用的假发布 | 可以用 |
| `FritCore` | 只依赖 Foundation 的纯逻辑，Linux 上也能测试。现在有版本号解析和比较 | 开发中 |
| `FritUpdate` | 一键更新：检查、下载、校验、按团队 ID 校验签名、替换、重新启动，以及更新条和设置区的界面 | 计划中 |
| `FritUI` | 玻璃材质、卡片、按钮样式、浮动面板 | 计划中 |
| `FritSystem` | 全局快捷键和录制控件、登录时启动、通知、权限、日志 | 计划中 |
| `FritSync` | iCloud 云盘文件同步 | 计划中 |

模块按功能平铺，统一用 `Frit` 前缀。同时支持 macOS 13 和 iOS 17，只在 macOS 上有意义的模块（一键更新、全局快捷键这些）在 iOS 上编译为空。

## 发布流程

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
    secrets: inherit
```

要发新版本时，在 CHANGELOG.md 最上面加一节（`## 0.46.0` 或 `## 0.46.0（2026-10-01）`）推到 main；CI 通过后，发现这个版本还没有标签，就自动打标签、打包、签名、公证并发布。

`build-command` 里能用这些环境变量：

| 变量 | 内容 |
| --- | --- |
| `VERSION` | 版本号，比如 `0.46.0`（不带 v） |
| `BUILD_NUMBER` | 提交数，可以用作 `CFBundleVersion` |
| `CODESIGN_IDENTITY`、`CODESIGN_KEYCHAIN`、`CODESIGN_NAME` | 配了证书时有值，签名用；没有时 ad-hoc 签名 |
| `FRIT_RELEASE` | Frit 发布脚本所在的目录，可以直接调用 `"$FRIT_RELEASE/sign.sh"`、`"$FRIT_RELEASE/thin-archives.sh"` |

其他参数（测试命令、发布说明、测试版、重新打包已有版本、必须公证、试运行）见 [`release-app.yml`](.github/workflows/release-app.yml) 开头的说明。证书和公证凭据怎么配见 [docs/release.md](docs/release.md)。

正式版发布前会比较仓库中全部已公开的正式版。只有更高的版本（或重新打包当前最高版本的原标签）才会标为 `latest`；重打包旧版会显式设置 `latest=false`。预发布和草稿不参与比较。正式版标签无法解析或 GitHub 列表读取失败时停止发布，避免错误地改变更新入口。

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
| `plan.sh` | 判断是否发版；草稿或缺附件时在标签对应的提交上补发 |
| `publish.sh` | 发布前核对标签与构建提交，上传全部附件后公开 Release |
| `changelog.sh` | 读 CHANGELOG.md 最上面的版本、取某个版本的一节 |
| `latest.py` | 比较全部正式版，防止重新打包旧版后 latest 倒退 |
| `fake-release.sh` | 更新端到端测试用：把 .app 改成 9.9.9，用本地 HTTP 服务器提供 GitHub 格式的 latest.json 和安装包 |
| `select-xcode.sh` | 在 GitHub 的 macOS runner 上切到最新的正式版 Xcode |

## 开发

```bash
swift test                          # FritCore 单元测试（macOS 和 Linux）
python3 -m unittest discover -s Tests/release -p 'test_*.py' # 发布逻辑和附件清单测试
Tests/release/test-changelog.sh     # changelog.sh 测试（macOS 和 Linux）
Tests/release/test-notarize.sh      # 公证超时与重试逻辑（替身命令，macOS 和 Linux）
Tests/release/test-publish.sh       # 发布竞态、失败恢复与附件完整性（macOS 和 Linux）
Tests/release/test-scripts.sh       # 发布脚本自测（macOS）：临时证书签名、精简包、假 xcrun 公证、假发布
```

CI 还会用一个示例 App 把 `release-app.yml` 从头到尾试运行一遍（不打标签、不发布）。

脚本要能在 macOS 自带的 bash 3.2 上运行：不用关联数组，`set -u` 下不展开空数组，变量后面紧跟中文或全角符号时写成 `${VAR}`。

## 许可证

MIT，见 [LICENSE](LICENSE)。
