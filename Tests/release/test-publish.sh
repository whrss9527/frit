#!/bin/bash
# plan.sh 和 publish.sh 的测试，Linux 和 macOS 上都能跑：本地的裸仓库当 origin，假的 gh 把 Release 的状态记在文件里。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
release="$here/../../scripts/release"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

fail() { echo "失败：$*"; exit 1; }
pass() { echo "通过：$*"; }

# 假的 gh：release 的 view、create、edit、upload 和用于 latest 检查的分页 API。
#   $FAKE_GH/state   none / draft / published
#   $FAKE_GH/assets  已上传的文件名，一行一个
#   $FAKE_GH/calls   调用记录
# FAKE_GH_UPLOAD_FAIL=1 时上传失败，FAKE_GH_VIEW_ERROR=1 时查询报网络错误。
fake="$work/fakebin"
mkdir -p "$fake"
cat > "$fake/gh" <<'SH'
#!/bin/bash
set -euo pipefail
dir="${FAKE_GH:?}"
echo "gh $*" >> "$dir/calls"
if [ "$1" = api ]; then
  [ "${FAKE_GH_API_ERROR:-}" != 1 ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
  if [ -f "$dir/releases.json" ]; then
    cat "$dir/releases.json"
  else
    echo '[[]]'
  fi
  exit 0
fi
[ "$1" = release ] || { echo "fake gh: unexpected $*" >&2; exit 1; }
cmd="$2"
shift 3
state="$(cat "$dir/state" 2>/dev/null || echo none)"
case "$cmd" in
  view)
    [ "${FAKE_GH_VIEW_ERROR:-}" != 1 ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    [ "$state" != none ] || { echo "release not found" >&2; exit 1; }
    if [ $# -gt 0 ]; then
      echo "$state"
      cat "$dir/assets" 2>/dev/null || true
    fi
    ;;
  create)
    echo draft > "$dir/state"
    : > "$dir/assets"
    ;;
  upload)
    [ "${FAKE_GH_UPLOAD_FAIL:-}" != 1 ] || { echo "upload failed" >&2; exit 1; }
    for f in "$@"; do
      [ "$f" = --clobber ] && continue
      name="$(basename "$f")"
      grep -qxF "$name" "$dir/assets" 2>/dev/null || echo "$name" >> "$dir/assets"
    done
    ;;
  edit)
    for a in "$@"; do
      [ "$a" != --draft=false ] || echo published > "$dir/state"
    done
    ;;
  *) echo "fake gh: unexpected $cmd" >&2; exit 1 ;;
