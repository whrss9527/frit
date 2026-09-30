#!/bin/bash
# 更新端到端测试用的「假发布」：把打包好的 .app 改成一个更高的版本号，打包、算校验和，
# 再生成一份和 GitHub releases 接口格式相同的 latest.json，用本地 HTTP 服务器提供出来。
# App 把检查更新的地址指到这里（比如 STOX_UPDATE_URL=http://127.0.0.1:8765/latest.json），
# 就能在 CI 里真正走一遍发现新版本、下载、校验、替换、重新启动。
#
#   scripts/release/fake-release.sh dist/Foo.app Foo.zip [另一个名字.zip …]
#
# 同一个包可以用几个名字各放一份（比如通用包和 -arm64 精简包），latest.json 里都会列出来。
# 环境变量：
#   FAKE_VERSION  假版本号，默认 9.9.9
#   FAKE_PORT     端口，默认 8765
#   FAKE_DIR      放文件的目录，默认 $RUNNER_TEMP/fake-release
# 输出：服务器起来后打印 latest.json 的地址；在 GitHub Actions 里同时写进 $GITHUB_ENV 的 FAKE_RELEASE_URL，
# 服务器进程号写进 FAKE_RELEASE_PID（测完 kill 掉即可）。
set -euo pipefail

[ $# -ge 2 ] || { echo "用法：fake-release.sh 程序.app 包名.zip [包名.zip …]"; exit 1; }
app="$1"
shift
[ -d "$app" ] || { echo "找不到 $app"; exit 1; }
version="${FAKE_VERSION:-9.9.9}"
port="${FAKE_PORT:-8765}"
dir="${FAKE_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fake-release}"
base="http://127.0.0.1:${port}"
app_name="$(basename "$app")"

rm -rf "$dir" && mkdir -p "$dir/stage"
ditto "$app" "$dir/stage/$app_name"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$dir/stage/$app_name/Contents/Info.plist"
# 改了 Info.plist 签名就失效了，重新 ad-hoc 签名（假发布只用来测流程，不测证书）。
codesign --force --deep --sign - "$dir/stage/$app_name"

first="$1"
(cd "$dir/stage" && ditto -c -k --keepParent "$app_name" "../$first")
for name in "$@"; do
  [ "$name" = "$first" ] || cp "$dir/$first" "$dir/$name"
done
rm -rf "$dir/stage"
(cd "$dir" && shasum -a 256 "$@" > SHA256SUMS.txt)

assets=""
for name in "$@" SHA256SUMS.txt; do
  size="$(stat -f %z "$dir/$name")"
  [ -z "$assets" ] || assets="${assets},"
  assets="${assets}{\"name\":\"${name}\",\"size\":${size},\"browser_download_url\":\"${base}/${name}\"}"
done
cat > "$dir/latest.json" <<JSON
{"tag_name":"v${version}","name":"v${version}","prerelease":false,"draft":false,
 "html_url":"${base}/latest.json","published_at":"2026-01-01T00:00:00Z",
 "body":"## ${version}\n\n- 这是 CI 里用来测试一键更新的假版本。\n- 下载、校验、替换、重新启动都会走一遍。",
 "assets":[${assets}]}
JSON
# 有的 App 读「全部发布」的列表（比如要看测试版），同样的内容再放一份数组。
printf '[%s]\n' "$(cat "$dir/latest.json")" > "$dir/releases.json"

(cd "$dir" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
pid=$!
# 服务器起来要一会儿（runner 忙的时候会超过一秒），能访问了再返回。
for _ in $(seq 1 30); do
  curl -sf -o /dev/null "${base}/latest.json" && break
  sleep 0.5
done
curl -sSf -o /dev/null "${base}/latest.json" || { kill "$pid" 2>/dev/null || true; echo "本地的假发布服务器没有起来"; exit 1; }

echo "假发布 ${version}：${base}/latest.json（服务器进程 ${pid}）"
cat "$dir/SHA256SUMS.txt"
if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "FAKE_RELEASE_URL=${base}/latest.json"
    echo "FAKE_RELEASE_PID=${pid}"
  } >> "$GITHUB_ENV"
fi
