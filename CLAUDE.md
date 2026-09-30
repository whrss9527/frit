# CLAUDE.md

Frit 是 Pop、Meno、Stox、Proxi 共用的 Swift 库和发布流程，MIT 许可证。

## 写法

- 代码注释、脚本输出、README 和文档用中文，提交信息用英文，风格照各 App 仓库。
- 模块按功能平铺、统一用 `Frit` 前缀（FritCore、FritUpdate……）。只依赖 Foundation 的逻辑放 FritCore，要能在 Linux 上测试。
- 脚本要能在 macOS 自带的 bash 3.2 上跑：不用关联数组，`set -u` 下不展开空数组，变量后面紧跟中文或全角符号时写成 `${VAR}`。改了脚本跑 `shellcheck -x`，改了工作流跑 `actionlint`。
- 这里的改动会影响四个 App 的发版。改 `release-app.yml` 或 `scripts/release/` 时，同时更新 `Tests/release/` 里的自测，CI 里的「发布流程试运行」要能通过。
- 从 App 仓库搬代码进来时，在提交说明里写明来源（仓库和文件）。

## 规划和待办

Frit 的待办在私有仓库 [whrss9527/plan](https://github.com/whrss9527/plan) 的 `projects/infra.md` 里，名字以 `kit-` 开头的任务。流程见 plan 仓库的 `AGENTS.md`。
