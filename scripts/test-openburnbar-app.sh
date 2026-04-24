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

xcodebuild_log=""
last_test_exit_code=0

cleanup() {
    if [ -n "$xcodebuild_log" ]; then
        rm -f "$xcodebuild_log" 2>/dev/null || true
    fi
    cleanup_derived_data
}

trap 'cleanup' EXIT

mkdir -p "$cache_dir"

xcodebuild_args=(
  -project "$repo_root/OpenBurnBar.xcodeproj"
  -scheme "OpenBurnBar"
  -destination "platform=macOS,arch=arm64"
  -clonedSourcePackagesDirPath "$cache_dir"
  -derivedDataPath "$derived_data_dir"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  -only-testing:"OpenBurnBarTests"
)

if [[ "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" ]]; then
  xcodebuild_args+=(-enableCodeCoverage YES)
  xcresult_path="$repo_root/.derived-data/OpenBurnBar_TestCoverage.xcresult"
  rm -rf "$xcresult_path"
  xcodebuild_args+=(-resultBundlePath "$xcresult_path")
fi

# Retry logic: attempt xcodebuild test up to 2 times.
# The XCTest runner intermittently hangs on startup; a fresh derived-data
# directory on retry usually resolves it. Only fall back to build-for-testing
# after all test attempts are exhausted.
max_test_attempts=2

test_attempt=1
while [ $test_attempt -le $max_test_attempts ]; do
    if [ $test_attempt -gt 1 ]; then
        echo "Retrying xcodebuild test (attempt $test_attempt of $max_test_attempts) with fresh derived data..."
        cleanup_derived_data
        derived_data_dir="$(mktemp -d "$repo_root/.derived-data/openburnbar-app-tests.XXXXXX")"
        xcodebuild_args=(
            -project "$repo_root/OpenBurnBar.xcodeproj"
            -scheme "OpenBurnBar"
            -destination "platform=macOS,arch=arm64"
            -clonedSourcePackagesDirPath "$cache_dir"
            -derivedDataPath "$derived_data_dir"
            CODE_SIGNING_ALLOWED=NO
            CODE_SIGNING_REQUIRED=NO
            -only-testing:"OpenBurnBarTests"
        )
        xcodebuild_log="$(mktemp "$repo_root/.derived-data/openburnbar-app-tests-log.XXXXXX.log")"
    else
        xcodebuild_log="$(mktemp "$repo_root/.derived-data/openburnbar-app-tests-log.XXXXXX.log")"
    fi

    set +e
    xcodebuild test "${xcodebuild_args[@]}" 2>&1 | tee "$xcodebuild_log"
    last_test_exit_code=${PIPESTATUS[0]}
    set -e

    if [ "$last_test_exit_code" -eq 0 ]; then
        exit 0
    fi

    if grep -Fq "test runner hung before establishing connection" "$xcodebuild_log"; then
        echo "Detected XCTest runner startup hang on attempt $test_attempt."
        test_attempt=$((test_attempt + 1))
        continue
    fi

    # Test failed for a real reason (not the hang bug) — don't retry
    exit "$last_test_exit_code"
done

# All retries exhausted
if [[ "${CI:-}" == "true" ]]; then
    echo "ERROR: All test attempts failed in CI. Running build-for-testing as compile safety net, but reporting failure."
    xcodebuild build-for-testing "${xcodebuild_args[@]}" || true
    exit 1
else
    echo "WARNING: All test attempts failed locally. Running build-for-testing as fallback."
    xcodebuild build-for-testing "${xcodebuild_args[@]}" || true
    exit "$last_test_exit_code"
fi
