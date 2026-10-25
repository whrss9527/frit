#!/bin/bash
# 真正启动 Sample.app：通过本地假发布验证替换、重启和提前退出回滚。
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
release="$here/../../scripts/release"
task_work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/frit-update.XXXXXX")
task_work=$(cd "$task_work" && pwd -P)
server_pid=""
completed=false
stop_apps() {
  /bin/ps -A -o pid=,command= | FRIT_TEST_ROOT="$task_work/" python3 -c '
import os, signal, sys
for line in sys.stdin:
    fields = line.strip().split(None, 1)
    if len(fields) == 2 and fields[1].startswith(os.environ["FRIT_TEST_ROOT"]) and "/Sample.app/Contents/MacOS/Sample" in fields[1]:
        try: os.kill(int(fields[0]), signal.SIGTERM)
        except ProcessLookupError: pass
'
}
cleanup() {
  local status=$?
  trap - EXIT
  stop_apps || true
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$task_work"
  # bash 3.2 某些展开错误的退出码可能为零，必须确认所有场景走到了末尾。
  if [ "$completed" != true ]; then status=1; fi
  exit "$status"
}
trap cleanup EXIT
fail() { echo "更新测试失败：$*" >&2; cat "$task_work"/*.log 2>/dev/null || true; exit 1; }
wait_for() {
  local limit="$1"
  shift
  local count=0
  until "$@"; do
    count=$((count + 1))
    [ "$count" -lt "$limit" ] || return 1
    sleep 1
  done
}
has_log() { grep -Fq "$2" "$1" 2>/dev/null; }
version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"; }
start_case() {
  local name="$1" strategy="$2"
  stop_apps
  mkdir -p "$task_work/$name"
  ditto "$task_work/dist/Sample.app" "$task_work/$name/Sample.app"
  SAMPLE_UPDATE_URL="$feed_url" SAMPLE_UPDATE_AUTO_INSTALL=1 SAMPLE_INSTALL_STRATEGY="$strategy" \
    SAMPLE_UPDATE_LOG="$task_work/$name.log" "$task_work/$name/Sample.app/Contents/MacOS/Sample" \
    > "$task_work/$name.stdout.log" 2>&1 &
}

VERSION=0.0.1 bash "$here/make-sample-app.sh" "$task_work/dist"
# 系统分配独占端口，假发布 helper 负责启动服务器并验证 HTTP 请求。
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
FAKE_DIR="$task_work/feed" FAKE_PORT="$port" GITHUB_ENV="$task_work/feed.env" \
  bash "$release/fake-release.sh" "$task_work/dist/Sample.app" Sample.zip
server_pid=$(sed -n 's/^FAKE_RELEASE_PID=//p' "$task_work/feed.env")
feed_url="http://127.0.0.1:$port/latest.json"
cp "$task_work/feed/latest.json" "$task_work/valid-feed.json"
cp "$task_work/feed/SHA256SUMS.txt" "$task_work/valid-sums.txt"

for strategy in staged atomic; do
  start_case "$strategy" "$strategy"
  wait_for 80 has_log "$task_work/$strategy.log" "SAMPLE_HEALTHY version=9.9.9" || fail "$strategy 没有替换并重新启动"
  [ "$(version_of "$task_work/$strategy/Sample.app")" = "9.9.9" ] || fail "$strategy 版本不符"
  has_log "$task_work/$strategy.log" "更新包校验通过" || fail "$strategy 没有校验"
  codesign --verify --deep --strict "$task_work/$strategy/Sample.app"
  sleep 1
  stop_apps
  echo "${strategy}：发现、下载、校验、替换、重新启动通过"
done

printf '%064d  Sample.zip\n' 0 > "$task_work/feed/SHA256SUMS.txt"
start_case bad-checksum staged
wait_for 35 has_log "$task_work/bad-checksum.log" "SAMPLE_FAILED checksumMismatch" || fail "没有拒绝错误校验和"
[ "$(version_of "$task_work/bad-checksum/Sample.app")" = "0.0.1" ] || fail "错误校验和改变了原程序"
stop_apps
cp "$task_work/valid-sums.txt" "$task_work/feed/SHA256SUMS.txt"
python3 - "$task_work/feed/latest.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
feed = json.loads(path.read_text())
feed["assets"] = []
path.write_text(json.dumps(feed))
PY
start_case no-archive staged
wait_for 35 has_log "$task_work/no-archive.log" "SAMPLE_FAILED noArchive" || fail "没有拒绝缺附件发布"
[ "$(version_of "$task_work/no-archive/Sample.app")" = "0.0.1" ] || fail "缺附件改变了原程序"
stop_apps

# 同一个假版本故意两秒内退出；真实 Relauncher 必须恢复旧程序，旧程序清理后记录拒绝版本。
cp "$task_work/valid-feed.json" "$task_work/feed/latest.json"
ditto "$task_work/dist/Sample.app" "$task_work/crash-source/Sample.app"
/usr/libexec/PlistBuddy -c 'Add :FritSampleFailAtStartup bool true' "$task_work/crash-source/Sample.app/Contents/Info.plist"
crash_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
FAKE_DIR="$task_work/crash-feed" FAKE_PORT="$crash_port" GITHUB_ENV="$task_work/crash.env" \
  bash "$release/fake-release.sh" "$task_work/crash-source/Sample.app" Sample.zip
crash_pid=$(sed -n 's/^FAKE_RELEASE_PID=//p' "$task_work/crash.env")
kill "$server_pid"
server_pid="$crash_pid"
feed_url="http://127.0.0.1:$crash_port/latest.json"
start_case rollback atomic
wait_for 100 has_log "$task_work/rollback.log" "SAMPLE_ROLLBACK rejected=9.9.9 restored=0.0.1" || fail "新版本提前退出后没有恢复旧程序"
has_log "$task_work/rollback.log" "SAMPLE_EARLY_EXIT version=9.9.9" || fail "没有实际启动失败的新版本"
[ "$(version_of "$task_work/rollback/Sample.app")" = "0.0.1" ] || fail "回滚版本不符"
codesign --verify --deep --strict "$task_work/rollback/Sample.app"
echo "更新成功、校验和错误、缺附件、真实提前退出回滚全部通过"
if [ -n "${FRIT_UPDATE_RESULT:-}" ]; then printf '%s\n' passed > "$FRIT_UPDATE_RESULT"; fi
completed=true
