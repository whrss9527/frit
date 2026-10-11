#!/bin/bash
# 本地裸仓库验证 Frit 版本标签，不连接 GitHub，也不移动已有标签。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../../scripts/release/tag-version.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
FRIT_TEST_REAL_GIT="$(command -v git)"
export FRIT_TEST_REAL_GIT
git init -q --bare "$work/origin.git"
git init -q "$work/app"
cd "$work/app"
git remote add origin "$work/origin.git"

fail() { cat "$work/log" >&2; echo "失败：$*" >&2; exit 1; }
pass() { echo "通过：$*"; }
record() {
  printf '# 更新日志\n\n## Unreleased\n\n## %s\n\n- 测试\n' "$1" > CHANGELOG.md
  git add CHANGELOG.md
  git commit -qm "Version $1"
}
remote_tag() { git ls-remote origin "refs/tags/$1" | awk '{print $1}'; }

record 0.1.0
first="$(git rev-parse HEAD)"
"$script" > "$work/log" 2>&1 || fail "创建首个标签"
[ "$(remote_tag v0.1.0)" = "$first" ] || fail "首个标签没有指向版本提交"
pass "忽略 Unreleased，创建 v0.1.0"

git commit -q --allow-empty -m Later
"$script" > "$work/log" 2>&1 || fail "重复执行"
[ "$(remote_tag v0.1.0)" = "$first" ] || fail "重复执行移动了旧标签"
pass "重复执行不移动标签"

record 0.2.0
second="$(git rev-parse HEAD)"
"$script" > "$work/log" 2>&1 || fail "创建新版本标签"
[ "$(remote_tag v0.2.0)" = "$second" ] || fail "新标签没有指向新版本提交"
[ "$(remote_tag v0.1.0)" = "$first" ] || fail "新版本影响了旧标签"
pass "新版本创建独立标签"

record 1.2
if "$script" > "$work/log" 2>&1; then fail "不完整版本号应该失败"; fi
[ -z "$(remote_tag v1.2)" ] || fail "无效版本创建了标签"
pass "拒绝不完整版本号"

mkdir "$work/bin"
cat > "$work/bin/git" <<'SH'
#!/bin/bash
if [ "$1" = ls-remote ] && [ "${FRIT_TEST_REMOTE_FAIL:-}" = 1 ]; then exit 1; fi
if [ "$1" = push ] && [ "${FRIT_TEST_PUSH_FAIL:-}" = 1 ]; then exit 1; fi
exec "$FRIT_TEST_REAL_GIT" "$@"
SH
chmod +x "$work/bin/git"
record 0.3.0
if PATH="$work/bin:$PATH" FRIT_TEST_REMOTE_FAIL=1 "$script" > "$work/log" 2>&1; then fail "远端查询失败不能创建标签"; fi
[ -z "$(remote_tag v0.3.0)" ] || fail "远端查询失败后仍创建了标签"
pass "远端查询失败就停止"

if PATH="$work/bin:$PATH" FRIT_TEST_PUSH_FAIL=1 "$script" > "$work/log" 2>&1; then fail "标签推送失败不能报告成功"; fi
[ -z "$(remote_tag v0.3.0)" ] || fail "失败的推送仍创建了标签"
pass "保留标签推送失败状态"

echo "Frit 版本标签测试通过"
