#!/bin/bash
# 给一个程序、框架或 .app 签名。发布用的签名规则统一在这里：
#   - 都开 hardened runtime（公证要求；ad-hoc 构建也开，CI 里测到的就是发布出去的运行方式）；
#   - 有开发者证书时带安全时间戳（公证要求，证书过期后签名照样有效），ad-hoc 签名不能带时间戳。
#
#   scripts/release/sign.sh dist/Foo.app/Contents/MacOS/helper      先签里面的程序
#   scripts/release/sign.sh dist/Foo.app Resources/Foo.entitlements  再签整个 .app（可以带权限声明）
#
# 由内向外签，不要用 --deep（它会用同样的参数重签里面的东西，权限声明就错了）。
# 环境变量：
#   CODESIGN_IDENTITY  证书名字或 SHA-1；不设或设成 - 时 ad-hoc 签名
#   CODESIGN_KEYCHAIN  证书所在的钥匙串（import-certificate.sh 会设好）
set -euo pipefail

[ $# -ge 1 ] || { echo "用法：sign.sh 路径 [权限声明.entitlements]"; exit 1; }
target="$1"
entitlements="${2:-}"
[ -e "$target" ] || { echo "找不到 $target"; exit 1; }

identity="${CODESIGN_IDENTITY:--}"
args=(--force --options runtime --sign "$identity")
if [ "$identity" != "-" ]; then
  args+=(--timestamp)
fi
if [ -n "${CODESIGN_KEYCHAIN:-}" ]; then
  args+=(--keychain "$CODESIGN_KEYCHAIN")
fi
if [ -n "$entitlements" ]; then
  [ -f "$entitlements" ] || { echo "找不到权限声明 $entitlements"; exit 1; }
  args+=(--entitlements "$entitlements")
fi
codesign "${args[@]}" "$target"
