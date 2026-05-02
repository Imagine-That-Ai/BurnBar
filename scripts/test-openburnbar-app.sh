#!/usr/bin/env bash
#
# test-openburnbar-app.sh — SOTA test driver for the OpenBurnBar Xcode app target.
#
# Responsibilities:
#   1. Pre-clean stale OpenBurnBar / xctest host processes before each attempt
#      so we never inherit a half-dead runner from a prior crash.
#   2. Run xcodebuild test against the OpenBurnBarTests bundle with per-attempt
#      isolated derived data and result bundles.
#   3. Detect known XCTest startup hang families and retry with exponential
#      backoff (4 attempts). Real test failures fail fast — no retry storms.
#   4. Emit structured JSONL telemetry per attempt + a final summary so failures
#      are diagnosable without scrolling 5 MB of xcodebuild noise.
#   5. Promote the successful attempt's xcresult to the canonical coverage path
#      when OPENBURNBAR_ENABLE_COVERAGE=YES.
#
# Environment knobs:
#   OPENBURNBAR_ENABLE_COVERAGE=YES   Capture xcresult at canonical path.
#   OPENBURNBAR_APP_TEST_ATTEMPTS=N   Override max attempts (default 4).
#   OPENBURNBAR_APP_TEST_FILTER=...   Pass a custom -only-testing target.
#
# Exit status:
#   0  — at least one attempt completed all tests successfully.
#   N  — the final xcodebuild exit code from the last failing attempt.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cache_dir="$repo_root/.spm-cache"
derived_data_root="$repo_root/.derived-data"
attempt_log_path="$derived_data_root/test-openburnbar-app-attempts.jsonl"

# Test runner timeouts (seconds). Defensive guards against hung individual
# test methods or stuck setup. Real CI overrides these via env if needed.
default_test_execution_allowance="${OPENBURNBAR_APP_TEST_DEFAULT_ALLOWANCE:-600}"
maximum_test_execution_allowance="${OPENBURNBAR_APP_TEST_MAX_ALLOWANCE:-1200}"

# Retry budget. Default 4 — the XCTest runner-connect race typically clears
# after process cleanup + fresh derived data; if it hasn't cleared by attempt
# 4, the failure is real.
max_test_attempts="${OPENBURNBAR_APP_TEST_ATTEMPTS:-4}"

# Test filter. Default to the active app test bundle. Callers can override
# (e.g. for targeted snapshot re-records: -only-testing:OpenBurnBarTests/SomeClass)
test_filter="${OPENBURNBAR_APP_TEST_FILTER:-OpenBurnBarTests}"

mkdir -p "$cache_dir"
mkdir -p "$derived_data_root"

# Per-invocation state
derived_data_dir="$(mktemp -d "$derived_data_root/openburnbar-app-tests.XXXXXX")"
xcodebuild_log=""
xcodebuild_args=()
last_test_exit_code=0
invocation_start_epoch="$(date +%s)"

# ---------------------------------------------------------------------------
# Telemetry
# ---------------------------------------------------------------------------

emit_attempt_event() {
    # Args: attempt exit_code outcome duration_seconds xcresult_path
    local attempt="$1"
    local exit_code="$2"
    local outcome="$3"
    local duration="$4"
    local xcresult_path="$5"
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "$attempt" "$exit_code" "$outcome" "$duration" "$xcresult_path" "$timestamp" "$attempt_log_path" <<'PY'
import json
import sys

attempt, exit_code, outcome, duration, xcresult_path, timestamp, dest = sys.argv[1:]
record = {
    "kind": "attempt",
    "timestamp": timestamp,
    "attempt": int(attempt),
    "exitCode": int(exit_code),
    "outcome": outcome,
    "durationSeconds": int(duration),
    "xcresultPath": xcresult_path,
}
with open(dest, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record) + "\n")
PY
}

emit_summary_event() {
    # Args: outcome attempts total_duration final_exit
    local outcome="$1"
    local attempts="$2"
    local total_duration="$3"
    local final_exit="$4"
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "$outcome" "$attempts" "$total_duration" "$final_exit" "$timestamp" "$attempt_log_path" <<'PY'
import json
import sys

outcome, attempts, duration, final_exit, timestamp, dest = sys.argv[1:]
record = {
    "kind": "summary",
    "timestamp": timestamp,
    "outcome": outcome,
    "attempts": int(attempts),
    "totalDurationSeconds": int(duration),
    "finalExitCode": int(final_exit),
}
with open(dest, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record) + "\n")
PY
    echo "Telemetry written to $attempt_log_path"
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

