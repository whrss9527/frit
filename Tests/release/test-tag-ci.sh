#!/bin/bash
# 模拟 CI 查询，确认失败、未完成、身份不符及网络错误都不能放行标签。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../../scripts/release/check-tag-ci.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'SH'
#!/bin/bash
set -euo pipefail
[ "$1" = api ]
[ "$2" = "repos/${GITHUB_REPOSITORY}/actions/workflows/ci.yml/runs?branch=main&head_sha=${FRIT_TEST_SHA}&per_page=1" ]
[ "$3" = --jq ]
if [ "${FRIT_TEST_CI_FAIL:-}" = 1 ]; then exit 1; fi
printf '%s\n' "${FRIT_TEST_CI_RESPONSE:-}"
SH
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH"
export GITHUB_REPOSITORY=test/frit
# 用自己的临时仓库模拟被检查的 main 提交，避免容器用户与工作区所有者不同。
git init -q "$work/repo"
cd "$work/repo"
git -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m fixture
FRIT_TEST_SHA="$(git rev-parse HEAD)"
export FRIT_TEST_SHA

deny() {
  if FRIT_TEST_CI_RESPONSE="$2" "$script" > "$work/log" 2>&1; then
    cat "$work/log" >&2
    echo "失败：$1 不应放行标签" >&2
    exit 1
  fi
  echo "通过：拒绝 $1"
}

FRIT_TEST_CI_RESPONSE="completed|success|${FRIT_TEST_SHA}|main|test/frit" "$script"
echo "通过：放行已通过完整 main CI 的提交"
deny "没有 CI" ""
deny "排队中的 CI" "queued|null|${FRIT_TEST_SHA}|main|test/frit"
deny "运行中的 CI" "in_progress|null|${FRIT_TEST_SHA}|main|test/frit"
deny "失败的 CI" "completed|failure|${FRIT_TEST_SHA}|main|test/frit"
deny "取消的 CI" "completed|cancelled|${FRIT_TEST_SHA}|main|test/frit"
deny "跳过的 CI" "completed|skipped|${FRIT_TEST_SHA}|main|test/frit"
deny "其他提交的 CI" "completed|success|0000000000000000000000000000000000000000|main|test/frit"
deny "其他分支的 CI" "completed|success|${FRIT_TEST_SHA}|feature|test/frit"
deny "其他仓库的 CI" "completed|success|${FRIT_TEST_SHA}|main|other/frit"
if FRIT_TEST_CI_FAIL=1 "$script" > "$work/log" 2>&1; then
  echo "失败：查询出错不应放行标签" >&2
  exit 1
fi
echo "通过：查询失败就停止"
