#!/bin/bash
# 验证 DMG 与对应 ZIP 中的 App 一致，检查两层签名、公证和安装目标。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/release/notary-validation.sh
. "$here/notary-validation.sh"
image="${1:?需要 DMG 安装包}"
archive="${2:?需要对应 ZIP}"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/frit-dmg-check.XXXXXX")"
mounted=""
cleanup() {
  if [ -n "$mounted" ]; then hdiutil detach "$mounted" -force >/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

hdiutil verify "$image"
mounted="$work/volume"
hdiutil attach "$image" -readonly -mountpoint "$mounted" -nobrowse -noautoopen
ditto -x -k "$archive" "$work/reference"
apps=("$work/reference/"*.app)
[ "${#apps[@]}" -eq 1 ] && [ -d "${apps[0]}" ] || { echo "ZIP 必须只含一个顶层 App"; exit 1; }
name="$(basename "${apps[0]}")"
diff -qr "${apps[0]}" "$mounted/$name"
[ -s "$mounted/.DS_Store" ] && [ -s "$mounted/.background/background.png" ] || { echo "DMG 缺少安装布局"; exit 1; }
xcrun swift -e 'import Foundation; let target = try URL(resolvingAliasFileAt: URL(fileURLWithPath: CommandLine.arguments[1]), options: [.withoutUI, .withoutMounting]); if target.path != "/Applications" { exit(1) }' "$mounted/Applications"
verify_notarized_app "$mounted/$name" "$work/app"
codesign --verify --strict "$image"
codesign --display --verbose=4 "$image" > "$work/signature.txt" 2>&1
grep -q '^Authority=Developer ID Application: ' "$work/signature.txt"
if [ -n "${CODESIGN_NAME:-}" ]; then grep -Fxq "Authority=${CODESIGN_NAME}" "$work/signature.txt"; fi
team="$(codesign --display --verbose=4 "$mounted/$name" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]]
grep -Fxq "TeamIdentifier=${team}" "$work/signature.txt"
stapler_with_retry validate "$image"
spctl --assess --type open --context context:primary-signature --verbose=2 "$image" > "$work/assessment.txt" 2>&1
cat "$work/assessment.txt"
if grep -Eiq 'override|security.*disabled|assessments.*disabled' "$work/assessment.txt"; then exit 1; fi
grep -Fxq 'source=Notarized Developer ID' "$work/assessment.txt"
