#!/bin/bash
# 把签好名的 zip 提交苹果公证，通过后把公证票据钉（staple）到 .app 上，再重新打成同名的 zip。
# 钉上票据后，用户第一次打开时就算没联网，系统也能确认它经过了公证。
#   scripts/release/notarize.sh dist/Foo.zip dist/Foo-arm64.zip …
# 每个 zip 的最外层要有且只有一个 .app（ditto -c -k --keepParent Foo.app Foo.zip 打出来的就是）。
# 凭据二选一（发布流程从 GitHub Secrets 传进来，见 docs/release.md）：
#   App Store Connect API 密钥：NOTARY_KEY_P8（.p8 文件的内容，或者它的 base64）、NOTARY_KEY_ID、NOTARY_ISSUER_ID（个人密钥不填）
#   Apple ID：NOTARY_APPLE_ID、NOTARY_PASSWORD（App 专用密码）、NOTARY_TEAM_ID
# 可选：
#   NOTARY_TIMEOUT  最多等苹果处理多久，格式同 notarytool 的 --timeout（30m、1h），默认 45m（发布 job 最长 60 分钟）
#   SPCTL_TRIES、SPCTL_INTERVAL  钉上票据后系统检查最多试几次、隔几秒，默认 6 次、10 秒（自测时调小）
set -euo pipefail
# shellcheck source=scripts/release/notary-validation.sh
. "$(dirname "$0")/notary-validation.sh"
umask 077

[ $# -gt 0 ] || { echo "用法：notarize.sh 文件.zip …"; exit 1; }
tries="${SPCTL_TRIES:-6}"
interval="${SPCTL_INTERVAL:-10}"
[[ "$tries" =~ ^[1-9][0-9]*$ ]] || { echo "SPCTL_TRIES 必须是正整数"; exit 1; }
[[ "$interval" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "SPCTL_INTERVAL 必须是非负整数秒数"; exit 1; }
work="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/frit-notary"
rm -rf "$work" && mkdir -p "$work"
notary_keychain=""
archive_work=""
cleanup() {
  rm -f "$work/AuthKey.p8"
  if [ -n "$archive_work" ]; then rm -rf "$archive_work"; fi
  if [ -n "$notary_keychain" ]; then
    security delete-keychain "$notary_keychain" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

auth=()
if [ -n "${NOTARY_KEY_P8:-}" ]; then
  key="$work/AuthKey.p8"
  if printf '%s' "$NOTARY_KEY_P8" | grep -q "BEGIN PRIVATE KEY"; then
    printf '%s\n' "$NOTARY_KEY_P8" > "$key"
  else
    printf '%s' "$NOTARY_KEY_P8" | tr -d ' \r\n\t' | base64 --decode > "$key"
  fi
  auth=(--key "$key" --key-id "${NOTARY_KEY_ID:?没有设置 NOTARY_KEY_ID}")
  if [ -n "${NOTARY_ISSUER_ID:-}" ]; then
    auth+=(--issuer "$NOTARY_ISSUER_ID")
  fi
elif [ -n "${NOTARY_APPLE_ID:-}" ]; then
  : "${NOTARY_PASSWORD:?没有设置 NOTARY_PASSWORD（App 专用密码）}"
  : "${NOTARY_TEAM_ID:?没有设置 NOTARY_TEAM_ID}"
  notary_keychain="$work/notary.keychain-db"
  keychain_password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  security create-keychain -p "$keychain_password" "$notary_keychain"
  security unlock-keychain -p "$keychain_password" "$notary_keychain"
  unset keychain_password
  # 省略 --password 让 notarytool 从标准输入读取；后续命令只携带临时钥匙串 profile。
  printf '%s\n' "$NOTARY_PASSWORD" | xcrun notarytool store-credentials frit-notary \
    --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --keychain "$notary_keychain"
  auth=(--keychain-profile frit-notary --keychain "$notary_keychain")
else
  echo "没有公证凭据：设置 NOTARY_KEY_P8 + NOTARY_KEY_ID（+ NOTARY_ISSUER_ID），或者 NOTARY_APPLE_ID + NOTARY_PASSWORD + NOTARY_TEAM_ID"
  exit 1
fi

# notarytool --output-format json 的输出里取一个字段。
json_field() {
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2" 2>/dev/null || true
}

# 先把所有包都传上去（苹果那边同时处理），再逐个等结果。
ids=()
for zip in "$@"; do
  [ -f "$zip" ] || { echo "找不到 $zip"; exit 1; }
  name="$(basename "$zip")"
  out="$work/submit-$name.json"
  echo "上传 $name 提交公证"
  if ! xcrun notarytool submit "$zip" "${auth[@]}" --output-format json > "$out"; then
    cat "$out" || true
    echo "提交失败：$name"
    exit 1
  fi
  id="$(json_field "$out" id)"
  [ -n "$id" ] || { cat "$out"; echo "没拿到提交编号：$name"; exit 1; }
  echo "  提交编号 $id"
  ids+=("$id")
done

i=0
for zip in "$@"; do
  id="${ids[$i]}"
  i=$((i + 1))
  name="$(basename "$zip")"
  out="$work/wait-$name.json"
  timeout="${NOTARY_TIMEOUT:-45m}"
  wait_result=0
  xcrun notarytool wait "$id" "${auth[@]}" --timeout "$timeout" --output-format json > "$out" || wait_result=$?
  status="$(json_field "$out" status)"
  echo "${name}：公证结果 ${status:-未知}"
  if [ "$wait_result" != 0 ] || [ "$status" != "Accepted" ]; then
    cat "$out" || true
    if [ "$wait_result" != 0 ]; then
      echo "等待公证失败（退出状态 ${wait_result}），这次不发布"
    fi
    if [ -z "$status" ] || [ "$status" = "In Progress" ]; then
      echo "等了 ${timeout} 苹果还没处理完（或者没拿到结果），这次不发布。可以稍后重新运行，或者用 xcrun notarytool info ${id} 查进度"
    fi
    echo "===== 公证日志（为什么没通过） ====="
    xcrun notarytool log "$id" "${auth[@]}" || true
    exit 1
  fi
  # 解压、钉票据、确认系统认可，再压回原来的文件。
  dir="$work/staple-${name%.zip}"
  rm -rf "$dir" && mkdir -p "$dir"
  ditto -x -k "$zip" "$dir"
  apps="$(find "$dir" -maxdepth 1 -name '*.app' -type d)"
  count="$(printf '%s\n' "$apps" | grep -c . || true)"
  [ "$count" = "1" ] || { echo "${name} 的最外层应该有且只有一个 .app（找到 ${count} 个）"; exit 1; }
  app="$apps"
  app_name="$(basename "$app")"
  stapler_with_retry staple "$app"
  if ! verify_notarized_app "$app" "$work/check-before-$i"; then
    xcrun notarytool log "$id" "${auth[@]}" || true
    exit 1
  fi
  target="$(cd "$(dirname "$zip")" && pwd)/$name"
  # 同文件系统暂存，最终 ZIP 验收完成前不删除或覆盖原归档。
  archive_work="$(mktemp -d "$(dirname "$target")/.frit-notarized.XXXXXX")"
  pending="$archive_work/$name"
  (cd "$dir" && ditto -c -k --keepParent "$app_name" "$pending")
  final="$work/final-$i"
  mkdir -p "$final"
  ditto -x -k "$pending" "$final"
  verify_notarized_app "$final/$app_name" "$work/check-final-$i"
  mv -f "$pending" "$target"
  rm -rf "$archive_work"
  archive_work=""
  echo "${name}：已钉上公证票据"
done
