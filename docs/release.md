# 发布、签名与公证

App 仓库调用 Frit 的 `release-app.yml` 发版。仓库的 Secrets 里有 Developer ID 证书和公证凭据时，发布流程会：

1. 把证书导入一个临时钥匙串（`scripts/release/import-certificate.sh`）；
2. 执行 App 的打包命令，用证书签名，带 hardened runtime 和安全时间戳（App 的打包脚本调用 `scripts/release/sign.sh`，或者用环境变量 `CODESIGN_IDENTITY` 自己签）；
3. 把 zip 提交苹果公证，通过后把票据钉到 `.app` 上再重新打包（`scripts/release/notarize.sh`）；
4. 算校验和、上传，Release 说明末尾注明「已用 Developer ID 签名并通过苹果公证」。

用户下载这样的包，解压后双击就能打开，不会再被 Gatekeeper 拦下。没有配置时照旧 ad-hoc 签名，发布日志里会有一条警告。

下面是一次性的准备工作，大约半小时。**同一套证书和凭据要在每个 App 仓库里各填一遍**（个人账号没有组织级的 Secrets）。

## 一、加入 Apple Developer Program

用 Apple ID 在 [developer.apple.com/programs/enroll](https://developer.apple.com/programs/enroll/) 或 Apple Developer App 里以**个人**身份注册，年费 99 美元（中国大陆 688 元）。Apple ID 需要开启双重认证。审核通过后会收到邮件。

Developer ID 签名和公证用个人账号就可以，不需要公司。

## 二、创建并导出 Developer ID Application 证书

1. 在 Mac 上打开 Xcode → 设置 → Accounts，登录开发者账号，选中团队，点「Manage Certificates…」，左下角「+」→「Developer ID Application」。
   （也可以在开发者网站的 Certificates, Identifiers & Profiles 里创建，需要先用「钥匙串访问 → 证书助理 → 从证书颁发机构请求证书」生成 CSR。）
2. 打开「钥匙串访问」，左边选「登录」，上面选「我的证书」，找到「Developer ID Application: 你的名字 (团队 ID)」。展开能看到下面的私钥，说明私钥在这台 Mac 上。
3. 在证书上右键 →「导出…」，格式选「个人信息交换 (.p12)」，设一个密码。
4. 转成一行 base64，复制到剪贴板：

   ```bash
   base64 -i DeveloperID.p12 | pbcopy
   ```

## 三、准备公证凭据（二选一）

**A. App Store Connect API 密钥（推荐）**

1. 登录 [App Store Connect](https://appstoreconnect.apple.com) → 用户和访问 → 集成 → App Store Connect API。第一次用要先点「请求访问」。
2. 在「团队密钥」里生成一个密钥，访问权限选「开发者」。
3. 下载 `.p8` 文件（只能下载一次，保存好），记下页面上的 **密钥 ID** 和 **Issuer ID**。

用个人密钥（个人资料里生成的）也可以，这时不填 Issuer ID。

**B. Apple ID + App 专用密码**

1. 在 [account.apple.com](https://account.apple.com) → 登录与安全 → App 专用密码，生成一个。
2. 在开发者网站的「会员资格详细信息」里找到 10 位的 **团队 ID**。

## 四、填进 GitHub Secrets

每个 App 仓库 → Settings → Secrets and variables → Actions → New repository secret，逐个添加：

| 名字 | 内容 |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | 第二步复制的 base64 |
| `MACOS_CERTIFICATE_PASSWORD` | 导出 .p12 时设的密码 |
| `NOTARY_KEY_P8` | A：`.p8` 文件的全部内容，直接粘贴（包括 BEGIN / END 两行） |
| `NOTARY_KEY_ID` | A：密钥 ID |
| `NOTARY_ISSUER_ID` | A：Issuer ID（个人密钥不填） |
| `NOTARY_APPLE_ID` | B：Apple ID 邮箱 |
| `NOTARY_PASSWORD` | B：App 专用密码 |
| `NOTARY_TEAM_ID` | B：团队 ID |

A 和 B 填一组就行，两组都填时用 A。

## 五、发布

在 CHANGELOG.md 最上面加一节新版本推到 main，或者在 Actions 页面手动运行 release。日志里：

- 「导入签名证书」会显示证书名字，应该是 `Developer ID Application: …`；
- 「检查签名」会列出每个包的版本和签名者；
- 「提交苹果公证并钉上票据」通常几分钟，最后 `spctl` 显示 `source=Notarized Developer ID` 就成功了；没通过时会打印苹果给的公证日志，里面写着是哪个文件、什么原因。

## 发版前的更新端到端验证

App 的可复用工作流调用增加 `update-e2e-command: scripts/update-e2e.sh`，命令由 App 仓库提供。Frit 在签名、公证并生成校验和后、打标签发布前运行它；非零退出状态直接阻断发布。命令也会在 dry-run 中运行。

命令可读取 `ARCHIVE_DIR`（最终归档目录）、`VERSION`（不含 v 的版本）、`SHA256SUMS_FILE`（完整校验和路径）和 `FRIT_RELEASE`（本次选用的发布脚本目录）。建议脚本先下载最新正式版，核对下载校验和及 Team ID，使用临时安装位置启动旧版，再将更新源指向本次构建，验证新进程启动和版本。

需要 9.9.9 假更新源时，先在临时目录解压最终归档，调用 `"$FRIT_RELEASE/fake-release.sh" 临时目录/App.app App.zip`。这个脚本会复制 App、保留权限声明、修改副本版本，并使用工作流已导入的 `CODESIGN_IDENTITY` 和 `CODESIGN_KEYCHAIN` 重新签名；内部程序保持原签名，不会被统一重签。未提供签名身份时使用 ad-hoc 签名，仅适合流程测试。它以本地 HTTP 服务器提供 `latest.json`、`releases.json`、安装包和校验和。将其输出的 `FAKE_RELEASE_URL` 传给 App 的测试更新源配置，结束后停止 `FAKE_RELEASE_PID` 并清理测试安装。Proxi 的「旧正式版 → 9.9.9」测试可作为调用方实现参考。

`fake-release.sh` 修改了 App，因此假更新包不保留原构建的公证票据。调用方应在临时测试安装中验证签名身份和更新流程，正式附件仍使用 `ARCHIVE_DIR` 中未经修改的归档。

## 要知道的几件事

- **一键更新会认签名**：从第一个签名版开始，App 只安装同一个团队 ID 签名的新版本。之后不要再发 ad-hoc 签名的版本，不然签名版的用户没法一键更新。Secrets 失效时发布日志里会出现「没有配置 MACOS_CERTIFICATE_P12」的警告，看到它先别发。
- **证书过期**：Developer ID 证书有效期五年。签名带着安全时间戳，已经发布的版本过期后照样能打开；发新版本前换一张新证书，更新每个仓库的 `MACOS_CERTIFICATE_P12` 和密码。团队 ID 不变，一键更新照常。
- **公证不审核功能**：公证只是苹果的自动恶意软件扫描，不看功能，一般几分钟出结果。
- **私钥保管**：`.p12` 和 `.p8` 只放在 GitHub Secrets 里，不要提交进仓库。泄露了就到开发者网站吊销证书或密钥，再换新的。

## 在自己的 Mac 上签名和公证

证书在登录钥匙串里时：

```bash
export CODESIGN_IDENTITY="Developer ID Application: 你的名字 (团队 ID)"
scripts/release/sign.sh dist/Foo.app/Contents/MacOS/helper      # 先签里面的程序
scripts/release/sign.sh dist/Foo.app Resources/Foo.entitlements  # 再签整个 .app
(cd dist && ditto -c -k --keepParent Foo.app Foo.zip)
NOTARY_APPLE_ID=… NOTARY_PASSWORD=… NOTARY_TEAM_ID=… scripts/release/notarize.sh dist/Foo.zip
```
