#!/bin/bash
# 发布脚本在 macOS 上的自测（Frit 的 CI 里跑）：
#   1. 用临时的自签名证书走一遍导入钥匙串、由内向外签名、hardened runtime、安全时间戳；
#   2. 精简包：两种芯片各一个，里面的程序只剩一种芯片，签名有效；
#   3. 公证脚本：用假的 xcrun 走一遍通过、没通过、等超时、没有凭据，以及钉票据后系统检查的重试和兜底；
#   4. 假发布：latest.json 能访问，下载的包校验和对得上，里面是 9.9.9。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
release="$(cd "$here/../../scripts/release" && pwd)"
work="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/frit-selftest"
rm -rf "$work" && mkdir -p "$work"
export FRIT_RELEASE="$release"

step() { printf '\n===== %s =====\n' "$1"; }

step "1. 证书签名"
cat > "$work/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Frit CI Test
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$work/openssl.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/cert.p12" -passout pass:ci-test
: > "$work/env"
CERTIFICATE_P12_BASE64="$(base64 -i "$work/cert.p12")" CERTIFICATE_PASSWORD=ci-test GITHUB_ENV="$work/env" \
  "$release/import-certificate.sh"
grep -q '^CODESIGN_NAME=Frit CI Test$' "$work/env" || { echo "缺少证书名称"; exit 1; }
identity="$(awk -F= '/^CODESIGN_IDENTITY=/{print $2}' "$work/env")"
keychain="$(awk -F= '/^CODESIGN_KEYCHAIN=/{print $2}' "$work/env")"
if [ -z "$identity" ] || [ -z "$keychain" ]; then
  echo "导入脚本没有给出签名身份和钥匙串"
  exit 1
fi
trap 'security delete-keychain "$keychain" 2>/dev/null || true' EXIT
export CODESIGN_IDENTITY="$identity" CODESIGN_KEYCHAIN="$keychain"

VERSION=1.2.3 "$here/make-sample-app.sh" "$work/dist"
app="$work/dist/Sample.app"
for code in "$app" "$app/Contents/MacOS/sample-helper"; do
  info="$(codesign -dvv "$code" 2>&1)"
  echo "$info" | grep -q "Authority=Frit CI Test" || { echo "$info"; echo "$code 不是用证书签的"; exit 1; }
  echo "$info" | grep -q "flags=.*runtime" || { echo "$info"; echo "$code 没有开 hardened runtime"; exit 1; }
  echo "$info" | grep -q "^Timestamp=" || { echo "$info"; echo "$code 没有安全时间戳"; exit 1; }
done
codesign -d --entitlements - "$app" 2>/dev/null | grep -q "automation.apple-events" || { echo "App 的权限声明没有签进去"; exit 1; }
if codesign -d --entitlements - "$app/Contents/MacOS/sample-helper" 2>/dev/null | grep -q "automation.apple-events"; then
  echo "辅助程序不该带 App 的权限声明"; exit 1
fi
"$app/Contents/MacOS/Sample" --exit | grep -q "Sample 1.2.3 已启动" || { echo "用证书签名的程序没有正常运行"; exit 1; }
echo "证书签名通过"

step "2. 精简包"
# 用相对路径调用，和发布流程里一样。
(cd "$work" && "$release/thin-archives.sh" dist/Sample.app dist/Sample dist/Sample.entitlements)
for arch in arm64 x86_64; do
  zip="$work/dist/Sample-$arch.zip"
  [ -f "$zip" ] || { echo "没有生成 $zip"; exit 1; }
  rm -rf "$work/thin" && mkdir -p "$work/thin"
  ditto -x -k "$zip" "$work/thin"
  for bin in Sample sample-helper; do
    archs="$(lipo -archs "$work/thin/Sample.app/Contents/MacOS/$bin")"
    [ "$archs" = "$arch" ] || { echo "$zip 里的 $bin 是 ${archs}，应该只有 ${arch}"; exit 1; }
  done
  codesign --verify --deep --strict "$work/thin/Sample.app"
  codesign -dvv "$work/thin/Sample.app" 2>&1 | grep -q "Authority=Frit CI Test" || { echo "$zip 没有用证书重新签名"; exit 1; }
  codesign -d --entitlements - "$work/thin/Sample.app" 2>/dev/null | grep -q "automation.apple-events" || { echo "$zip 的权限声明丢了"; exit 1; }
