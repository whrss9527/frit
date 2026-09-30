#!/bin/bash
# 读 CHANGELOG.md。版本标题写成下面任意一种都认：
#   ## 0.45.0
#   ## 0.4.0（2026-09-29）
#   ## [0.4.0] - 2026-09-29
#   ## 0.5.0-beta.1
#
#   scripts/release/changelog.sh version [CHANGELOG.md]         最上面的版本号
#   scripts/release/changelog.sh notes 0.45.0 [CHANGELOG.md]    这个版本那一节的内容（不含标题，去掉首尾空行）
set -euo pipefail

version_of() {
  # 标题行里第一个像版本号的东西。
  sed -n 's/^## \[\{0,1\}v\{0,1\}\([0-9][0-9]*\(\.[0-9][0-9]*\)*\(-[0-9A-Za-z.]*[0-9A-Za-z]\)\{0,1\}\).*/\1/p'
}

case "${1:-}" in
  version)
    file="${2:-CHANGELOG.md}"
    [ -f "$file" ] || { echo "找不到 $file" >&2; exit 1; }
    version="$(version_of < "$file" | head -1)"
    [ -n "$version" ] || { echo "$file 里找不到版本标题（格式是「## 0.8.0」或「## 0.8.0（2026-09-28）」）" >&2; exit 1; }
    echo "$version"
    ;;
  notes)
    want="${2:?用法：changelog.sh notes 版本号 [CHANGELOG.md]}"
    want="${want#v}"
    file="${3:-CHANGELOG.md}"
    [ -f "$file" ] || { echo "找不到 $file" >&2; exit 1; }
    found=""
    printing=""
    body=""
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "## "*)
          [ -n "$printing" ] && break
          if [ "$(printf '%s\n' "$line" | version_of)" = "$want" ]; then
            printing=1
            found=1
          fi
          continue
          ;;
      esac
      if [ -n "$printing" ]; then
        body="${body}${line}
"
      fi
    done < "$file"
    [ -n "$found" ] || { echo "$file 里没有 ${want} 这一节" >&2; exit 1; }
    # 去掉首尾空行。
    printf '%s' "$body" | awk 'NF { started = 1 } started { lines[++n] = $0 } END { while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print lines[i] }'
    ;;
  *)
    echo "用法：changelog.sh version [文件] | changelog.sh notes 版本号 [文件]" >&2
    exit 1
    ;;
esac
