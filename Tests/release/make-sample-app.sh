#!/bin/bash
# 做一个最小的菜单栏 App（Sample.app），给发布脚本的自测用：
# 主程序和一个辅助程序都是 Apple 芯片 + Intel 的通用二进制，这样能测由内向外签名和精简包。
#   Tests/release/make-sample-app.sh dist            → dist/Sample.app（ad-hoc 签名）
# 读 VERSION（默认 0.0.1）、CODESIGN_IDENTITY、CODESIGN_KEYCHAIN；FRIT_RELEASE 指向 scripts/release。
set -euo pipefail

out="${1:-dist}"
version="${VERSION:-0.0.1}"
here="$(cd "$(dirname "$0")" && pwd)"
release="${FRIT_RELEASE:-$here/../../scripts/release}"
work="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/frit-sample"
rm -rf "$work" && mkdir -p "$work" "$out"

cat > "$work/main.swift" <<'SWIFT'
import AppKit
print("Sample \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") 已启动")
if CommandLine.arguments.contains("--exit") { exit(0) }
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
SWIFT
cat > "$work/helper.swift" <<'SWIFT'
print("helper")
SWIFT

for arch in arm64 x86_64; do
  swiftc -O -target "${arch}-apple-macos13" "$work/main.swift" -o "$work/Sample-$arch"
  swiftc -O -target "${arch}-apple-macos13" "$work/helper.swift" -o "$work/helper-$arch"
done

app="$out/Sample.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
lipo -create -output "$app/Contents/MacOS/Sample" "$work/Sample-arm64" "$work/Sample-x86_64"
lipo -create -output "$app/Contents/MacOS/sample-helper" "$work/helper-arm64" "$work/helper-x86_64"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Sample</string>
  <key>CFBundleIdentifier</key><string>io.github.whrss9527.frit.sample</string>
  <key>CFBundleName</key><string>Sample</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER:-1}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
cat > "$work/Sample.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
PLIST
cp "$work/Sample.entitlements" "$out/Sample.entitlements"

"$release/sign.sh" "$app/Contents/MacOS/sample-helper"
"$release/sign.sh" "$app" "$out/Sample.entitlements"
codesign --verify --deep --strict "$app"
echo "已生成 ${app}（版本 ${version}）：$(lipo -archs "$app/Contents/MacOS/Sample")"