done
[ ! -e "$work/dist/Sample-thin-arm64" ] || { echo "临时文件夹没有清理"; exit 1; }
echo "精简包通过"

step "3. 公证脚本"
(cd "$work/dist" && ditto -c -k --keepParent Sample.app Sample.zip)
fake="$work/fakebin"
mkdir -p "$fake"
cat > "$fake/xcrun" <<'SH'
#!/bin/bash
case "$1 $2" in
  "notarytool submit") echo '{"id":"00000000-0000-4000-8000-000000000000","message":"Successfully uploaded file"}' ;;
  "notarytool wait") echo "{\"id\":\"$3\",\"status\":\"${FAKE_NOTARY_STATUS:-Accepted}\",\"message\":\"Processing complete\"}"; exit "${FAKE_NOTARY_WAIT_EXIT:-0}" ;;
  "notarytool log") echo '{"issues":[{"message":"fake notary issue"}]}' ;;
  "stapler staple"|"stapler validate") echo "The $2 action worked!" ;;
  *) echo "fake xcrun: unexpected $*" >&2; exit 1 ;;
esac
SH
# 假的 spctl：FAKE_SPCTL=accept（默认）、flaky（前 FAKE_SPCTL_FAILS 次说没公证，之后通过）、
# unnotarized（一直说没公证）、rejected（签名有问题）。调用次数记在 $FAKE_SPCTL_COUNT。
cat > "$fake/spctl" <<'SH'
#!/bin/bash
count_file="${FAKE_SPCTL_COUNT:-/dev/null}"
n="$(cat "$count_file" 2>/dev/null || echo 0)"
n=$((n + 1))
[ "$count_file" = /dev/null ] || echo "$n" > "$count_file"
for app in "$@"; do :; done
case "${FAKE_SPCTL:-accept}" in
  flaky) [ "$n" -gt "${FAKE_SPCTL_FAILS:-2}" ] || { printf '%s: rejected\nsource=Unnotarized Developer ID\n' "$app" >&2; exit 3; } ;;
  unnotarized) printf '%s: rejected\nsource=Unnotarized Developer ID\n' "$app" >&2; exit 3 ;;
  rejected) printf '%s: rejected\nsource=no usable signature\n' "$app" >&2; exit 3 ;;
esac
echo "$app: accepted"
SH
chmod +x "$fake/xcrun" "$fake/spctl"
cp "$work/dist/Sample.zip" "$work/test.zip"
PATH="$fake:$PATH" NOTARY_APPLE_ID=ci@example.com NOTARY_PASSWORD=x NOTARY_TEAM_ID=ABCDE12345 "$release/notarize.sh" "$work/test.zip"
rm -rf "$work/unzipped" && ditto -x -k "$work/test.zip" "$work/unzipped"
codesign --verify --deep --strict "$work/unzipped/Sample.app"
printf -- '-----BEGIN PRIVATE KEY-----\nMIGT\n-----END PRIVATE KEY-----\n' > "$work/key.p8"
PATH="$fake:$PATH" NOTARY_KEY_P8="$(cat "$work/key.p8")" NOTARY_KEY_ID=ABC123 "$release/notarize.sh" "$work/test.zip" >/dev/null
if PATH="$fake:$PATH" FAKE_NOTARY_STATUS=Invalid NOTARY_APPLE_ID=ci@example.com NOTARY_PASSWORD=x NOTARY_TEAM_ID=ABCDE12345 \
    "$release/notarize.sh" "$work/test.zip" > "$work/invalid.log" 2>&1; then
  cat "$work/invalid.log"; echo "公证没通过时脚本应该失败"; exit 1
fi
grep -q "fake notary issue" "$work/invalid.log" || { cat "$work/invalid.log"; echo "公证没通过时没有打印苹果的日志"; exit 1; }
notarize() { PATH="$fake:$PATH" NOTARY_APPLE_ID=ci@example.com NOTARY_PASSWORD=x NOTARY_TEAM_ID=ABCDE12345 SPCTL_TRIES=3 SPCTL_INTERVAL=0 "$release/notarize.sh" "$work/test.zip"; }
if FAKE_NOTARY_STATUS="In Progress" FAKE_NOTARY_WAIT_EXIT=75 notarize > "$work/timeout.log" 2>&1; then
  cat "$work/timeout.log"; echo "等公证超时时脚本应该失败"; exit 1