esac
SH
chmod +x "$fake/gh"
export PATH="$fake:$PATH" FAKE_GH="$work/gh"
mkdir -p "$FAKE_GH"
reset_gh() { rm -f "$FAKE_GH"/*; }

# App 仓库：提交 A 加了 1.0.0 这一节，提交 B 在 A 之后，版本没变。
git init -q --bare "$work/origin.git"
git init -q "$work/app"
cd "$work/app"
git remote add origin "$work/origin.git"
printf '# 更新日志\n\n## 1.0.0（2026-10-03）\n\n- 第一版\n' > CHANGELOG.md
git add CHANGELOG.md && git commit -q -m A
A="$(git rev-parse HEAD)"
git commit -q --allow-empty -m B
B="$(git rev-parse HEAD)"
git push -q origin HEAD:refs/heads/main 2>/dev/null

mkdir -p dist
echo zip > dist/App.zip
echo sums > dist/SHA256SUMS.txt
echo notes > "$work/notes.md"
export APP_NAME=App ARCHIVES=dist/App.zip ARCHIVE_DIR=dist NOTES_FILE="$work/notes.md"
export GITHUB_REPOSITORY=test/app

out="$work/out"
plan() { : > "$out"; GITHUB_OUTPUT="$out" "$release/plan.sh" > "$work/log" 2>&1; }
publish() { : > "$out"; GITHUB_OUTPUT="$out" TAG=v1.0.0 SHA="$1" "$release/publish.sh" > "$work/log" 2>&1; }
output() { awk -F= -v k="$1" '$1 == k { print $2 }' "$out"; }
remote_tag() { git ls-remote origin "refs/tags/$1" | awk '{ print $1 }'; }

# 1. 没有标签：在当前提交上发布
plan
if [ "$(output tag)" != v1.0.0 ] || [ "$(output sha)" != "$B" ]; then
  cat "$work/log"
  fail "没有标签时应该在当前提交上发布 v1.0.0"
fi
pass "没有标签时发布当前提交"

# 2. 连续推送两次：两次运行都定了要发，A 先发完，B 拿到锁后不能把自己的包传到 A 的标签下
publish "$A" || { cat "$work/log"; fail "发布 A"; }
[ "$(remote_tag v1.0.0)" = "$A" ] || fail "标签应该打在 A 上"
[ "$(output tag)" = v1.0.0 ] || fail "发布成功后要输出 tag"
[ "$(cat "$FAKE_GH/state")" = published ] || fail "发布后 Release 应该已公开"
uploads="$(grep -c 'release upload' "$FAKE_GH/calls")"
publish "$B" || { cat "$work/log"; fail "标签被别的提交占了时应该跳过而不是失败"; }
grep -q "不上传" "$work/log" || { cat "$work/log"; fail "应该说明为什么不上传"; }
[ -z "$(output tag)" ] || fail "没发布时不输出 tag"
[ "$(grep -c 'release upload' "$FAKE_GH/calls")" = "$uploads" ] || fail "B 不应该上传附件"
[ "$(remote_tag v1.0.0)" = "$A" ] || fail "标签应该还在 A 上"
pass "标签已被别的提交占了时不上传"

# 3. 已经发完：不再发版
plan
[ -z "$(output tag)" ] || { cat "$work/log"; fail "已经发完时不应该再发"; }
pass "已经发完时不发"

# 4. 上次发布中途失败（标签打了、附件没传上去）：在标签指向的提交上接着发
git push -q origin :refs/tags/v1.0.0 2>/dev/null
reset_gh
if FAKE_GH_UPLOAD_FAIL=1 publish "$A"; then fail "上传失败时 publish.sh 应该失败"; fi
if [ "$(remote_tag v1.0.0)" != "$A" ] || [ "$(cat "$FAKE_GH/state")" != draft ]; then
  fail "应该留下标签和草稿"
fi
plan
if [ "$(output tag)" != v1.0.0 ] || [ "$(output sha)" != "$A" ]; then
  cat "$work/log"
  fail "草稿没发完时应该在标签指向的 A 上接着发"
fi
publish "$A" || { cat "$work/log"; fail "接着发布"; }
if ! { [ "$(cat "$FAKE_GH/state")" = published ] && grep -qxF App.zip "$FAKE_GH/assets" && grep -qxF SHA256SUMS.txt "$FAKE_GH/assets"; }; then
  fail "接着发布后应该公开并且附件齐全"
fi
pass "上次没发完时接着发"

# 5. 已公开但缺附件也算没发完
grep -vxF App.zip "$FAKE_GH/assets" > "$work/assets" || true
mv "$work/assets" "$FAKE_GH/assets"
plan
[ "$(output sha)" = "$A" ] || { cat "$work/log"; fail "缺附件时应该接着发"; }
pass "缺附件时接着发"

# 6. overwrite：标签已存在也重新打包，用标签指向的提交
echo App.zip >> "$FAKE_GH/assets"
: > "$out"
OVERWRITE=true GITHUB_OUTPUT="$out" "$release/plan.sh" > "$work/log" 2>&1
[ "$(output sha)" = "$A" ] || { cat "$work/log"; fail "overwrite 时用标签指向的提交"; }
pass "overwrite"

# 7. 试运行：不管标签，在当前提交上打包
: > "$out"
DRY_RUN=true GITHUB_OUTPUT="$out" "$release/plan.sh" > "$work/log" 2>&1
[ "$(output sha)" = "$B" ] || { cat "$work/log"; fail "试运行用当前提交"; }
pass "试运行"

# 8. 查 Release 出错时失败，不能当成没发完
if FAKE_GH_VIEW_ERROR=1 plan; then cat "$work/log"; fail "查不了 Release 时应该失败"; fi
pass "查不了 Release 时失败"

# 9. 附注标签取它指向的提交
git tag -a v2.0.0 -m v2 "$A"
git push -q origin refs/tags/v2.0.0 2>/dev/null
reset_gh
: > "$out"
TAG=v2.0.0 GITHUB_OUTPUT="$out" "$release/plan.sh" > "$work/log" 2>&1
[ "$(output sha)" = "$A" ] || { cat "$work/log"; fail "附注标签应该取它指向的提交"; }
pass "附注标签"

# 10. 测试版
reset_gh
: > "$out"
GITHUB_OUTPUT="$out" TAG=v3.0.0-beta.1 PRERELEASE=true SHA="$B" "$release/publish.sh" > "$work/log" 2>&1 || { cat "$work/log"; fail "发布测试版"; }
if ! { grep -q "release create v3.0.0-beta.1 .*--prerelease" "$FAKE_GH/calls" && grep -q "release edit v3.0.0-beta.1 --draft=false --prerelease" "$FAKE_GH/calls"; }; then
  cat "$FAKE_GH/calls"
  fail "测试版要带 --prerelease"
fi
pass "测试版"

# 11. 标签格式不对
if TAG=1.0 plan; then fail "标签格式不对时应该失败"; fi
pass "标签格式检查"

# 12. 公证后生成的完整附件列表必须上传，补发判断也要包含额外附件和归档别名。
reset_gh
printf '{"plugins":[]}\n' > dist/plugins.json
export EXTRA_ASSETS=dist/plugins.json ASSET_ALIASES=dist/App.zip=dist/LegacyApp.zip
GITHUB_ENV="$work/asset-env" "$release/assets.sh" > "$work/asset-log"
RELEASE_ASSETS="$(sed -n 's/^RELEASE_ASSETS=//p' "$work/asset-env")"
export RELEASE_ASSETS
publish "$A" || { cat "$work/log"; fail "发布完整附件"; }
for asset in App.zip plugins.json LegacyApp.zip SHA256SUMS.txt; do
  grep -qxF "$asset" "$FAKE_GH/assets" || fail "没有上传 $asset"
done
if grep -qxF release-assets.json "$FAKE_GH/assets"; then
  fail "内部清单不应该当成发布附件"
fi
plan
[ -z "$(output tag)" ] || { cat "$work/log"; fail "附件齐全时不应该再发"; }
pass "上传完整附件，齐全时不再发"
for missing in plugins.json LegacyApp.zip; do
  grep -vxF "$missing" "$FAKE_GH/assets" > "$work/assets" || true
  mv "$work/assets" "$FAKE_GH/assets"
  plan
  [ "$(output sha)" = "$A" ] || { cat "$work/log"; fail "缺 $missing 时应该在标签提交上补发"; }
  publish "$A" || { cat "$work/log"; fail "补发 $missing"; }
  grep -qxF "$missing" "$FAKE_GH/assets" || fail "补发后仍缺少 $missing"
  pass "缺 $missing 时补发"
done

# 13. 发布前查询失败也不能当成不存在，更不能创建 Release 或覆盖已有附件。
reset_gh
if FAKE_GH_VIEW_ERROR=1 publish "$A"; then
  cat "$work/log"; fail "发布时查不了 Release 应该失败"
fi
if grep -qE 'release (create|edit|upload)' "$FAKE_GH/calls"; then
  cat "$FAKE_GH/calls"; fail "查询失败后不能修改 Release"
fi
[ -z "$(output tag)" ] || fail "查询失败时不输出发布成功"
pass "发布时查询失败不会创建或上传"

# 抽取后的实际发布入口也必须保留 PR #25 的 latest 决策。
reset_gh
printf '[[{"tag_name":"v2.0.0","draft":false,"prerelease":false}]]\n' > "$FAKE_GH/releases.json"
publish "$A" || { cat "$work/log"; fail "旧版补发"; }
grep -q -- '--latest=false' "$FAKE_GH/calls" || fail "旧版补发不能抢占 latest"
pass "实际发布脚本保留旧版不抢占 latest 的判断"
reset_gh
publish "$A" || { cat "$work/log"; fail "首次正式发布"; }
grep -q -- '--latest=true' "$FAKE_GH/calls" || fail "首个正式版应成为 latest"
pass "首个正式版标为 latest"
reset_gh
if FAKE_GH_API_ERROR=1 publish "$A"; then fail "分页查询失败应该阻止发布"; fi
if grep -qE 'release (create|edit|upload)' "$FAKE_GH/calls"; then
  fail "latest 查询失败后不能修改 Release"
fi
pass "latest 分页查询失败阻止修改 Release"

echo "plan.sh、publish.sh 测试通过"
