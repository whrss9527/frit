#!/usr/bin/env bash
# 从 ZIP 制作拖拽安装的 DMG，保留同一份 App 和公证票据。
set -euo pipefail

archive="${1:?用法：package-dmg.sh 应用.zip 输出.dmg}"
output="${2:?用法：package-dmg.sh 应用.zip 输出.dmg}"
scripts="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/app-dmg.XXXXXX")"
mounted=""
cleanup() {
  if [ -n "$mounted" ]; then hdiutil detach "$mounted" -force >/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/contents/.background" "$(dirname "$output")"
ditto -x -k "$archive" "$work/contents"
apps=("$work/contents/"*.app)
[ "${#apps[@]}" -eq 1 ] && [ -d "${apps[0]}" ] || { echo "ZIP 最外层必须只有一个 App" >&2; exit 1; }
app="${apps[0]}"
app_name="$(basename "$app")"
name="${app_name%.app}"
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
touch "$work/contents/.metadata_never_index"
xcrun swift "$scripts/dmg-background.swift" "$work/contents/.background/background.png" "$work/contents/Applications"
size="$(( $(du -sk "$work/contents" | awk '{print $1}') + 32768 ))k"
for attempt in 1 2 3; do
  if LC_ALL=C hdiutil create -ov -volname "${name} ${version}" -fs HFS+ -format UDRW \
    -size "$size" -srcfolder "$work/contents" "$work/layout.dmg" > "$work/create.log" 2>&1; then
    cat "$work/create.log"
    break
  else
    result=$?
  fi
  cat "$work/create.log"
  if ! grep -q 'Resource busy' "$work/create.log" || [ "$attempt" -eq 3 ]; then exit "$result"; fi
  sleep 2
done
mounted="$work/volume"
hdiutil attach "$work/layout.dmg" -mountpoint "$mounted" -nobrowse -noautoopen

osascript - "$mounted" "$app_name" <<'APPLESCRIPT'
on run arguments
  set imageFolder to POSIX file (item 1 of arguments) as alias
  set appName to item 2 of arguments
  tell application "Finder"
    tell folder imageFolder
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set bounds of container window to {120, 120, 680, 468}
      set viewOptions to icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 144
      set text size of viewOptions to 14
      set background picture of viewOptions to file ".background:background.png"
      set position of item appName to {145, 170}
      set position of item "Applications" to {415, 170}
      update without registering applications
      delay 2
      close
    end tell
  end tell
end run
APPLESCRIPT

sync
hdiutil detach "$mounted"
mounted=""
hdiutil convert "$work/layout.dmg" -ov -format UDZO -imagekey zlib-level=9 -o "$output"
hdiutil verify "$output"
mounted="$work/volume"
hdiutil attach "$output" -readonly -mountpoint "$mounted" -nobrowse -noautoopen
xcrun swift -e 'import Foundation; let target = try URL(resolvingAliasFileAt: URL(fileURLWithPath: CommandLine.arguments[1]), options: [.withoutUI, .withoutMounting]); if target.path != "/Applications" { exit(1) }' "$mounted/Applications"
[ -s "$mounted/.DS_Store" ] && [ -s "$mounted/.background/background.png" ] || { echo "DMG 缺少安装布局" >&2; exit 1; }
diff -qr "$app" "$mounted/$app_name"
hdiutil detach "$mounted"
mounted=""

args=(--force --sign "${CODESIGN_IDENTITY:--}" --identifier "${identifier}.diskimage")
if [ -n "${CODESIGN_IDENTITY:-}" ]; then args+=(--timestamp); fi
if [ -n "${CODESIGN_KEYCHAIN:-}" ]; then args+=(--keychain "$CODESIGN_KEYCHAIN"); fi
codesign "${args[@]}" "$output"
codesign --verify --strict "$output"
echo "已生成 ${output}"