# Robust cleanup with retry/backoff to handle transient "Directory not empty"
# errors that can occur when derived-data removal races with lingering processes.
cleanup_derived_data() {
    local target="${1:-$derived_data_dir}"
    local max_attempts=5
    local attempt=1
    local delay_tenths=5  # delay in tenths of a second (5 = 0.5s)

    while [ $attempt -le $max_attempts ]; do
        if rm -rf "$target" 2>/dev/null; then
            return 0
        fi
        if [ $attempt -lt $max_attempts ]; then
            sleep "$(awk "BEGIN{printf \"%.1f\", $delay_tenths/10}")"
            delay_tenths=$((delay_tenths * 2))
        fi
        attempt=$((attempt + 1))
    done

    # Final attempt — let any error surface so trap exit code reflects failure
    rm -rf "$target" || true
}

# Pre-attempt process hygiene. Orphaned OpenBurnBar / xctest hosts from a
# prior crashed run will eat the next runner's connect window and produce
# the "test runner hung before establishing connection" error.
preclean_stale_processes() {
    local patterns=(
        "OpenBurnBar.app/Contents/MacOS/OpenBurnBar"
        "OpenBurnBarTests.xctest"
        "xctest .*OpenBurnBarTests"
    )
    for pattern in "${patterns[@]}"; do
        # pkill returns 1 when no match, which is fine.
        pkill -f "$pattern" >/dev/null 2>&1 || true
    done
    # Give launchd a moment to reap.
    sleep 0.2
}

cleanup() {
    if [ -n "$xcodebuild_log" ]; then
        rm -f "$xcodebuild_log" 2>/dev/null || true
    fi
    cleanup_derived_data "$derived_data_dir"
}

trap 'cleanup' EXIT

# ---------------------------------------------------------------------------
# xcodebuild argument assembly
# ---------------------------------------------------------------------------

populate_xcodebuild_args() {
    # Populates the global `xcodebuild_args` array in place.
    # Args: derived_data attempt_xcresult
    local dd="$1"
    local attempt_result="$2"
    xcodebuild_args=(
        -project "$repo_root/OpenBurnBar.xcodeproj"
        -scheme "OpenBurnBar"
        -destination "platform=macOS,arch=arm64"
        -clonedSourcePackagesDirPath "$cache_dir"
        -derivedDataPath "$dd"
        -resultBundlePath "$attempt_result"
        -test-timeouts-enabled YES
        -default-test-execution-time-allowance "$default_test_execution_allowance"
        -maximum-test-execution-time-allowance "$maximum_test_execution_allowance"
        CODE_SIGNING_ALLOWED=NO
        CODE_SIGNING_REQUIRED=NO
        -only-testing:"$test_filter"
    )
    if [[ "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" ]]; then
        xcodebuild_args+=(-enableCodeCoverage YES)
    fi
    # Forward the SnapshotTesting record-mode env var into the test runner
    # process. xcodebuild only forwards env vars that begin with
    # `TEST_RUNNER_`, so callers set `OPENBURNBAR_SNAPSHOT_RECORD=all`
    # locally and we translate it to `TEST_RUNNER_SNAPSHOT_TESTING_RECORD`
    # which the swift-snapshot-testing runtime reads on first access.
    if [[ -n "${OPENBURNBAR_SNAPSHOT_RECORD:-}" ]]; then
        xcodebuild_args+=("TEST_RUNNER_SNAPSHOT_TESTING_RECORD=${OPENBURNBAR_SNAPSHOT_RECORD}")
    fi
}

# Canonical coverage xcresult location consumed by extract-coverage.sh
canonical_xcresult_path="$derived_data_root/OpenBurnBar_TestCoverage.xcresult"
if [[ "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" ]]; then
    rm -rf "$canonical_xcresult_path"
fi

# Truncate the per-invocation telemetry stream so each fresh run is self-
# contained for diagnostics. Append-only within the run.
: > "$attempt_log_path"

# ---------------------------------------------------------------------------
# Hang detection
# ---------------------------------------------------------------------------

# Known XCTest host startup/handshake failure substrings. Match any of these
# and retry; everything else is a real failure.
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

# ---------------------------------------------------------------------------
# Backoff schedule
# ---------------------------------------------------------------------------

# Index 0 is the initial attempt (no backoff). Indices 1..N-1 are between-
# attempt sleeps in seconds.
backoff_seconds=(0 5 10 20 40)

# ---------------------------------------------------------------------------
# Main retry loop
# ---------------------------------------------------------------------------

test_attempt=1
final_exit_code=0
final_outcome="failed"
final_xcresult=""

