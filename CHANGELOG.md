# 更新日志

Frit 的版本号和发布说明。App 仓库在 `uses:` 里写的 `@` 后面可以是这里的版本标签，也可以是某个提交。

## 0.1.0

- 可复用的发布工作流 `release-app.yml`：从 CHANGELOG.md 定版本，打包、签名、公证、钉票据，生成 SHA256SUMS.txt，先建草稿再公开。
- 发布脚本 `scripts/release/`：导入证书、签名、公证、精简包、读 CHANGELOG、更新测试用的假发布、选择 Xcode。
- FritCore：`AppVersion`，版本号解析和比较（含测试版）。
