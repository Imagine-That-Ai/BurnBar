#!/usr/bin/env bash
#
# test-openburnbar-mobile.sh — SOTA test driver for OpenBurnBarMobileTests (iOS Simulator).
#
# Mirrors retry/telemetry patterns from test-openburnbar-app.sh.
#
# Environment knobs:
#   OPENBURNBAR_ENABLE_COVERAGE=YES   Capture xcresult at canonical mobile coverage path.
#   OPENBURNBAR_MOBILE_TEST_ATTEMPTS=N   Override max attempts (default 4).
#   OPENBURNBAR_MOBILE_TEST_FILTER=...  Pass a custom -only-testing target.
#   OPENBURNBAR_MOBILE_SIMULATOR=...    Simulator name (default: iPhone 17 Pro Max).
#
# Exit status:
#   0  — tests passed
#   N  — final xcodebuild exit code

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cache_dir="$repo_root/.spm-cache-new"
artifact_root="$repo_root/.derived-data"
derived_data_root="${OPENBURNBAR_MOBILE_TEST_DERIVED_DATA_ROOT:-${TMPDIR:-/tmp}/openburnbar-mobile-tests}"
attempt_log_path="$artifact_root/test-openburnbar-mobile-attempts.jsonl"

default_test_execution_allowance="${OPENBURNBAR_MOBILE_TEST_DEFAULT_ALLOWANCE:-900}"
maximum_test_execution_allowance="${OPENBURNBAR_MOBILE_TEST_MAX_ALLOWANCE:-1800}"
max_test_attempts="${OPENBURNBAR_MOBILE_TEST_ATTEMPTS:-4}"
test_filter="${OPENBURNBAR_MOBILE_TEST_FILTER:-OpenBurnBarMobileTests}"
simulator_name="${OPENBURNBAR_MOBILE_SIMULATOR:-iPhone 17 Pro Max}"

mkdir -p "$cache_dir"
mkdir -p "$artifact_root"
mkdir -p "$derived_data_root"

derived_data_dir="$(mktemp -d "$derived_data_root/openburnbar-mobile-tests.XXXXXX")"
xcodebuild_log=""
xcodebuild_args=()
last_test_exit_code=0

emit_attempt_event() {
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
}

cleanup_derived_data() {
    local dd="$1"
    rm -rf "$dd" 2>/dev/null || true
}

cleanup() {
    if [ -n "$xcodebuild_log" ]; then
        rm -f "$xcodebuild_log" 2>/dev/null || true
    fi
    cleanup_derived_data "$derived_data_dir"
}

trap 'cleanup' EXIT

populate_xcodebuild_args() {
    local dd="$1"
    local attempt_result="$2"
    xcodebuild_args=(
        -project "$repo_root/OpenBurnBar.xcodeproj"
        -scheme "OpenBurnBarMobile"
        -destination "platform=iOS Simulator,name=${simulator_name}"
        -clonedSourcePackagesDirPath "$cache_dir"
        -derivedDataPath "$dd"
        -resultBundlePath "$attempt_result"
        -test-timeouts-enabled YES
        -default-test-execution-time-allowance "$default_test_execution_allowance"
        -maximum-test-execution-time-allowance "$maximum_test_execution_allowance"
        SWIFT_ENABLE_EXPLICIT_MODULES=NO
        SWIFT_COMPILATION_MODE=singlefile
        SWIFT_ENABLE_BATCH_MODE=NO
        CODE_SIGNING_ALLOWED=NO
        CODE_SIGNING_REQUIRED=NO
        -only-testing:"$test_filter"
    )
    if [[ "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" ]]; then
        xcodebuild_args+=(-enableCodeCoverage YES)
    fi
}

if [[ "${CI:-}" == "true" ]]; then
    export TEST_RUNNER_CI=true
fi
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    export TEST_RUNNER_GITHUB_ACTIONS=true
fi

canonical_xcresult_path="$artifact_root/OpenBurnBarMobile_TestCoverage.xcresult"
if [[ "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" ]]; then
    rm -rf "$canonical_xcresult_path"
fi

: > "$attempt_log_path"

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

backoff_seconds=(0 5 10 20 40)

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
        echo ">>> Mobile retry attempt $test_attempt of $max_test_attempts. Sleeping ${wait_for}s."
        sleep "$wait_for"
        if (( test_attempt % 2 == 1 )); then
            cleanup_derived_data "$derived_data_dir"
            derived_data_dir="$(mktemp -d "$derived_data_root/openburnbar-mobile-tests.XXXXXX")"
        fi
    fi

    attempt_xcresult="$derived_data_dir/OpenBurnBarMobileTests-attempt-$test_attempt.xcresult"
    xcodebuild_log="$(mktemp "$derived_data_root/openburnbar-mobile-tests-log-XXXXXX")"

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

    if is_known_hang "$xcodebuild_log" && [ "$test_attempt" -lt "$max_test_attempts" ]; then
        emit_attempt_event "$test_attempt" "$last_test_exit_code" "hang_retry" "$attempt_duration" "$attempt_xcresult"
        echo ">>> Known XCTest hang detected on mobile attempt $test_attempt; retrying."
        test_attempt=$((test_attempt + 1))
        continue
    fi

    emit_attempt_event "$test_attempt" "$last_test_exit_code" "failed" "$attempt_duration" "$attempt_xcresult"
    final_exit_code="$last_test_exit_code"
    final_outcome="failed"
    final_xcresult="$attempt_xcresult"
    break
done

if [[ -n "$final_xcresult" && "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" && "$final_outcome" == "passed" ]]; then
    rm -rf "$canonical_xcresult_path"
    cp -R "$final_xcresult" "$canonical_xcresult_path"
fi

invocation_end_epoch="$(date +%s)"
total_duration=$((invocation_end_epoch - $(date -r "$attempt_log_path" +%s 2>/dev/null || echo "$invocation_end_epoch")))
emit_summary_event "$final_outcome" "$test_attempt" "$total_duration" "$final_exit_code"

echo ">>> Mobile test summary: outcome=$final_outcome attempts=$test_attempt exit=$final_exit_code"
echo ">>> Telemetry: $attempt_log_path"

exit "$final_exit_code"
