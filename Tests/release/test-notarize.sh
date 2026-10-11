#!/bin/bash
# 公证流程的跨平台回归：用替身命令验证失败传播、重试和重打包边界。
# 真正的签名、公证工具参数与 App 打包仍由 test-scripts.sh 在 macOS 上验证。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
release="$here/../../scripts/release"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fake="$work/bin"
mkdir -p "$fake" "$work/runner"

fail() { cat "$work/log" >&2; echo "失败：$*" >&2; exit 1; }
pass() { echo "通过：$*"; }

cat > "$fake/command" <<'SH'
#!/bin/bash
set -euo pipefail
tool="$(basename "$0")"
if [ "$tool" = security ]; then
  printf '%s\n' "$tool $1" >> "$FAKE_NOTARY_CALLS"
else
  printf '%s\n' "$tool $*" >> "$FAKE_NOTARY_CALLS"
fi
case "$tool" in
  xcrun)
    case "$1 $2" in
      "notarytool store-credentials")
        IFS= read -r password
        [ "$password" = test-only ] || exit 99
        ;;
      "notarytool submit") printf '{"id":"test-submission"}\n' ;;
      "notarytool wait")
        timeout=""
        for argument in "$@"; do
          if [ "$timeout" = next ]; then timeout="$argument"; break; fi
          [ "$argument" != --timeout ] || timeout=next
        done
        [ "$timeout" = "$FAKE_EXPECT_TIMEOUT" ] || { echo "缺少正确的 --timeout" >&2; exit 99; }
        printf '{"status":"%s"}\n' "$FAKE_NOTARY_STATUS"
        exit "$FAKE_WAIT_EXIT"
        ;;
      "notarytool log") printf '{"issues":[{"message":"测试公证日志"}]}\n' ;;
      "stapler staple"|"stapler validate") echo "测试票据通过" ;;
      *) echo "未预期的 xcrun 调用" >&2; exit 99 ;;
    esac
    ;;
  spctl)
    count_file="${FAKE_NOTARY_CALLS}.count"
    n="$(cat "$count_file" 2>/dev/null || echo 0)"
    n=$((n + 1))
    echo "$n" > "$count_file"
    case "$FAKE_ASSESS_MODE" in
      flaky) [ "$n" -gt 2 ] || { echo "source=Unnotarized Developer ID" >&2; exit 3; } ;;
      unnotarized) echo "source=Unnotarized Developer ID" >&2; exit 3 ;;
      rejected) echo "source=no usable signature" >&2; exit 3 ;;
      accept) ;;
      *) exit 99 ;;
    esac
    echo "测试系统检查通过"
    ;;
  codesign)
    if [ "$1" = --verify ]; then exit "$FAKE_SIGNATURE_EXIT"; fi
    echo "测试签名诊断"
    ;;
  ditto)
    if [ "$1" = -x ]; then
      mkdir -p "$4/Sample.app"
    elif [ "$1" = -c ]; then
      for target in "$@"; do :; done
      printf 'repacked\n' > "$target"
    else
      exit 99
    fi
    ;;
  security|sleep|syspolicy_check) ;;
  *) exit 99 ;;
esac
SH
chmod +x "$fake/command"
for tool in xcrun spctl codesign ditto sleep syspolicy_check security; do
  ln -s command "$fake/$tool"
done

prepare() {
  rm -f "$work/calls" "$work/calls.count"
  printf 'original\n' > "$work/Sample.zip"
  cp "$work/Sample.zip" "$work/original.zip"
}

notarize() {
  env PATH="$fake:$PATH" RUNNER_TEMP="$work/runner" \
    NOTARY_KEY_P8='' NOTARY_KEY_ID='' NOTARY_ISSUER_ID='' \
    NOTARY_APPLE_ID=test@example.invalid NOTARY_PASSWORD=test-only NOTARY_TEAM_ID=TESTONLY \
    SPCTL_TRIES=3 SPCTL_INTERVAL=0 NOTARY_TIMEOUT=45m \
    FAKE_NOTARY_CALLS="$work/calls" FAKE_EXPECT_TIMEOUT=45m \
    FAKE_NOTARY_STATUS=Accepted FAKE_WAIT_EXIT=0 FAKE_ASSESS_MODE=accept FAKE_SIGNATURE_EXIT=0 \
    "$@" "$release/notarize.sh" "$work/Sample.zip" > "$work/log" 2>&1
}

