#!/bin/bash
# 检查版本、签名、可选的发布团队和 Developer ID 公证前提。
set -euo pipefail
: "${ARCHIVES:?没有设置 ARCHIVES}"
: "${VERSION:?没有设置 VERSION}"
team="${TEAM_ID:-}"
if [ -n "$team" ] && ! [[ "$team" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "::error::team-id 应为 10 位大写字母或数字"
  exit 1
fi
for archive in $ARCHIVES; do
  work="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/check-$(basename "$archive" .zip)"
  rm -rf "$work" && mkdir -p "$work"
  ditto -x -k "$archive" "$work"
  app="$(find "$work" -maxdepth 1 -name '*.app' -type d | head -1)"
  [ -n "$app" ] || { echo "::error::${archive} 的最外层没有 .app"; exit 1; }
  codesign --verify --deep --strict "$app"
  app_version="$(python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["CFBundleShortVersionString"])' "$app/Contents/Info.plist")"
  [ "$app_version" = "$VERSION" ] || { echo "::error::${archive} 里的版本号是 ${app_version}，应该是 ${VERSION}"; exit 1; }
  info="$(codesign -dvv "$app" 2>&1)"
  echo "$(basename "$archive")：版本 ${app_version}，$(printf '%s\n' "$info" | awk -F= '/^Authority=/{print $2; exit}')"
  if [ -n "$team" ]; then
    signed_team="$(printf '%s\n' "$info" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
    [ "$signed_team" = "$team" ] || { echo "::error::${archive} 的 TeamIdentifier 是 ${signed_team:-未知}，应该是 ${team}"; exit 1; }
  fi
  if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    printf '%s\n' "$info" | grep -q 'flags=.*runtime' || { echo "::error::${archive} 没有开 hardened runtime，公证不会通过"; exit 1; }
    printf '%s\n' "$info" | grep -q '^Timestamp=' || { echo "::error::${archive} 没有安全时间戳，公证不会通过"; exit 1; }
  fi
done
