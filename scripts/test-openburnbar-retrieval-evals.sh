#!/usr/bin/env bash
#
# test-openburnbar-retrieval-evals.sh — Replay golden suites for retrieval
# (search) and authoring (writeback) on a focused xcodebuild test invocation.
# Reuses the SOTA retry/telemetry pattern from `test-openburnbar-app.sh`:
# pre-cleans stale OpenBurnBar/xctest hosts, retries up to 4 times on the
# known XCTest IPC startup hang, and surfaces real failures fast.
#
# Why this matters: the replay-golden suites guard the retrieval+authoring
# spine; transient XCTest startup hangs would otherwise count as red and
# block the release-smoke gate even though the app suite is green.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cache_dir="$repo_root/.spm-cache"

mkdir -p "$repo_root/.derived-data"
mkdir -p "$cache_dir"

derived_data_root="$repo_root/.derived-data"
hang_substrings=(
    "test runner hung before establishing connection"
    "Test runner never began executing tests"
    "Test session timed out"
    "Failed to launch test runner"
    "failed to launch"
    "Lost connection to the test runner"
    "Could not attach to pid"
    "TestRunner crashed"
)
backoff_seconds=(0 5 10 20)
max_attempts="${OPENBURNBAR_RETRIEVAL_EVAL_ATTEMPTS:-4}"

is_known_hang() {
    local log_path="$1"
    local pattern
    for pattern in "${hang_substrings[@]}"; do
        if grep -Fq "$pattern" "$log_path"; then
            return 0
        fi
    done
    return 1
}

preclean_stale_processes() {
    pkill -9 -f "OpenBurnBar.app/Contents/MacOS/OpenBurnBar" 2>/dev/null || true
    pkill -9 -f "OpenBurnBarTests.xctest" 2>/dev/null || true
}

attempt=1
last_exit_code=0
while [ "$attempt" -le "$max_attempts" ]; do
    if [ "$attempt" -gt 1 ]; then
        local_idx=$((attempt - 1))
        if [ "$local_idx" -ge "${#backoff_seconds[@]}" ]; then
            local_idx=$((${#backoff_seconds[@]} - 1))
        fi
        wait_for=${backoff_seconds[$local_idx]}
        echo ">>> Retrieval-eval retry $attempt/$max_attempts after known XCTest hang. Sleeping ${wait_for}s." >&2
        sleep "$wait_for"
    fi

    preclean_stale_processes

    derived_data_dir="$(mktemp -d "$derived_data_root/openburnbar-retrieval-evals.XXXXXX")"
    log_file="$derived_data_dir/xcodebuild.log"

    set +e
    xcodebuild test \
      -project "$repo_root/OpenBurnBar.xcodeproj" \
      -scheme "OpenBurnBar" \
      -destination "platform=macOS,arch=arm64" \
      -clonedSourcePackagesDirPath "$cache_dir" \
      -derivedDataPath "$derived_data_dir" \
      -test-timeouts-enabled YES \
      -default-test-execution-time-allowance 600 \
      -maximum-test-execution-time-allowance 1200 \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      -only-testing:"OpenBurnBarTests/OpenBurnBarRetrievalReplayGoldenTests" \
      -only-testing:"OpenBurnBarTests/OpenBurnBarAuthoringReplayGoldenTests" 2>&1 | tee "$log_file"
    last_exit_code=${PIPESTATUS[0]}
    set -e

    if [ "$last_exit_code" -eq 0 ]; then
        rm -rf "$derived_data_dir"
        exit 0
    fi

    if is_known_hang "$log_file"; then
        echo ">>> Detected known XCTest startup hang on attempt $attempt." >&2
        rm -rf "$derived_data_dir"
        attempt=$((attempt + 1))
        continue
    fi

    rm -rf "$derived_data_dir"
    exit "$last_exit_code"
done

echo ">>> Retrieval evals exhausted $max_attempts retries on XCTest startup hang." >&2
exit "$last_exit_code"
