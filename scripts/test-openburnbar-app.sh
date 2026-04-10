#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cache_dir="$repo_root/.spm-cache"

# Use a unique derived-data path per invocation to avoid races when
# multiple validator reruns run concurrently (e.g. repeated scrutiny).
mkdir -p "$repo_root/.derived-data"
derived_data_dir="$(mktemp -d "$repo_root/.derived-data/openburnbar-app-tests.XXXXXX")"
trap 'rm -rf "$derived_data_dir"' EXIT

mkdir -p "$cache_dir"

xcodebuild test \
  -project "$repo_root/OpenBurnBar.xcodeproj" \
  -scheme "OpenBurnBar" \
  -destination "platform=macOS" \
  -clonedSourcePackagesDirPath "$cache_dir" \
  -derivedDataPath "$derived_data_dir" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -only-testing:"OpenBurnBarTests"
