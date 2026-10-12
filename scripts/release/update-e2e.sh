#!/bin/bash
# 公证与校验和完成后的可选更新验证。保留退出状态，失败时 Actions 不再进入发布步骤。
set -euo pipefail
[ -n "${UPDATE_E2E_COMMAND:-}" ] || exit 0
: "${ARCHIVE_DIR:?没有设置 ARCHIVE_DIR}"
: "${VERSION:?没有设置 VERSION}"
SHA256SUMS_FILE="$ARCHIVE_DIR/SHA256SUMS.txt"
[ -s "$SHA256SUMS_FILE" ] || { echo "::error::缺少更新验证需要的校验和：$SHA256SUMS_FILE"; exit 1; }
export SHA256SUMS_FILE
bash -c "$UPDATE_E2E_COMMAND"
