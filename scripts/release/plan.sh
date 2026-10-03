#!/bin/bash
# 定这次要不要发版、发哪个版本、在哪个提交上打包。release-app.yml 的「定版本」一步调用，
# 在 App 仓库的检出目录里运行。
#
#   scripts/release/plan.sh
#
# 环境变量：
#   TAG        要发布的标签；留空时取 CHANGELOG（默认 CHANGELOG.md）最上面的版本
#   ARCHIVES   要上传的 zip，空格分隔；用来判断上次发布有没有传完
#   OVERWRITE  true 时标签已存在也重新打包、替换附件
#   DRY_RUN    true 时只试运行，在当前提交上打包
#   GH_TOKEN   查 Release 用
# 要发版时把 tag 和 sha 写进 $GITHUB_OUTPUT（不在 Actions 里时打印出来），不发版时什么都不写：
#   - 标签还没有：在当前提交上发布
#   - 标签已经有了，Release 也已公开、附件齐全：不发（除非 OVERWRITE）
#   - 标签已经有了，但 Release 还是草稿或者缺附件（上次发布中途失败）：在标签指向的提交上接着发布
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/release/lib.sh
. "$here/lib.sh"

if [ -z "${TAG:-}" ]; then
  version="$("$here/changelog.sh" version "${CHANGELOG:-CHANGELOG.md}")"
  TAG="v${version}"
fi
if ! [[ "$TAG" =~ ^v[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.]+)?$ ]]; then
  echo "::error::标签格式应该是 v主版本.次版本.修订号，比如 v0.46.0（现在是 ${TAG}）"
  exit 1
fi

sha="$(git rev-parse HEAD)"
if [ "${DRY_RUN:-}" = "true" ]; then
  echo "试运行 ${TAG}，提交 ${sha}（不打标签、不发布）"
else
  tagged="$(remote_tag_commit "$TAG")"
  if [ -n "$tagged" ]; then
    if [ "${OVERWRITE:-}" = "true" ]; then
      echo "${TAG} 已存在，在它指向的提交 ${tagged} 上重新打包"
    else
      complete=0
      release_complete "$TAG" "${ARCHIVES:-}" || complete=$?
      if [ "$complete" = 0 ]; then
        echo "${TAG} 已经发布过，这次不发版。要发版就在 CHANGELOG.md 最上面加一节新版本。"
        exit 0
      elif [ "$complete" = 2 ]; then
        echo "::error::查不到 ${TAG} 的 Release，没法判断上次有没有发完（见上面 gh 的输出）"
        exit 1
      fi
      echo "${TAG} 已经打了标签，但 Release 还是草稿或者缺附件（上次发布没有完成），在标签指向的提交 ${tagged} 上接着发布"
    fi
    sha="$tagged"
  else
    echo "发布 ${TAG}，提交 ${sha}"
  fi
fi
write_output tag "$TAG"
write_output sha "$sha"
