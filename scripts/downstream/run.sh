#!/bin/bash
# 在独立 App checkout 中复用各仓库已有的构建、单测和更新场景。
set -euo pipefail
app="${1:?需要 App 名称}"
mode="${2:?需要 build、test 或 update}"
task_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$task_root/../app"
case "$app:$mode" in
  meno:build|stox:build|proxi:build) swift build ;;
  meno:test|stox:test) swift test ;;
  proxi:test)
    bash Scripts/ci/install-fish.sh
    bash Scripts/ci/test.sh
    ;;
  pop:build|pop:test)
    command -v xcodegen >/dev/null || brew install xcodegen
    xcodegen generate
    action="build"
    [ "$mode" != test ] || action="test"
    xcodebuild "$action" -project Pop.xcodeproj -scheme Pop -destination 'platform=macOS' \
      -clonedSourcePackagesDirPath .build/SourcePackages CODE_SIGNING_ALLOWED=NO > "$mode.log" 2>&1 || {
      tail -n 80 "$mode.log"; exit 1;
    }
    ;;
  meno:update)
    bash scripts/build-app.sh
    bash scripts/check-updating.sh build/Meno.app
    ;;
  stox:update)
    UNIVERSAL=1 bash scripts/build-app.sh
    bash scripts/ci-e2e.sh update
    ;;
  pop:update)
    bash scripts/build-app.sh 0.0.0-ci build/downstream
    bash scripts/update-e2e.sh build/downstream/Pop.app
    ;;
  proxi:update)
    bash Scripts/ci/package.sh
    bash Scripts/ci/build-tools.sh
    bash Scripts/ci/update-e2e.sh
    ;;
  *) echo "不支持的下游检查：$app $mode" >&2; exit 2 ;;
esac
