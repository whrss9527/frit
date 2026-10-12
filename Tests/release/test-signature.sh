#!/bin/bash
# 签名检查的跨平台回归；codesign 与 ditto 用替身，版本使用真正的 plist 文件。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../../scripts/release/check-signature.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/runner"
cat > "$work/bin/ditto" <<'SH'
#!/bin/bash
mkdir -p "$4/Sample.app/Contents"
python3 - "$4/Sample.app/Contents/Info.plist" <<'PY'
import os, plistlib, sys
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump({'CFBundleShortVersionString': os.environ['FRIT_TEST_VERSION']}, stream)
PY
SH
cat > "$work/bin/codesign" <<'SH'
#!/bin/bash
if [ "$1" = --verify ]; then exit "$FRIT_TEST_SIGNATURE_EXIT"; fi
printf 'Authority=Test\nTeamIdentifier=%s\n' "$FRIT_TEST_TEAM" >&2
if [ "$FRIT_TEST_RUNTIME" = 1 ]; then echo 'flags=runtime' >&2; fi
if [ "$FRIT_TEST_TIMESTAMP" = 1 ]; then echo 'Timestamp=test' >&2; fi
SH
chmod +x "$work/bin/ditto" "$work/bin/codesign"
check() {
  env PATH="$work/bin:$PATH" RUNNER_TEMP="$work/runner" ARCHIVES="$work/Sample.zip" VERSION=1.2.3 \
    TEAM_ID=ABCDE12345 CODESIGN_IDENTITY=test FRIT_TEST_VERSION=1.2.3 FRIT_TEST_TEAM=ABCDE12345 \
    FRIT_TEST_SIGNATURE_EXIT=0 FRIT_TEST_RUNTIME=1 FRIT_TEST_TIMESTAMP=1 \
    "$@" "$script" > "$work/log" 2>&1
}
fail() { cat "$work/log" >&2; echo "失败：$*" >&2; exit 1; }
check || fail "正确团队和签名应该通过"
echo "通过：正确团队和签名"
for mismatch in FRIT_TEST_TEAM=ZZZZZ99999 FRIT_TEST_TEAM=unknown TEAM_ID=bad \
  FRIT_TEST_SIGNATURE_EXIT=1 FRIT_TEST_VERSION=1.2.4 FRIT_TEST_RUNTIME=0 FRIT_TEST_TIMESTAMP=0; do
  if check "$mismatch"; then fail "${mismatch} 不应通过"; fi
  echo "通过：拒绝 $mismatch"
done
check TEAM_ID='' CODESIGN_IDENTITY='' FRIT_TEST_TEAM=unknown FRIT_TEST_RUNTIME=0 FRIT_TEST_TIMESTAMP=0 \
  || fail "开发自测未指定团队或证书时仍需通过基本签名及版本检查"
echo "通过：未指定团队的开发自测"
