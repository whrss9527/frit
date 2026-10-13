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

# 假的 gh：按 ID 创建/查询/公开草稿，上传、下载及完整分页列表。
#   $FAKE_GH/state   none / draft / published
#   $FAKE_GH/assets  已上传的文件名，一行一个
#   $FAKE_GH/calls   调用记录
# FAKE_GH_UPLOAD_FAIL=1 时上传失败，FAKE_GH_VIEW_ERROR=1 时查询报网络错误。
fake="$work/fakebin"
mkdir -p "$fake"
cat > "$fake/gh" <<'PY'
#!/usr/bin/env python3
import hashlib, json, os, pathlib, shutil, sys
root = pathlib.Path(os.environ['FAKE_GH'])
a = sys.argv[1:]
with (root / 'calls').open('a') as stream: stream.write('gh ' + ' '.join(a) + '\n')
def read(name, default=''):
    path = root / name
    return path.read_text().strip() if path.exists() else default
def write(name, value): (root / name).write_text(value + '\n')
def fail(message): print(message, file=sys.stderr); sys.exit(1)
def argument(flag): return a[a.index(flag) + 1]
def snapshot():
    assets = []
    for name in read('assets').splitlines():
        data = (root / ('asset-' + name)).read_bytes()
        assets.append({'name': name, 'size': len(data), 'state': 'uploaded', 'digest': 'sha256:' + hashlib.sha256(data).hexdigest()})
    return {'id': 41, 'tag_name': read('tag', os.environ.get('TAG', 'v1.0.0')), 'draft': read('state', 'none') == 'draft', 'prerelease': read('prerelease') == 'true', 'assets': assets}
if a[0] == 'api':
    endpoint = next(value for value in a[1:] if value.startswith('repos/'))
    method = argument('--method') if '--method' in a else 'GET'
    if method in ('POST', 'PATCH'):
        body = json.loads(pathlib.Path(argument('--input')).read_text())
        with (root / 'calls').open('a') as stream: stream.write('request ' + json.dumps(body) + '\n')
        if method == 'POST':
            write('state', 'draft'); write('tag', body['tag_name']); write('assets', '')
        if body.get('draft') is False: write('state', 'published')
        if 'prerelease' in body: write('prerelease', str(body['prerelease']).lower())
        print(json.dumps(snapshot()))
    elif '/releases/tags/' in endpoint:
        if read('state', 'none') != 'published': fail('HTTP 404: Not Found')
        print(json.dumps(snapshot()))
    elif endpoint.endswith('/releases/41'):
        if os.environ.get('FAKE_GH_VIEW_ERROR') == '1': fail('HTTP 502: Bad Gateway')
        if read('state', 'none') == 'none': fail('HTTP 404: Not Found')
        print(json.dumps(snapshot()))
    else:
        if os.environ.get('FAKE_GH_API_ERROR') == '1' or os.environ.get('FAKE_GH_VIEW_ERROR') == '1': fail('HTTP 502: Bad Gateway')
        releases = []
        if read('state', 'none') != 'none': releases.append(snapshot())
        if (root / 'releases.json').exists():
            for index, page in enumerate(json.loads((root / 'releases.json').read_text())):
                for item in page:
                    item.setdefault('id', 100 + index)
                    releases.append(item)
        print(json.dumps(releases))
elif a[:2] == ['release', 'upload']:
    if os.environ.get('FAKE_GH_UPLOAD_FAIL') == '1': fail('upload failed')
    assets = read('assets').splitlines()
    for value in a[3:]:
        if value == '--clobber': continue
        path = pathlib.Path(value)
        shutil.copyfile(path, root / ('asset-' + path.name))
        if path.name not in assets: assets.append(path.name)
    write('assets', '\n'.join(assets))
elif a[:2] == ['release', 'download']:
    name = argument('--pattern')
    shutil.copyfile(root / ('asset-' + name), pathlib.Path(argument('--dir')) / name)
else: fail('unexpected fake gh command')
PY
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
echo notes > "$work/notes.md"
export APP_NAME=App ARCHIVES=dist/App.zip ARCHIVE_DIR=dist NOTES_FILE="$work/notes.md"
export GITHUB_REPOSITORY=test/app
"$release/assets.sh" >/dev/null

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
before="$(wc -l < "$FAKE_GH/calls")"
publish "$A" || { cat "$work/log"; fail "公开发行应该核验后跳过"; }
[ -z "$(output tag)" ] || fail "跳过公开发行不输出新发布标签"
if tail -n +"$((before + 1))" "$FAKE_GH/calls" | grep -qE 'release (create|edit|upload)|api --method (POST|PATCH)'; then
  fail "已公开发行不能修改 notes、latest 或附件"
