#!/bin/bash
# 构建可直接打开的 Sample.app，附带 SwiftPM 语言资源；只用于组件预览。
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SAMPLE_PACKAGE="$TASK_ROOT/Examples/UpdateSample"
SAMPLE_OUTPUT="${1:-$TASK_ROOT/dist/UpdateSample.app}"
swift build --package-path "$SAMPLE_PACKAGE"
SAMPLE_BIN=$(swift build --package-path "$SAMPLE_PACKAGE" --show-bin-path)
mkdir -p "$SAMPLE_OUTPUT/Contents/MacOS" "$SAMPLE_OUTPUT/Contents/Resources"
cp "$SAMPLE_BIN/UpdateSample" "$SAMPLE_OUTPUT/Contents/MacOS/UpdateSample"
if [ -d "$SAMPLE_BIN/Frit_FritUpdate.bundle" ]; then
  ditto "$SAMPLE_BIN/Frit_FritUpdate.bundle" "$SAMPLE_OUTPUT/Contents/Resources/Frit_FritUpdate.bundle"
else
  echo "没有找到 FritUpdate 语言资源" >&2
  exit 1
fi
cat > "$SAMPLE_OUTPUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.whrss9527.frit.UpdateSample</string>
<key>CFBundleExecutable</key><string>UpdateSample</string>
<key>CFBundleName</key><string>UpdateSample</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$SAMPLE_OUTPUT"
codesign --verify --deep --strict "$SAMPLE_OUTPUT"
echo "已构建组件预览：$SAMPLE_OUTPUT"
