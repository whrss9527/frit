# Sample 实际更新测试

macOS 上执行 `bash Tests/release/test-update.sh`。测试构建通用 Sample.app，调用 `fake-release.sh` 提供 9.9.9 的回环 HTTP 发布，真实运行暂存与原子两种策略的检查、下载、校验、替换、重启与八秒健康确认，再验证错误校验和、缺附件和新包两秒内退出后的回滚。

Sample 的源码在 `Examples/UpdateE2ESample`。它是原有发布试运行 Sample 的主程序，保留 `--exit`、辅助程序、双架构与发布脚本签名自测。只在指定 `SAMPLE_UPDATE_URL` 后联网；`SAMPLE_UPDATE_AUTO_INSTALL=1` 直接安装，`SAMPLE_INSTALL_STRATEGY=atomic` 开启原子替换。测试 App 日志写入 `SAMPLE_UPDATE_LOG`，不会改用户的其他 App。

失败新包的 Info.plist 设置 `FritSampleFailAtStartup=true`。同一个真实 FritSystem Relauncher 观察到它退出后恢复旧包；旧包确认稳定后清理 rejected 目录、记录拒绝版本并停止再次自动安装，避免测试重试成循环。测试同时验证恢复版本、进程实际启动日志和签名。整个 macOS CI 步骤限制五分钟。

每次运行有独占临时目录和系统分配的端口。清理只停止路径在该目录内的 Sample 进程及自己启动的 HTTP 服务，不操作 /Applications。组件预览仍在独立的 `Examples/UpdateSample`，它不执行安装。

来源参考：Stox `scripts/ci-e2e.sh` 的 update 场景（d97ddd9），Pop `scripts/update-e2e.sh` 的负向更新用例（db38be6）；实际入口调用公共 FritUpdate 和 FritSystem，无复制安装器。
