#!/bin/bash
# plan.sh 和 publish.sh 共用的函数，用 . 引入。
frit_release_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 远端标签指向的提交；没有这个标签时输出空。附注标签取它指向的提交。
remote_tag_commit() {
  local refs peeled
  refs="$(git ls-remote origin "refs/tags/$1" "refs/tags/$1^{}")" || return 1
  peeled="$(printf '%s\n' "$refs" | awk 'index($2, "^{}") { print $1; exit }')"
  if [ -n "$peeled" ]; then
    echo "$peeled"
  else
    printf '%s\n' "$refs" | awk 'NF { print $1; exit }'
  fi
}

# 草稿不能用 tags 端点查询；完整分页精确定位，后续按创建响应的 ID 查询。
# 返回 0：快照写入 $2；1：不存在；2：查不了。
release_snapshot() {
  local work id result
  work="$(mktemp -d)"
  id="${3:-}"
  if [ -z "$id" ]; then
    if ! gh api --paginate "repos/${GITHUB_REPOSITORY:?没有设置 GITHUB_REPOSITORY}/releases?per_page=100" > "$work/releases.json"; then
      rm -rf "$work"; return 2
    fi
    result=0
    id="$(python3 "$frit_release_lib_dir/check-release.py" select "$1" "$work/releases.json")" || result=$?
    if [ "$result" = 3 ]; then rm -rf "$work"; return 1; fi
    if [ "$result" != 0 ]; then rm -rf "$work"; return 2; fi
  fi
  if ! gh api "repos/${GITHUB_REPOSITORY:?没有设置 GITHUB_REPOSITORY}/releases/$id" > "$2"; then
    rm -rf "$work"; return 2
  fi
  if ! python3 "$frit_release_lib_dir/check-release.py" state "$1" "$2" "$id" >/dev/null; then
    rm -rf "$work"; return 2
  fi
  rm -rf "$work"
}

# 公开发行只读核验：附件、上传状态、校验和与服务端摘要必须一致。
#   release_complete 标签 "dist/A.zip dist/plugins.json dist/LegacyA.zip"
# 返回 0：公开且完整；1：不存在或草稿；2：查询/核验失败，不能自动补发。
release_complete() {
  local work result state
  work="$(mktemp -d)"
  result=0
  release_snapshot "$1" "$work/release.json" || result=$?
  if [ "$result" != 0 ]; then rm -rf "$work"; return "$result"; fi
  if ! state="$(python3 "$frit_release_lib_dir/check-release.py" state "$1" "$work/release.json")"; then
    rm -rf "$work"; return 2
  fi
  if [ "$state" = draft ]; then rm -rf "$work"; return 1; fi
  if ! python3 "$frit_release_lib_dir/check-release.py" published "$1" "$work/release.json" "$2"; then
    echo "::error::${1} 已公开但核验未通过；保留原发行，请发布新的补丁版本" >&2
    rm -rf "$work"; return 2
  fi
  rm -rf "$work"
}

# 在 Actions 里写进 $GITHUB_OUTPUT，不在 Actions 里时打印出来。
write_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >> "$GITHUB_OUTPUT"
  else
    echo "$1=$2"
  fi
}
