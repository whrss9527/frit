#!/bin/bash
# changelog.sh 的测试，Linux 和 macOS 上都能跑。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
changelog="$here/../../scripts/release/changelog.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

check() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" != "$actual" ]; then
    printf '%s\n期望：\n%s\n实际：\n%s\n' "$label" "$expected" "$actual"
    exit 1
  fi
  echo "通过：$label"
}

cat > "$work/a.md" <<'MD'
# 更新日志

说明文字。

## 0.4.0（2026-09-29）

### 新增

- 第一条
- 第二条

## 0.3.1（2026-09-20）

- 修好了一个问题

MD
check "0.4.0" "$("$changelog" version "$work/a.md")" "带日期的标题"
check "$(printf '### 新增\n\n- 第一条\n- 第二条')" "$("$changelog" notes v0.4.0 "$work/a.md")" "取一节内容"
check "- 修好了一个问题" "$("$changelog" notes 0.3.1 "$work/a.md")" "最后一节"

printf '## [1.2.0-beta.1] - 2026-01-01\n- a\n## 1.10.0\n- b\n' > "$work/b.md"
check "1.2.0-beta.1" "$("$changelog" version "$work/b.md")" "方括号和测试版"
check "- b" "$("$changelog" notes 1.10.0 "$work/b.md")" "不会把 1.1 当成 1.10"
printf '## 1.1\n- c\n## 1.10.0\n- b\n' > "$work/c.md"
check "- c" "$("$changelog" notes 1.1 "$work/c.md")" "版本号要完全一致"

if "$changelog" notes 9.9 "$work/a.md" >/dev/null 2>&1; then echo "没有这一节时应该失败"; exit 1; fi
printf '# 空的\n' > "$work/d.md"
if "$changelog" version "$work/d.md" >/dev/null 2>&1; then echo "没有版本时应该失败"; exit 1; fi
echo "changelog.sh 测试通过"
