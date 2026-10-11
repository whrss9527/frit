#!/bin/bash
# main 合入版本记录后创建 Frit 自己的版本标签；已有标签不移动。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
version="$("$here/changelog.sh" version "${CHANGELOG:-CHANGELOG.md}")"
if ! [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$ ]]; then
  echo "::error::Frit 版本需要主版本.次版本.修订号，例如 0.1.0（现在是 ${version}）"
  exit 1
fi
tag="v${version}"
sha="$(git rev-parse HEAD)"
existing="$(git ls-remote origin "refs/tags/${tag}")"
if [ -n "$existing" ]; then
  echo "${tag} 已存在，不移动标签"
  exit 0
fi
git push origin "${sha}:refs/tags/${tag}"
echo "已创建 ${tag}，提交 ${sha}"
