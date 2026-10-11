#!/bin/bash
# Apple ID 密码只从 stdin 传给一次 store-credentials；后续调用只用 profile，退出必清理。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../../scripts/release/notarize.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/runner"
cat > "$work/bin/security" <<'SH'
#!/bin/bash
echo "security $1" >> "$FRIT_TEST_CALLS"
SH
cat > "$work/bin/xcrun" <<'SH'
#!/bin/bash
set -euo pipefail
for argument in "$@"; do
  [ "$argument" != --password ] || { echo "密码进入了命令行参数" >&2; exit 99; }
done
printf '%s\n' "$*" >> "$FRIT_TEST_CALLS"
case "$1 $2" in
  "notarytool store-credentials")
    IFS= read -r password
    [ "$password" = test-password ] || exit 99
    exit "$FRIT_TEST_STORE_EXIT"
    ;;
  "notarytool submit"|"notarytool wait"|"notarytool log")
    case " $* " in *' --keychain-profile frit-notary '*) ;; *) exit 99 ;; esac
    case "$2" in
      submit) printf '{"id":"test"}\n' ;;
      wait) printf '{"status":"Accepted"}\n' ;;
      log) printf '{}\n' ;;
    esac
    ;;
  "stapler staple"|"stapler validate") ;;
  *) exit 99 ;;
esac
SH
cat > "$work/bin/ditto" <<'SH'
#!/bin/bash
if [ "$1" = -x ]; then mkdir -p "$4/Sample.app"; else
  for target in "$@"; do :; done
  printf 'repacked\n' > "$target"
fi
SH
printf '#!/bin/bash\nexit 0\n' > "$work/bin/spctl"
chmod +x "$work/bin/"*
run() {
  printf 'original\n' > "$work/Sample.zip"
  : > "$work/calls"
  env PATH="$work/bin:$PATH" RUNNER_TEMP="$work/runner" NOTARY_KEY_P8='' \
    NOTARY_APPLE_ID=test@example.invalid NOTARY_PASSWORD=test-password NOTARY_TEAM_ID=ABCDE12345 \
    FRIT_TEST_CALLS="$work/calls" FRIT_TEST_STORE_EXIT=0 "$@" "$script" "$work/Sample.zip" > "$work/log" 2>&1
}
fail() { cat "$work/log" >&2; echo "失败：$*" >&2; exit 1; }
run || fail "profile 公证流程应该通过"
grep -q '^notarytool store-credentials ' "$work/calls" || fail "未创建 profile"
grep -q '^notarytool submit .*--keychain-profile' "$work/calls" || fail "提交未使用 profile"
grep -q '^notarytool wait .*--keychain-profile' "$work/calls" || fail "等待未使用 profile"
grep -q '^security delete-keychain$' "$work/calls" || fail "成功后未清理钥匙串"
if grep -q test-password "$work/calls"; then fail "密码泄漏到调用参数"; fi
echo "通过：stdin 存储密码，后续使用 profile，成功后清理"
if run FRIT_TEST_STORE_EXIT=5; then fail "凭据存储失败应终止"; fi
grep -q '^security delete-keychain$' "$work/calls" || fail "失败后未清理钥匙串"
if grep -q '^notarytool submit ' "$work/calls"; then fail "凭据失败后继续提交"; fi
[ "$(cat "$work/Sample.zip")" = original ] || fail "失败覆盖了原归档"
echo "通过：凭据存储失败后停止并清理"
