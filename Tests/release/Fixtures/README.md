# 发布接口样本

`new-draft.json` 按 2026-10-13 授权读取的 GitHub 新建空草稿响应整理；标签替换为测试值，保留实际字段类型和边界：正整数发行 ID、`target_commitish: main`、`draft: true`、`published_at: null`、空附件列表。

同一次真实观察中，按标签的 REST 查询返回 404，按发行 ID 和授权分页列表可以查询。替身重现该行为，避免将公开发行的查询能力误用于草稿。`target_commitish` 不能作为构建 SHA；脚本单独核对 Git 标签指向的提交。
