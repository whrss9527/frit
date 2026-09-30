#!/bin/bash
# 在 GitHub 的 macOS runner 上切到最新的正式版 Xcode（跳过 beta 和 RC）。
# 用 Xcode 26 编译时，玻璃效果在 macOS 26 上才会换成系统的 Liquid Glass。
set -euo pipefail
latest=""
candidates=""
for xcode in /Applications/Xcode_*.app /Applications/Xcode.app; do
  [ -d "$xcode" ] || continue
  case "$(basename "$xcode" | tr '[:upper:]' '[:lower:]')" in
    *beta*|*release_candidate*|*_rc*) continue ;;
  esac
  candidates="${candidates}${xcode}
"
done
if [ -n "$candidates" ]; then
  latest="$(printf '%s' "$candidates" | sort -V | tail -1)"
  sudo xcode-select -s "$latest"
fi
xcodebuild -version
swift --version
