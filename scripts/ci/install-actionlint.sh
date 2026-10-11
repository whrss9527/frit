#!/bin/bash
# 固定版本与官方发布校验和，不执行下载的安装脚本。
set -euo pipefail
destination="${1:?用法：install-actionlint.sh 安装目录}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
archive="$work/actionlint_1.7.7_linux_amd64.tar.gz"
curl --fail --silent --show-error --location \
  https://github.com/rhysd/actionlint/releases/download/v1.7.7/actionlint_1.7.7_linux_amd64.tar.gz \
  --output "$archive"
printf '023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757  %s\n' "$archive" | sha256sum --check
tar -xzf "$archive" -C "$work" actionlint
mkdir -p "$destination"
cp "$work/actionlint" "$destination/actionlint"
chmod +x "$destination/actionlint"
