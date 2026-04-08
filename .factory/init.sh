#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$repo_root/.spm-cache" "$repo_root/.derived-data"

if [ ! -d "$repo_root/extensions/openburnbar/node_modules" ]; then
  npm --prefix "$repo_root/extensions/openburnbar" ci
fi

if [ ! -f "$repo_root/.spm-cache/.mission-resolved" ]; then
  xcodebuild -resolvePackageDependencies \
    -project "$repo_root/OpenBurnBar.xcodeproj" \
    -scheme "OpenBurnBar" \
    -clonedSourcePackagesDirPath "$repo_root/.spm-cache" \
    -derivedDataPath "$repo_root/.derived-data/mission-resolve" \
    -quiet
  touch "$repo_root/.spm-cache/.mission-resolved"
fi