fi
grep -q "还没处理完" "$work/timeout.log" || { cat "$work/timeout.log"; echo "等公证超时时应该说明"; exit 1; }
if FAKE_NOTARY_WAIT_EXIT=1 notarize > "$work/wait-error.log" 2>&1; then
  cat "$work/wait-error.log"; echo "wait 报错时不能因为 JSON 里写着 Accepted 就继续"; exit 1
fi
grep -q "等待公证失败" "$work/wait-error.log" || { cat "$work/wait-error.log"; echo "没有说明 wait 失败"; exit 1; }
echo 0 > "$work/spctl-count"
FAKE_SPCTL=flaky FAKE_SPCTL_COUNT="$work/spctl-count" notarize > "$work/flaky.log" 2>&1 || { cat "$work/flaky.log"; echo "系统检查前两次没通过、第三次通过时应该成功"; exit 1; }
[ "$(cat "$work/spctl-count")" = 3 ] || { cat "$work/flaky.log"; echo "系统检查应该试了 3 次"; exit 1; }
FAKE_SPCTL=unnotarized notarize > "$work/unnotarized.log" 2>&1 || { cat "$work/unnotarized.log"; echo "已公证、只有系统检查说没公证时应该照常发布"; exit 1; }
grep -q "::warning::" "$work/unnotarized.log" || { cat "$work/unnotarized.log"; echo "这种情况要记一条警告"; exit 1; }
if FAKE_SPCTL=rejected notarize > "$work/rejected.log" 2>&1; then
  cat "$work/rejected.log"; echo "系统检查因为签名问题没通过时应该失败"; exit 1
fi
if "$release/notarize.sh" "$work/test.zip" > "$work/nocreds.log" 2>&1; then
  cat "$work/nocreds.log"; echo "没有公证凭据时脚本应该失败"; exit 1
fi
# 公证脚本用到的命令和参数，这个 Xcode 里都有。
for command in submit wait; do
  help="$(xcrun notarytool "$command" --help 2>&1)"
  for option in --key --key-id --issuer --apple-id --password --team-id --output-format; do
    echo "$help" | grep -qE -- "${option}( |,|\$)" || { echo "$help"; echo "notarytool ${command} 没有 ${option} 参数"; exit 1; }
  done
done
xcrun notarytool wait --help 2>&1 | grep -qE -- "--timeout( |,|\$)" || { echo "notarytool wait 没有 --timeout 参数"; exit 1; }
xcrun notarytool log --help >/dev/null
xcrun --find stapler >/dev/null
echo "公证脚本通过"

step "4. 假发布"
: > "$work/fake-env"
GITHUB_ENV="$work/fake-env" FAKE_DIR="$work/feed" FAKE_PORT=8799 "$release/fake-release.sh" "$app" Sample.zip Sample-arm64.zip
url="$(awk -F= '/^FAKE_RELEASE_URL=/{print $2}' "$work/fake-env")"
pid="$(awk -F= '/^FAKE_RELEASE_PID=/{print $2}' "$work/fake-env")"
curl -sSf "$url" > "$work/latest.json"
python3 - "$work/latest.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["tag_name"] == "v9.9.9", data["tag_name"]
names = [asset["name"] for asset in data["assets"]]
assert names == ["Sample.zip", "Sample-arm64.zip", "SHA256SUMS.txt"], names
PY
curl -sSf -o "$work/downloaded.zip" "http://127.0.0.1:8799/Sample-arm64.zip"
curl -sSf -o "$work/SHA256SUMS.txt" "http://127.0.0.1:8799/SHA256SUMS.txt"
expected="$(awk '$2 == "Sample-arm64.zip" {print $1}' "$work/SHA256SUMS.txt")"
actual="$(shasum -a 256 "$work/downloaded.zip" | awk '{print $1}')"
[ "$expected" = "$actual" ] || { echo "校验和对不上：$expected / $actual"; exit 1; }
rm -rf "$work/fake-unzipped" && ditto -x -k "$work/downloaded.zip" "$work/fake-unzipped"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$work/fake-unzipped/Sample.app/Contents/Info.plist")" = "9.9.9" ] \
  || { echo "假发布里的版本不是 9.9.9"; exit 1; }
codesign --verify --deep --strict "$work/fake-unzipped/Sample.app"
curl -sSf "http://127.0.0.1:8799/releases.json" | python3 -c 'import json,sys; assert json.load(sys.stdin)[0]["tag_name"] == "v9.9.9"'
kill "$pid"
echo "假发布通过"

printf '\n发布脚本自测全部通过\n'
