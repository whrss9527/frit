#!/bin/bash
# 打标签、建 Release、上传附件并公开。release-app.yml 的「发布」一步调用。
#
#   scripts/release/publish.sh
#
# 环境变量：TAG、SHA（这次打包的提交）、APP_NAME、RELEASE_ASSETS（assets.sh 输出的完整附件列表，缺省用 ARCHIVES）、
# ARCHIVE_DIR（SHA256SUMS.txt 所在的文件夹）、
# NOTES_FILE、PRERELEASE（true 时作为测试版）、GH_TOKEN。
# 发布成功后把 tag 写进 $GITHUB_OUTPUT。
#
# 同一个 App 的发布一次只跑一个（release job 的 concurrency），但「定版本」在锁外面：连续推送两次时，
# 两次运行可能都判定「还没发过」。所以拿到锁之后在这里再核对一次标签：标签已经被另一次运行打在别的提交上，
# 就不上传这次的包，免得把这个提交打出的包传到别的提交的标签下。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/release/lib.sh
. "$here/lib.sh"

tagged="$(remote_tag_commit "$TAG")"
if [ -z "$tagged" ]; then
  git push origin "${SHA}:refs/tags/${TAG}"
elif [ "$tagged" != "$SHA" ]; then
  echo "::warning::${TAG} 已经打在提交 ${tagged} 上，和这次打包的提交 ${SHA} 不一样（多半是连续推送了两次，另一次运行先发了），这次的包不上传。那次发布如果没有传完，下一次运行会在标签指向的提交上接着发布。"
  exit 0
fi

flags=()
if [ "${PRERELEASE:-}" = "true" ]; then
  flags+=(--prerelease)
fi
if release_info "$TAG" >/dev/null; then
  gh release edit "$TAG" --notes-file "$NOTES_FILE"
else
  result=$?
  if [ "$result" != 1 ]; then
    echo "::error::查不到 ${TAG} 的 Release 状态，停止发布"
    exit 1
  fi
  gh release create "$TAG" --draft --verify-tag --title "${APP_NAME} ${TAG}" --notes-file "$NOTES_FILE" ${flags[@]+"${flags[@]}"}
fi
files=()
# shellcheck disable=SC2086
for archive in ${RELEASE_ASSETS:-$ARCHIVES}; do
  files+=("$archive")
done
files+=("${ARCHIVE_DIR}/SHA256SUMS.txt")
gh release upload "$TAG" "${files[@]}" --clobber
if [ "${PRERELEASE:-}" = "true" ]; then
  gh release edit "$TAG" --draft=false --prerelease
else
  gh release edit "$TAG" --draft=false --latest
fi
write_output tag "$TAG"
echo "已发布到 https://github.com/${GITHUB_REPOSITORY:-}/releases/tag/${TAG}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### ${APP_NAME} ${TAG} 已发布"
    echo "https://github.com/${GITHUB_REPOSITORY:-}/releases/tag/${TAG}"
  } >> "$GITHUB_STEP_SUMMARY"
fi
