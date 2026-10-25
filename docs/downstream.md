# 下游兼容矩阵

`ci.yml` 调用可复用的 `downstream.yml`，每次推送含 main 都运行，标签沿用完整 main CI 门槛，因而会等待矩阵。也可在 Actions 手动运行 downstream。四列 `fail-fast: false`，分别 checkout Stox、Pop、Proxi、Meno 的 main；库固定到本次完整 Frit SHA，不修改 App 仓库或推送它们的锁文件。

`pin.py` 只替换已有 Frit 声明：SwiftPM 的 revision/from/版本范围，或 Pop 的 XcodeGen package。多条、无法闭合的声明会失败，不猜一个目标。没有 Frit 包的 App 列明确报告未运行，后续 AppVersion 接入后自动开始验证。当前首次启用时只有 Meno 已接入，其余三个 App 的接入 issue 仍开放；不能声称已经用该提交验证四个 App。

编译和单测使用各 App 现有方式：三个 SwiftPM App 跑 swift build/test，Pop 生成 Xcode 项目后跑 build/test。更新使用 Stox `ci-e2e.sh update`、Pop `update-e2e.sh`、已抽出的 Proxi `Scripts/ci/update-e2e.sh` 和已补齐的 Meno `check-updating.sh`。Proxi 保留测试脚本要求的 fish 和真实签名样本检查，没有为矩阵关闭它们。

每列 Step Summary 给出库和 App 提交、固定依赖及编译/单测/e2e 结果。失败的列上传已有日志。每列独占 macOS runner，可以运行 App 原有的 GUI 与更新测试，不与其他 App 共用用户目录。
