#!/bin/bash
# 用假更新命令验证输入、失败传播和发布阻断；不操作真实 App 或 GitHub Release。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../../scripts/release/update-e2e.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/dist"
printf 'checksum  Sample.zip\n' > "$work/dist/SHA256SUMS.txt"
fail() { echo "失败：$*" >&2; exit 1; }

UPDATE_E2E_COMMAND='' "$script" || fail "空命令应跳过"
echo "通过：空命令跳过"

# 命令中的变量由子 shell 展开。
# shellcheck disable=SC2016
env ARCHIVE_DIR="$work/dist" VERSION=1.2.3 FRIT_TEST_ARCHIVE_DIR="$work/dist" FRIT_TEST_MARKER="$work/passed" \
  UPDATE_E2E_COMMAND='[ "$VERSION" = 1.2.3 ] && [ "$ARCHIVE_DIR" = "$FRIT_TEST_ARCHIVE_DIR" ] && [ -s "$SHA256SUMS_FILE" ] && printf "passed\n" > "$FRIT_TEST_MARKER"' \
  "$script" || fail "未传递更新验证输入"
[ "$(cat "$work/passed")" = passed ] || fail "没有执行更新命令"
echo "通过：执行命令并传递归档、版本和校验和路径"

result=0
# shellcheck disable=SC2016
env ARCHIVE_DIR="$work/dist" VERSION=1.2.3 UPDATE_E2E_COMMAND='exit 23' \
  FRIT_TEST_GATE="$script" FRIT_TEST_PUBLISHED="$work/published" \
  bash -c '"$FRIT_TEST_GATE" && touch "$FRIT_TEST_PUBLISHED"' || result=$?
[ "$result" = 23 ] || fail "命令失败状态被吞掉"
[ ! -e "$work/published" ] || fail "失败后仍继续发布"
echo "通过：失败保留退出状态并阻断后续发布"

rm "$work/dist/SHA256SUMS.txt"
if ARCHIVE_DIR="$work/dist" VERSION=1.2.3 UPDATE_E2E_COMMAND=true "$script" > "$work/missing.log" 2>&1; then
  fail "缺少校验和时不能验证更新"
fi
grep -q '缺少更新验证需要的校验和' "$work/missing.log" || fail "缺少校验和没有诊断信息"
echo "通过：缺少校验和时停止"

python3 - "$here/../../.github/workflows/release-app.yml" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
assets = s.index('run: .frit/scripts/release/assets.sh')
gate = s.index('run: .frit/scripts/release/update-e2e.sh')
publish = s.index('      - name: 发布\n')
assert assets < gate < publish, '更新验证必须在校验和后、发布前'
block = s[s.rfind('      - name:', 0, gate):gate]
assert 'inputs.update-e2e-command' in block
assert 'inputs.dry-run' not in block, 'dry-run 也应执行配置好的更新命令'
PY
echo "通过：工作流顺序和 dry-run 入口"
