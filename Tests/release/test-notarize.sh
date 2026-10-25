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
      "stapler staple"|"stapler validate")
        action="$2"
        count_file="${FAKE_NOTARY_CALLS}.${action}"
        n="$(cat "$count_file" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$count_file"
        [ "${FAKE_STAPLER_EXIT:-0}" = 0 ] || exit "$FAKE_STAPLER_EXIT"
        if [ "$n" -le "${FAKE_STAPLER_NETWORK_FAILURES:-0}" ]; then exit 68; fi
        echo "测试票据通过" ;;
      *) echo "未预期的 xcrun 调用" >&2; exit 99 ;;
    esac
    ;;
  spctl)
    if [ "$1" = --status ]; then
      printf '%s\n' "${FAKE_POLICY:-assessments enabled}"
      exit "${FAKE_POLICY_EXIT:-0}"
    fi
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
    printf 'accepted\nsource=%s\n' "${FAKE_SOURCE:-Notarized Developer ID}"
    ;;
  codesign)
    if [ "$1" = --verify ]; then exit "$FAKE_SIGNATURE_EXIT"; fi
    printf 'Authority=%s\n' "${FAKE_AUTHORITY:-Developer ID Application: Fixture (TESTONLY00)}"
    if [[ "$*" = *'--arch arm64'* ]]; then printf 'CDHash=%040d\n' 2; else printf 'CDHash=%040d\n' 1; fi
    ;;
  ditto)
    if [ "$1" = -x ]; then
      mkdir -p "$4/Sample.app/Contents/MacOS"
      python3 - "$4/Sample.app" "$3" <<'PYMOCK'
import os,plistlib,sys
from pathlib import Path
app=Path(sys.argv[1]); (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Sample'}))
(app/'Contents/MacOS/Sample').write_bytes(b'fixture')
ticket=b''
if os.environ.get('FAKE_MISSING_ARCH') != 'x86_64': ticket+=bytes.fromhex('0'*39+'1')
if os.environ.get('FAKE_MISSING_ARCH') != 'arm64' and not (os.environ.get('FAKE_FINAL_BROKEN') == '1' and Path(sys.argv[2]).read_text() == 'repacked\n'):
 ticket+=bytes.fromhex('0'*39+'2')
(app/'Contents/CodeResources').write_bytes(ticket)
PYMOCK
    elif [ "$1" = -c ]; then
      for target in "$@"; do :; done
      printf 'repacked\n' > "$target"
      [ "${FAKE_PACK_EXIT:-0}" = 0 ] || exit "$FAKE_PACK_EXIT"
    else
      exit 99
    fi
    ;;
  lipo) echo 'x86_64 arm64' ;;
  security|sleep|syspolicy_check) ;;
  *) exit 99 ;;
esac
SH
chmod +x "$fake/command"
for tool in xcrun spctl codesign ditto sleep syspolicy_check security lipo; do
  ln -s command "$fake/$tool"
done

prepare() {
  rm -f "$work/calls" "$work/calls.count" "$work/calls.staple" "$work/calls.validate"
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
[ "$(cat "$work/calls.count")" = 2 ] || fail "首次通过后不能重试"
[ "$(cat "$work/Sample.zip")" = repacked ] || fail "通过后没有重新打包"
pass "首次通过后重打包"

prepare
notarize FAKE_ASSESS_MODE=flaky || fail "重试后通过"
[ "$(cat "$work/calls.count")" = 4 ] || fail "应该在第三次通过"
[ "$(grep -c '^sleep ' "$work/calls")" = 2 ] || fail "只应在两次检查之间等待"
pass "两次失败后第三次通过"

prepare
if notarize FAKE_ASSESS_MODE=rejected; then fail "签名拒绝不能通过"; fi
[ "$(cat "$work/calls.count")" = 3 ] || fail "拒绝后仅限三次检查"
[ "$(grep -c '^sleep ' "$work/calls")" = 2 ] || fail "最后一次失败后不能继续等待"
grep -q 'source=no usable signature' "$work/log" || fail "缺少完整拒绝原因"
grep -q '测试公证日志' "$work/log" || fail "缺少苹果诊断日志"
unchanged
pass "系统检查一直拒绝时诊断并保留原归档"

# 未公证来源不再以本机缓存例外放行；原归档必须保留。
prepare
if notarize FAKE_ASSESS_MODE=unnotarized; then fail "未公证来源不能通过"; fi
unchanged
pass "拒绝未公证来源"

for setting in FAKE_SIGNATURE_EXIT=1 FAKE_MISSING_ARCH=arm64 FAKE_MISSING_ARCH=x86_64 FAKE_FINAL_BROKEN=1 FAKE_PACK_EXIT=1 FAKE_STAPLER_EXIT=65 FAKE_POLICY_EXIT=1 \
  FAKE_POLICY=disabled FAKE_SOURCE=Unknown 'FAKE_POLICY=assessments enabled (override)' \
  'FAKE_SOURCE=Notarized Developer ID (override)' 'FAKE_AUTHORITY=Apple Development: Fixture'; do
  prepare
  if notarize "$setting"; then fail "不完整验收不得通过：$setting"; fi
  unchanged
  pass "拒绝并保留原归档：$setting"
done

prepare
notarize FAKE_STAPLER_NETWORK_FAILURES=1 || fail "票据临时网络错误应限次重试"
[ "$(cat "$work/calls.staple")" = 2 ] || fail "staple重试次数"
[ "$(cat "$work/calls.validate")" = 3 ] || fail "validate含最终ZIP核验与一次重试"
pass "票据网络错误有限重试后执行最终ZIP核验"

prepare
if notarize FAKE_STAPLER_NETWORK_FAILURES=99; then fail "票据网络错误耗尽后必须失败"; fi
[ "$(cat "$work/calls.staple")" = 3 ] || fail "票据网络重试必须有上限"
unchanged
pass "票据重试耗尽保留原归档"

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
