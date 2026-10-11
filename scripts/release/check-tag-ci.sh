#!/bin/bash
# 版本标签只引用已经通过完整 main CI 的提交，手动运行也不绕过检查。
set -euo pipefail
: "${GITHUB_REPOSITORY:?需要 GITHUB_REPOSITORY}"
sha="$(git rev-parse HEAD)"
result="$(gh api "repos/${GITHUB_REPOSITORY}/actions/workflows/ci.yml/runs?branch=main&head_sha=${sha}&per_page=1" \
  --jq '.workflow_runs[0] | if . == null then "" else "\(.status)|\(.conclusion)|\(.head_sha)|\(.head_branch)|\(.head_repository.full_name)" end')"
if [ "$result" != "completed|success|${sha}|main|${GITHUB_REPOSITORY}" ]; then
  echo "::error::${sha} 的最新 main CI 尚未通过，不创建版本标签" >&2
  exit 1
fi
echo "${sha} 的完整 main CI 已通过"
