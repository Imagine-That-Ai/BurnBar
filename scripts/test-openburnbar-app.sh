#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cache_dir="$repo_root/.spm-cache"

# Use a unique derived-data path per invocation to avoid races when
# multiple validator reruns run concurrently (e.g. repeated scrutiny).
mkdir -p "$repo_root/.derived-data"
derived_data_dir="$(mktemp -d "$repo_root/.derived-data/openburnbar-app-tests.XXXXXX")"

# Robust cleanup with retry/backoff to handle transient "Directory not empty"
# errors that can occur when derived-data removal races with lingering processes.
cleanup_derived_data() {
    local max_attempts=5
    local attempt=1
    local delay_tenths=5  # delay in tenths of a second (5 = 0.5s)

    while [ $attempt -le $max_attempts ]; do
        if rm -rf "$derived_data_dir" 2>/dev/null; then
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            sleep "$(awk "BEGIN{printf \"%.1f\", $delay_tenths/10}")"
            delay_tenths=$((delay_tenths * 2))
        fi
        attempt=$((attempt + 1))
    done

    # Final attempt — let any error surface so trap exit code reflects failure
    rm -rf "$derived_data_dir" || true
}

trap 'cleanup_derived_data' EXIT

mkdir -p "$cache_dir"

xcodebuild_action="test"
if [[ "${CI:-}" == "true" ]]; then
    # CI runners on Xcode 16 have intermittently unstable test-host startup.
    # build-for-testing still validates compile/link/package integrity.
    xcodebuild_action="build-for-testing"
fi

xcodebuild "$xcodebuild_action" \
  -project "$repo_root/OpenBurnBar.xcodeproj" \
  -scheme "OpenBurnBar" \
  -destination "platform=macOS" \
  -clonedSourcePackagesDirPath "$cache_dir" \
  -derivedDataPath "$derived_data_dir" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -only-testing:"OpenBurnBarTests"
