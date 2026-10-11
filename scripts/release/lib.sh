#!/bin/bash
# plan.sh 和 publish.sh 共用的函数，用 . 引入。

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

# 查询 Release；只有明确的 not found 才当作尚未创建，网络或权限错误不能触发重发。
# 返回 0：已找到并输出状态和附件；1：不存在；2：查不了。
release_info() {
  local info err
  err="$(mktemp)"
  if ! info="$(gh release view "$1" --json isDraft,assets --jq '(if .isDraft then "draft" else "published" end), (.assets[].name)' 2>"$err")"; then
    if grep -qi "not found" "$err"; then
      rm -f "$err"
      return 1
    fi
    cat "$err" >&2
    rm -f "$err"
    return 2
  fi
  rm -f "$err"
  printf '%s\n' "$info"
}

# Release 已经公开（不是草稿），并且每个附件和 SHA256SUMS.txt 都传上去了。
#   release_complete 标签 "dist/A.zip dist/plugins.json dist/LegacyA.zip"
# 返回 0：发完了；1：没有这个 Release、还是草稿或者缺附件；2：查不了（网络、权限）。
release_complete() {
  local info state assets archive name
  info="$(release_info "$1")" || return $?
  state="$(printf '%s\n' "$info" | head -1)"
  [ "$state" = "published" ] || return 1
  assets="$(printf '%s\n' "$info" | tail -n +2)"
  for archive in $2 SHA256SUMS.txt; do
    name="$(basename "$archive")"
    printf '%s\n' "$assets" | grep -qxF "$name" || return 1
  done
}

# 在 Actions 里写进 $GITHUB_OUTPUT，不在 Actions 里时打印出来。
write_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >> "$GITHUB_OUTPUT"
  else
    echo "$1=$2"
  fi
}
