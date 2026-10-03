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

# 假的 gh：只认 release 的 view、create、edit、upload。
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

echo "plan.sh、publish.sh 测试通过"
