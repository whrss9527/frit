#!/bin/bash
# 从通用二进制（Apple 芯片 + Intel）的 .app 里各取一种芯片，打成两个精简包，一键更新时按本机芯片下载，只有通用包一半大。
#   scripts/release/thin-archives.sh dist/Foo.app dist/Foo-macos [权限声明.entitlements]
#   → dist/Foo-macos-arm64.zip、dist/Foo-macos-x86_64.zip
# Contents/MacOS 里的每个程序都会被瘦身；某个程序里没有这种芯片时，跳过这种芯片的包。
# 瘦身后先签里面的辅助程序、再签整个 .app（规则同 sign.sh，同样读 CODESIGN_IDENTITY、CODESIGN_KEYCHAIN）。
set -euo pipefail

[ $# -ge 2 ] || { echo "用法：thin-archives.sh 通用.app 输出前缀 [权限声明.entitlements]"; exit 1; }
app="$1"
prefix="$2"
entitlements="${3:-}"
here="$(cd "$(dirname "$0")" && pwd)"
[ -d "$app" ] || { echo "找不到 $app"; exit 1; }
app_name="$(basename "$app")"
main_exec="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$app/Contents/Info.plist")"

for arch in arm64 x86_64; do
  dir="${prefix}-thin-${arch}"
  rm -rf "$dir" && mkdir -p "$dir"
  ditto "$app" "$dir/$app_name"
  missing=""
  for bin in "$dir/$app_name/Contents/MacOS/"*; do
    [ -f "$bin" ] || continue
    archs="$(lipo -archs "$bin" 2>/dev/null || true)"
    [ -n "$archs" ] || continue
    if [ "$archs" = "$arch" ]; then
      continue
    elif [[ " $archs " == *" $arch "* ]]; then
      lipo "$bin" -thin "$arch" -output "${bin}.thin"
      mv "${bin}.thin" "$bin"
      chmod +x "$bin"
    else
      missing="$bin"
    fi
  done
  if [ -n "$missing" ]; then
    echo "跳过 ${arch} 精简包：${missing} 里没有这个架构"
    rm -rf "$dir"
    continue
  fi
  for bin in "$dir/$app_name/Contents/MacOS/"*; do
    [ -f "$bin" ] || continue
    [ "$(basename "$bin")" = "$main_exec" ] && continue
    lipo -archs "$bin" >/dev/null 2>&1 || continue
    "$here/sign.sh" "$bin"
  done
  if [ -n "$entitlements" ]; then
    "$here/sign.sh" "$dir/$app_name" "$entitlements"
  else
    "$here/sign.sh" "$dir/$app_name"
  fi
  codesign --verify --deep --strict "$dir/$app_name"
  # 先算出绝对路径，下面 cd 进临时文件夹以后相对路径就不对了。
  out="$(cd "$(dirname "$prefix")" && pwd)/$(basename "$prefix")-${arch}.zip"
  rm -f "$out"
  (cd "$dir" && ditto -c -k --keepParent "$app_name" "$out")
  rm -rf "$dir"
  echo "已生成 ${prefix}-${arch}.zip：$(du -h "$out" | cut -f1)"
done