fi
pass "锁内核验已公开发行后只读跳过"

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

# 5. 已公开但缺附件必须停止，不能重打已公开 ZIP。
grep -vxF App.zip "$FAKE_GH/assets" > "$work/assets" || true
mv "$work/assets" "$FAKE_GH/assets"
if plan; then fail "公开发行缺附件应失败"; fi
grep -q "新的补丁版本" "$work/log" || { cat "$work/log"; fail "缺附件应说明需新补丁版本"; }
before="$(wc -l < "$FAKE_GH/calls")"
if publish "$A"; then fail "锁内公开缺附件也应失败"; fi
if tail -n +"$((before + 1))" "$FAKE_GH/calls" | grep -qE 'release (create|edit|upload)|api --method (POST|PATCH)'; then fail "缺附件不能修改公开发行"; fi
[ "$(cat "$FAKE_GH/state")" = published ] || fail "不能把公开发行转草稿"
pass "公开缺附件失败并保留原发行"

# 6. overwrite 只允许草稿；公开发行不能覆盖。
echo App.zip >> "$FAKE_GH/assets"
: > "$out"
if OVERWRITE=true GITHUB_OUTPUT="$out" "$release/plan.sh" > "$work/log" 2>&1; then fail "不能 overwrite 公开发行"; fi
if OVERWRITE=true publish "$A"; then fail "发布层也应拒绝公开 overwrite"; fi
echo draft > "$FAKE_GH/state"
OVERWRITE=true GITHUB_OUTPUT="$out" "$release/plan.sh" > "$work/log" 2>&1
[ "$(output sha)" = "$A" ] || { cat "$work/log"; fail "overwrite 时用标签指向的提交"; }
pass "overwrite 明确拒绝公开发行，仅允许草稿"

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
if ! { grep -q '"prerelease": true' "$FAKE_GH/calls" && grep -q '"draft": false' "$FAKE_GH/calls" && [ "$(cat "$FAKE_GH/prerelease")" = true ]; }; then
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
  if plan; then fail "公开缺 $missing 应停止"; fi
  if publish "$A"; then fail "发布层不能补发公开缺 $missing"; fi
  echo "$missing" >> "$FAKE_GH/assets"
  pass "公开缺 ${missing} 不覆盖原附件"
done

# 13. 发布前查询失败也不能当成不存在，更不能创建 Release 或覆盖已有附件。
reset_gh
if FAKE_GH_VIEW_ERROR=1 publish "$A"; then
  cat "$work/log"; fail "发布时查不了 Release 应该失败"
fi
if grep -qE 'release (create|edit|upload)|api --method (POST|PATCH)' "$FAKE_GH/calls"; then
  cat "$FAKE_GH/calls"; fail "查询失败后不能修改 Release"
fi
[ -z "$(output tag)" ] || fail "查询失败时不输出发布成功"
pass "发布时查询失败不会创建或上传"

# 抽取后的实际发布入口也必须保留 PR #25 的 latest 决策。
reset_gh
printf '[[{"tag_name":"v2.0.0","draft":false,"prerelease":false}]]\n' > "$FAKE_GH/releases.json"
publish "$A" || { cat "$work/log"; fail "旧版补发"; }
grep -q '"make_latest": "false"' "$FAKE_GH/calls" || fail "旧版补发不能抢占 latest"
pass "实际发布脚本保留旧版不抢占 latest 的判断"
reset_gh
publish "$A" || { cat "$work/log"; fail "首次正式发布"; }
grep -q '"make_latest": "true"' "$FAKE_GH/calls" || fail "首个正式版应成为 latest"
pass "首个正式版标为 latest"
reset_gh
if FAKE_GH_API_ERROR=1 publish "$A"; then fail "分页查询失败应该阻止发布"; fi
if grep -qE 'release (create|edit|upload)|api --method (POST|PATCH)' "$FAKE_GH/calls"; then
  fail "latest 查询失败后不能修改 Release"
fi
pass "latest 分页查询失败阻止修改 Release"

echo "plan.sh、publish.sh 测试通过"
