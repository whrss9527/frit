#!/bin/bash
# 打标签、建 Release、上传附件并公开。release-app.yml 的「发布」一步调用。
#
#   scripts/release/publish.sh
#
# 环境变量：TAG、SHA（这次打包的提交）、APP_NAME、RELEASE_ASSETS（assets.sh 输出的完整附件列表，缺省用 ARCHIVES）、
# ARCHIVE_DIR（SHA256SUMS.txt 所在的文件夹）、
# NOTES_FILE、PRERELEASE（true 时作为测试版）、OVERWRITE（只允许草稿）、GH_TOKEN。
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
if [ -n "$tagged" ] && [ "$tagged" != "$SHA" ]; then
  echo "::warning::${TAG} 已经打在提交 ${tagged} 上，和这次打包的提交 ${SHA} 不一样（多半是连续推送了两次，另一次运行先发了），这次的包不上传。那次发布如果没有传完，下一次运行会在标签指向的提交上接着发布。"
  exit 0
fi

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/frit-publish.XXXXXX")"
trap 'rm -rf "$work"' EXIT
expected="${RELEASE_ASSETS:-${ARCHIVES:-} ${EXTRA_ASSETS:-}}"
if [ -z "${RELEASE_ASSETS:-}" ]; then
  for mapping in ${ASSET_ALIASES:-}; do expected="$expected ${mapping#*=}"; done
fi
result=0
release_snapshot "$TAG" "$work/release.json" || result=$?
state=none
if [ "$result" = 0 ]; then
  state="$(python3 "$here/check-release.py" state "$TAG" "$work/release.json")"
elif [ "$result" != 1 ]; then
  echo "::error::查不到 ${TAG} 的 Release 状态，停止发布"
  exit 1
fi
# 锁内重新核对：定版本后可能已由另一次运行发布；公开内容永不覆盖。
if [ "$state" = published ]; then
  if [ -z "$tagged" ]; then
    echo "::error::${TAG} 已公开但远端标签不存在，停止发布并保留原发行"
    exit 1
  fi
  if [ "${OVERWRITE:-}" = true ]; then
    echo "::error::${TAG} 已公开，不允许 overwrite；请发布新的补丁版本"
    exit 1
  fi
  if ! python3 "$here/check-release.py" published "$TAG" "$work/release.json" "$expected"; then
    echo "::error::${TAG} 已公开但核验未通过；保留原发行，请发布新的补丁版本"
    exit 1
  fi
  echo "${TAG} 已公开且核验通过，这次不修改发行或附件"
  exit 0
fi
python3 "$here/check-release.py" local "$expected" "${ARCHIVE_DIR}/SHA256SUMS.txt"

latest_decision() {
  gh api --paginate "repos/${GITHUB_REPOSITORY:?没有设置 GITHUB_REPOSITORY}/releases?per_page=100" > "$work/releases.json" || return $?
  python3 "$here/check-release.py" pages "$work/releases.json" > "$work/pages.json" || return $?
  python3 "$here/latest.py" "$TAG" < "$work/pages.json"
}
if [ "${PRERELEASE:-}" != "true" ]; then
  # 保留 latest.py 的全部分页检查；抽成脚本后也不能让重打旧版抢占 latest。
  latest="$(latest_decision)"
fi
if [ -z "$tagged" ]; then
  git push origin "${SHA}:refs/tags/${TAG}"
fi
if [ "$state" = draft ]; then
  release_id="$(python3 "$here/check-release.py" id "$TAG" "$work/release.json")"
  python3 - "$NOTES_FILE" > "$work/notes.json" <<'PY'
import json, pathlib, sys
print(json.dumps({'body': pathlib.Path(sys.argv[1]).read_text()}))
PY
  gh api --method PATCH "repos/${GITHUB_REPOSITORY}/releases/${release_id}" --input "$work/notes.json" > "$work/edited.json"
else
  python3 - "$TAG" "$APP_NAME" "$NOTES_FILE" "${PRERELEASE:-false}" > "$work/create.json" <<'PY'
import json, pathlib, sys
print(json.dumps({'tag_name': sys.argv[1], 'name': sys.argv[2] + ' ' + sys.argv[1],
                  'body': pathlib.Path(sys.argv[3]).read_text(), 'draft': True, 'prerelease': sys.argv[4] == 'true'}))
PY
  gh api --method POST "repos/${GITHUB_REPOSITORY}/releases" --input "$work/create.json" > "$work/created.json"
  release_id="$(python3 "$here/check-release.py" id "$TAG" "$work/created.json")"
  if [ "$(python3 "$here/check-release.py" state "$TAG" "$work/created.json" "$release_id")" != draft ]; then
    echo "::error::新建发行没有保持草稿状态，停止上传"
    exit 1
  fi
fi
files=()
# shellcheck disable=SC2086
for archive in $expected; do
  files+=("$archive")
done
files+=("${ARCHIVE_DIR}/SHA256SUMS.txt")
# 另一发布入口可能在准备期间公开草稿，上传前再次确认状态。
release_snapshot "$TAG" "$work/before-upload.json" "$release_id"
if [ "$(python3 "$here/check-release.py" state "$TAG" "$work/before-upload.json")" != draft ]; then
  echo "::error::${TAG} 已被公开，停止覆盖附件；请核验原发行或发布新补丁版本"
  exit 1
fi
gh release upload "$TAG" "${files[@]}" --clobber
release_snapshot "$TAG" "$work/uploaded.json" "$release_id"
python3 "$here/check-release.py" draft "$TAG" "$work/uploaded.json" "$expected" "${ARCHIVE_DIR}/SHA256SUMS.txt"
if [ "$(remote_tag_commit "$TAG")" != "$SHA" ]; then
  echo "::error::${TAG} 的标签提交已经变化，保留草稿并停止公开"
  exit 1
fi
if [ "${PRERELEASE:-}" = "true" ]; then
  latest=false
else
  # 上传期间可能有其他工作流发布新版；公开前重新确认 latest 选择。
  latest="$(latest_decision)"
fi
python3 - "${PRERELEASE:-false}" "$latest" > "$work/public.json" <<'PY'
import json, sys
print(json.dumps({'draft': False, 'prerelease': sys.argv[1] == 'true', 'make_latest': sys.argv[2]}))
PY
gh api --method PATCH "repos/${GITHUB_REPOSITORY}/releases/${release_id}" --input "$work/public.json" > "$work/published.json"
if [ "$(python3 "$here/check-release.py" state "$TAG" "$work/published.json" "$release_id")" != published ]; then
  echo "::error::发行没有成功公开，不输出发布标签"
  exit 1
fi
write_output tag "$TAG"
echo "已发布到 https://github.com/${GITHUB_REPOSITORY:-}/releases/tag/${TAG}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### ${APP_NAME} ${TAG} 已发布"
    echo "https://github.com/${GITHUB_REPOSITORY:-}/releases/tag/${TAG}"
  } >> "$GITHUB_STEP_SUMMARY"
fi