while [ "$test_attempt" -le "$max_test_attempts" ]; do
    if [ "$test_attempt" -gt 1 ]; then
        local_idx=$((test_attempt - 1))
        if [ "$local_idx" -ge "${#backoff_seconds[@]}" ]; then
            local_idx=$((${#backoff_seconds[@]} - 1))
        fi
        wait_for=${backoff_seconds[$local_idx]}
        # Even-numbered retries (2, 4, 6) keep the derived-data dir intact and
        # rely on a longer sleep to clear the XCTest IPC race; odd-numbered
        # retries (3, 5) refresh derived data from scratch. This alternation
        # covers both classes of hang we've observed: the "stale runner state"
        # variant (cleared by a fresh derived data dir) and the "macOS XCTest
        # IPC race" variant (cleared by a longer cooldown alone).
        echo ">>> Retry attempt $test_attempt of $max_test_attempts after known XCTest hang. Sleeping ${wait_for}s."
        sleep "$wait_for"
        if (( test_attempt % 2 == 1 )); then
            echo ">>> Refreshing derived data for attempt $test_attempt."
            cleanup_derived_data "$derived_data_dir"
            derived_data_dir="$(mktemp -d "$derived_data_root/openburnbar-app-tests.XXXXXX")"
        else
            echo ">>> Reusing derived data for attempt $test_attempt (warm-cache retry)."
        fi
    fi

    preclean_stale_processes

    attempt_xcresult="$derived_data_dir/OpenBurnBarTests-attempt-$test_attempt.xcresult"
    xcodebuild_log="$(mktemp "$derived_data_root/openburnbar-app-tests-log-XXXXXX")"

    # Assemble args for this attempt (per-attempt derived data + result bundle).
    populate_xcodebuild_args "$derived_data_dir" "$attempt_xcresult"

    attempt_start_epoch="$(date +%s)"
    set +e
    xcodebuild test "${xcodebuild_args[@]}" 2>&1 | tee "$xcodebuild_log"
    last_test_exit_code=${PIPESTATUS[0]}
    set -e
    attempt_end_epoch="$(date +%s)"
    attempt_duration=$((attempt_end_epoch - attempt_start_epoch))

    if [ "$last_test_exit_code" -eq 0 ]; then
        emit_attempt_event "$test_attempt" "$last_test_exit_code" "passed" "$attempt_duration" "$attempt_xcresult"
        final_exit_code=0
        final_outcome="passed"
        final_xcresult="$attempt_xcresult"
        break
    fi

    if is_known_hang "$xcodebuild_log"; then
        emit_attempt_event "$test_attempt" "$last_test_exit_code" "hang_retry" "$attempt_duration" "$attempt_xcresult"
        echo ">>> Detected known XCTest startup hang on attempt $test_attempt (exit $last_test_exit_code)."
        test_attempt=$((test_attempt + 1))
        continue
    fi

    # Real test failure — surface it immediately, no retry storm.
    emit_attempt_event "$test_attempt" "$last_test_exit_code" "test_failure" "$attempt_duration" "$attempt_xcresult"
    final_exit_code="$last_test_exit_code"
    final_outcome="test_failure"
    final_xcresult="$attempt_xcresult"
    break
done

# All retries exhausted without a real failure being surfaced — every attempt
# hit a hang. Treat as a hard failure; build-for-testing remains a compile
# safety net so we still detect Swift errors masked by host hangs.
if [ "$final_outcome" = "failed" ] && [ "$test_attempt" -gt "$max_test_attempts" ]; then
    final_exit_code="$last_test_exit_code"
    final_outcome="exhausted_retries"
    echo ">>> Exhausted $max_test_attempts attempts; running build-for-testing as compile safety net."
    populate_xcodebuild_args "$derived_data_dir" "$derived_data_dir/safety-net.xcresult"
    xcodebuild build-for-testing "${xcodebuild_args[@]}" || true
fi

# Promote the successful attempt's xcresult to the canonical coverage path so
# extract-coverage.sh / diff-coverage.sh have a stable input.
if [[ "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" && "$final_outcome" = "passed" && -d "$final_xcresult" ]]; then
    rm -rf "$canonical_xcresult_path"
    cp -R "$final_xcresult" "$canonical_xcresult_path"
    echo "Coverage xcresult promoted to $canonical_xcresult_path"
fi

invocation_end_epoch="$(date +%s)"
total_duration=$((invocation_end_epoch - invocation_start_epoch))
emit_summary_event "$final_outcome" "$test_attempt" "$total_duration" "$final_exit_code"

exit "$final_exit_code"
