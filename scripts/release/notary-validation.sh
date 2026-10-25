#!/bin/bash
# notarize.sh 与只读归档验收共用；不修改系统策略，不接受缓存例外。
frit_notary_validation_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

stapler_with_retry() {
  local action="$1" app="$2" attempt result
  for attempt in 1 2 3; do
    if xcrun stapler "$action" "$app"; then return 0; else result=$?; fi
    [ "$result" -eq 68 ] && [ "$attempt" -lt 3 ] || return "$result"
    echo "票据 ${action} 网络查询未完成，5 秒后重试（${attempt}/3）"
    sleep 5
  done
}

verify_notarized_app() {
  local app="$1" evidence="$2" attempt
  mkdir -p "$evidence"
  codesign --verify --deep --strict --all-architectures "$app" || return 1
  codesign --display --verbose=4 "$app" > "$evidence/signature.txt" 2>&1 || return 1
  grep -q '^Authority=Developer ID Application: ' "$evidence/signature.txt" || {
    echo '缺少 Developer ID Application 签名'; return 1;
  }
  if [ -n "${CODESIGN_NAME:-}" ]; then
    grep -Fxq "Authority=${CODESIGN_NAME}" "$evidence/signature.txt" || {
      echo '归档签名与导入的证书不一致'; return 1;
    }
  fi
  stapler_with_retry validate "$app" || return 1
  python3 "$frit_notary_validation_dir/check-ticket.py" "$app" || return 1
  spctl --status > "$evidence/policy.txt" 2>&1 || { cat "$evidence/policy.txt"; return 1; }
  grep -Fxq 'assessments enabled' "$evidence/policy.txt" || { cat "$evidence/policy.txt"; return 1; }
  if grep -Eiq 'override|security.*disabled|assessments.*disabled' "$evidence/policy.txt"; then
    cat "$evidence/policy.txt"; return 1
  fi
  for attempt in $(seq 1 "${SPCTL_TRIES:-6}"); do
    if spctl --assess --type execute --verbose=2 "$app" > "$evidence/assessment.txt" 2>&1; then
      if ! grep -Eiq 'override|security.*disabled|assessments.*disabled' "$evidence/assessment.txt" \
         && grep -Fxq 'source=Notarized Developer ID' "$evidence/assessment.txt"; then
        cat "$evidence/assessment.txt"; return 0
      fi
    fi
    if [ "$attempt" -lt "${SPCTL_TRIES:-6}" ]; then sleep "${SPCTL_INTERVAL:-10}"; fi
  done
  cat "$evidence/assessment.txt"
  echo '归档未通过公证后的 Gatekeeper 验收'
  return 1
}