unchanged() { cmp -s "$work/Sample.zip" "$work/original.zip" || fail "失败时不能覆盖原归档"; }

prepare
notarize || fail "首次系统检查通过"
[ "$(cat "$work/calls.count")" = 1 ] || fail "首次通过后不能重试"
[ "$(cat "$work/Sample.zip")" = repacked ] || fail "通过后没有重新打包"
pass "首次通过后重打包"

prepare
notarize FAKE_ASSESS_MODE=flaky || fail "重试后通过"
[ "$(cat "$work/calls.count")" = 3 ] || fail "应该在第三次通过"
[ "$(grep -c '^sleep ' "$work/calls")" = 2 ] || fail "只应在两次检查之间等待"
pass "两次失败后第三次通过"

prepare
if notarize FAKE_ASSESS_MODE=rejected; then fail "签名拒绝不能通过"; fi
[ "$(cat "$work/calls.count")" = 4 ] || fail "应有三次重试检查和一次详细诊断"
[ "$(grep -c '^sleep ' "$work/calls")" = 2 ] || fail "最后一次失败后不能继续等待"
grep -q 'source=no usable signature' "$work/log" || fail "缺少完整拒绝原因"
grep -q '测试公证日志' "$work/log" || fail "缺少苹果诊断日志"
unchanged
pass "系统检查一直拒绝时诊断并保留原归档"

# Proxi 兼容规则：只在 Accepted、票据通过且签名完整时允许系统缓存延迟，必须明确警告。
prepare
notarize FAKE_ASSESS_MODE=unnotarized || fail "符合约束的缓存延迟应记录警告"
grep -q '::warning::' "$work/log" || fail "缓存延迟没有警告"
grep -q '^codesign --verify --deep --strict ' "$work/calls" || fail "没有核对签名"
pass "缓存延迟仍需签名与票据核对"

prepare
if notarize FAKE_ASSESS_MODE=unnotarized FAKE_SIGNATURE_EXIT=1; then fail "无效签名不能使用缓存延迟兜底"; fi
unchanged
pass "缓存延迟不能掩盖无效签名"

prepare
if notarize FAKE_NOTARY_STATUS='In Progress' FAKE_WAIT_EXIT=75; then fail "等待超时必须失败"; fi
grep -q '还没处理完' "$work/log" || fail "超时没有明确原因"
if grep -q '^ditto ' "$work/calls"; then fail "超时后不能解压或重打包"; fi
unchanged
pass "等待超时后停止"

prepare
if notarize FAKE_WAIT_EXIT=1; then fail "Accepted JSON 不能掩盖 wait 命令失败"; fi
grep -q '等待公证失败' "$work/log" || fail "没有报告命令失败"
unchanged
pass "Accepted JSON 不能掩盖非零退出状态"

prepare
if notarize FAKE_NOTARY_STATUS=Invalid; then fail "公证被拒绝必须失败"; fi
grep -q '测试公证日志' "$work/log" || fail "公证拒绝时没有诊断日志"
unchanged
pass "公证拒绝时停止并打印日志"

prepare
notarize NOTARY_TIMEOUT=2m FAKE_EXPECT_TIMEOUT=2m || fail "自定义超时没有传给 notarytool"
pass "传递自定义超时"

for setting in SPCTL_TRIES=0 SPCTL_INTERVAL=-1; do
  prepare
  if notarize "$setting"; then fail "无效重试参数必须失败"; fi
  [ ! -f "$work/calls" ] || fail "参数无效时不能提交公证"
  unchanged
  pass "拒绝 $setting"
done

echo "公证超时与重试逻辑测试通过"
