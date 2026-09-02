#!/usr/bin/env bash
#
# test-openburnbar-app.sh — SOTA test driver for the OpenBurnBar Xcode app target.
#
# Responsibilities:
#   1. Pre-clean stale OpenBurnBar / xctest host processes before each attempt
#      so we never inherit a half-dead runner from a prior crash.
#   2. Run xcodebuild test against the OpenBurnBarTests bundle with per-attempt
#      isolated derived data and result bundles.
#   3. Run process-global-state-sensitive tests in a fresh host and merge their
#      result bundle into the canonical coverage evidence.
#   4. Detect known XCTest startup hang families and retry with exponential
#      backoff (4 attempts). Real test failures fail fast — no retry storms.
#   5. Emit structured JSONL telemetry per attempt + a final summary so failures
#      are diagnosable without scrolling 5 MB of xcodebuild noise.
#   6. Promote the successful attempt's xcresult to the canonical coverage path
#      when OPENBURNBAR_ENABLE_COVERAGE=YES.
#
# Environment knobs:
#   OPENBURNBAR_ENABLE_COVERAGE=YES   Capture xcresult at canonical path.
#   OPENBURNBAR_APP_TEST_ATTEMPTS=N   Override max attempts (default 4).
#   OPENBURNBAR_APP_TEST_FILTER=...   Pass one custom -only-testing target.
#   OPENBURNBAR_APP_TEST_FILTERS=...  Pass newline/comma/semicolon-separated
#                                      -only-testing targets in one xcodebuild
#                                      invocation. CLI -only-testing arguments
#                                      take precedence over both env knobs.
#                                      `AgentLensTests/...` is accepted as a
#                                      stable alias for `OpenBurnBarTests/...`.
#   OPENBURNBAR_APP_ISOLATED_TEST_ATTEMPTS=N
#                                      Override fresh-host retry attempts for
#                                      isolation-sensitive tests (default 2).
#   OPENBURNBAR_APP_TEST_DERIVED_DATA_ROOT=...
#                                      Override runnable derived-data root.
#   OPENBURNBAR_APP_TEST_DERIVED_DATA_DIR=...
#                                      Reuse this exact prebuilt directory and
#                                      leave it in place on exit; the caller
#                                      owns it. Intended for CI steps that
#                                      already built the app for a real-process
#                                      gate on the same runner, and for local
#                                      iteration where a cold rebuild per run
#                                      costs more than the disk.
#
# Exit status:
#   0  — at least one attempt completed all tests successfully.
#   N  — the final xcodebuild exit code from the last failing attempt.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# Keep CI/package resolution on the source-built Firestore graph. The prebuilt
# grpc-binary path is unsafe for iOS 27 and can be reintroduced by Xcode package
# resolution unless the environment is present.
export FIREBASE_SOURCE_FIRESTORE="${FIREBASE_SOURCE_FIRESTORE:-1}"

cache_dir="$repo_root/.spm-cache-new"
artifact_root="$repo_root/.derived-data"

# shellcheck source=scripts/lib/openburnbar-app-test-classifier.sh
source "$repo_root/scripts/lib/openburnbar-app-test-classifier.sh"

# Keep runnable app/test-host products out of the repo's Documents path. macOS
# can launch test hosts via launchd/testmanagerd, and those child processes do
# not always inherit the caller's TCC grant for Documents, which can wedge dyld
# before XCTest starts. Repo-local artifacts remain under .derived-data.
if [[ -n "${OPENBURNBAR_APP_TEST_DERIVED_DATA_ROOT:-}" ]]; then
    derived_data_root="$OPENBURNBAR_APP_TEST_DERIVED_DATA_ROOT"
elif [[ -n "${OPENBURNBAR_SNAPSHOT_RECORD:-}" || "${OPENBURNBAR_RUN_SNAPSHOT_TESTS:-}" == "YES" ]]; then
    derived_data_root="${TMPDIR:-/tmp}/openburnbar-snapshot-tests"
else
    derived_data_root="${TMPDIR:-/tmp}/openburnbar-app-tests"
fi
attempt_log_path="$artifact_root/test-openburnbar-app-attempts.jsonl"

# Test runner timeouts (seconds). Defensive guards against hung individual
# test methods or stuck setup. Real CI overrides these via env if needed.
default_test_execution_allowance="${OPENBURNBAR_APP_TEST_DEFAULT_ALLOWANCE:-600}"
maximum_test_execution_allowance="${OPENBURNBAR_APP_TEST_MAX_ALLOWANCE:-1200}"

# Retry budget. Default 4 — the XCTest runner-connect race typically clears
# after process cleanup + fresh derived data; if it hasn't cleared by attempt
# 4, the failure is real.
max_test_attempts="${OPENBURNBAR_APP_TEST_ATTEMPTS:-4}"
max_isolated_test_attempts="${OPENBURNBAR_APP_ISOLATED_TEST_ATTEMPTS:-2}"

# Test filter. Default to the active app test bundle. Callers can override
# (e.g. for targeted snapshot re-records: -only-testing:OpenBurnBarTests/SomeClass).
# The source folder is AgentLensTests, but the XCTest bundle is OpenBurnBarTests.
# Normalize the folder-name alias so repeated manual/agent invocations do not
# fail with "AgentLensTests isn't a member of the specified test plan or scheme."
normalize_app_test_filter() {
    local candidate="$1"
    case "$candidate" in
        AgentLensTests)
            printf '%s\n' "OpenBurnBarTests"
            ;;
        AgentLensTests/*)
            printf '%s\n' "OpenBurnBarTests/${candidate#AgentLensTests/}"
            ;;
        *)
            printf '%s\n' "$candidate"
            ;;
    esac
}

usage() {
    cat <<'EOF'
Usage: scripts/test-openburnbar-app.sh [options]

Options:
  -only-testing:<target>       Run a specific XCTest bundle/class/method.
                               May be repeated.
  -only-testing <target>       Same as above.
  --print-xcodebuild-filters   Print normalized filters and exit.
  --print-xcodebuild-plan      Print the main/fresh-host filter plan and exit.
  -h, --help                  Show this help.

Environment:
  OPENBURNBAR_APP_TEST_FILTER=<target>
      Default test filter when -only-testing is not supplied.
  OPENBURNBAR_APP_TEST_FILTERS=<targets>
      Newline/comma/semicolon-separated default filters when -only-testing is
      not supplied. Takes precedence over OPENBURNBAR_APP_TEST_FILTER.
EOF
}

cli_test_filters=()
print_xcodebuild_filters=0
print_xcodebuild_plan=0
set_cli_test_filter() {
    local value="$1"
    if [[ -z "$value" ]]; then
        echo "error: -only-testing requires a non-empty target" >&2
        exit 64
    fi
    cli_test_filters+=("$value")
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -only-testing:*)
            set_cli_test_filter "${1#-only-testing:}"
            shift
            ;;
        -only-testing)
            shift
            if [[ "$#" -eq 0 ]]; then
                echo "error: -only-testing requires a target" >&2
                exit 64
            fi
            set_cli_test_filter "$1"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --print-xcodebuild-filters)
            print_xcodebuild_filters=1
            shift
            ;;
        --print-xcodebuild-plan)
            print_xcodebuild_plan=1
            shift
            ;;
        *)
            echo "error: unsupported argument '$1'" >&2
            usage >&2
            exit 64
            ;;
    esac
done

raw_test_filters=()
if ((${#cli_test_filters[@]})); then
    raw_test_filters=("${cli_test_filters[@]}")
elif [[ -n "${OPENBURNBAR_APP_TEST_FILTERS:-}" ]]; then
    while IFS= read -r raw_filter; do
        raw_filter="${raw_filter#"${raw_filter%%[![:space:]]*}"}"
        raw_filter="${raw_filter%"${raw_filter##*[![:space:]]}"}"
        if [[ -n "$raw_filter" ]]; then
            raw_test_filters+=("$raw_filter")
        fi
    done < <(printf '%s\n' "$OPENBURNBAR_APP_TEST_FILTERS" | tr ',;' '\n\n')
else
    raw_test_filters=("${OPENBURNBAR_APP_TEST_FILTER:-OpenBurnBarTests}")
fi

if ((${#raw_test_filters[@]} == 0)); then
    echo "error: no app test filters resolved" >&2
    exit 64
fi

test_filters=()
for raw_test_filter in "${raw_test_filters[@]}"; do
    test_filter="$(normalize_app_test_filter "$raw_test_filter")"
    if [[ "$test_filter" != "$raw_test_filter" ]]; then
        echo ">>> Normalized app test filter from '$raw_test_filter' to '$test_filter'."
    fi
    test_filters+=("$test_filter")
done

isolated_test_filters=(
    "OpenBurnBarTests/MediaSessionCoordinatorTests/testActiveScreenShareStopsWhenAdmissionIsRevoked"
    "OpenBurnBarTests/MediaSessionCoordinatorTests/testStartScreenShareRollsBackAfterCaptureStartFailureAndCanRetry"
    "OpenBurnBarTests/MemoryActivationEndToEndTests"
    "OpenBurnBarTests/MemoryCitationJumpThreadResolutionTests"
    "OpenBurnBarTests/MemoryCloudSyncDomainTests"
    "OpenBurnBarTests/MemoryDropTelemetryTests"
    "OpenBurnBarTests/ProjectionChunkerTests"
    "OpenBurnBarTests/ProjectionPipelineServiceTests"
    "OpenBurnBarTests/ProjectionPipelineServiceMattersTests"
    "OpenBurnBarTests/ProjectionStoreLifecycleTests"
)
isolated_test_expected_count=138
main_skip_test_filters=()
run_isolated_test_phase=0
if ((${#test_filters[@]} == 1)) && [[ "${test_filters[0]}" == "OpenBurnBarTests" ]]; then
    # These tests pass together in a fresh host but are contaminated by
    # process-global media/StoreKit/GRDB state after the monolithic run.
    # Keep the complete state-sensitive memory, citation, cloud-sync, and
    # projection surfaces mandatory in one clean XCTest process so newly added
    # tests cannot inherit that state.
    main_skip_test_filters=("${isolated_test_filters[@]}")
    run_isolated_test_phase=1
fi

if [[ "$print_xcodebuild_filters" == "1" ]]; then
    printf '%s\n' "${test_filters[@]}"
    exit 0
fi

if [[ "$print_xcodebuild_plan" == "1" ]]; then
    for filter in "${test_filters[@]}"; do
        printf 'main-only\t%s\n' "$filter"
    done
    if [[ "$run_isolated_test_phase" == "1" ]]; then
        for filter in "${main_skip_test_filters[@]}"; do
            printf 'main-skip\t%s\n' "$filter"
        done
        for filter in "${isolated_test_filters[@]}"; do
            printf 'fresh-host-only\t%s\n' "$filter"
        done
        printf 'fresh-host-expected-count\t%s\n' "$isolated_test_expected_count"
    fi
    exit 0
fi

mkdir -p "$cache_dir"
mkdir -p "$artifact_root"
mkdir -p "$derived_data_root"

# Per-invocation state. An exact reuse directory lets a preceding CI build seed
# the product and dependency objects; xcodebuild still compiles the test bundle
# and evaluates the full test action before execution.
create_derived_data_dir() {
    if [[ -n "${OPENBURNBAR_APP_TEST_DERIVED_DATA_DIR:-}" ]]; then
        mkdir -p "$OPENBURNBAR_APP_TEST_DERIVED_DATA_DIR"
        printf '%s\n' "$OPENBURNBAR_APP_TEST_DERIVED_DATA_DIR"
    else
        mktemp -d "$derived_data_root/openburnbar-app-tests.XXXXXX"
    fi
}

derived_data_dir="$(create_derived_data_dir)"
# A caller-pinned directory belongs to the caller. Deleting it on exit made the
# reuse path above single-use: the seeded objects it exists to preserve were
# gone before the next invocation could read them, so every run paid a cold
# build. Retry refreshes still wipe it, which is what a refresh is for.
derived_data_is_caller_owned="$([[ -n "${OPENBURNBAR_APP_TEST_DERIVED_DATA_DIR:-}" ]] && echo yes || echo no)"
xcodebuild_log=""
xcodebuild_args=()
last_test_exit_code=0
invocation_start_epoch="$(date +%s)"

# ---------------------------------------------------------------------------
# Telemetry
# ---------------------------------------------------------------------------

# Failure diagnostics that must survive cleanup. Attempt xcresults live inside
# the derived-data dir, which is deleted both by odd-numbered retry refreshes
# and by the EXIT trap — long before CI's artifact upload step runs. When a
# test hangs, XCTest attaches the hung process's thread backtraces to that
# attempt's xcresult, so losing the bundle makes a 10-minute hang undiagnosable
# from the streamed log alone. Copy every non-passing attempt's bundle here.
diagnostics_dir="$artifact_root/test-openburnbar-app-diagnostics"

preserve_diagnostic_xcresult() {
    # Args: xcresult_path
    local bundle="$1"
    [ -d "$bundle" ] || return 0
    mkdir -p "$diagnostics_dir"
    local dest
    dest="$diagnostics_dir/$(basename "$bundle")"
    rm -rf "$dest"
    cp -R "$bundle" "$dest" 2>/dev/null || true
    # Announce it. The bundle surviving cleanup is only useful if the person
    # reading the failure knows it exists; without this line the natural move is
    # to re-run the whole suite just to capture output that was already saved.
    [ -d "$dest" ] && echo "  ↳ failure diagnostics preserved: $dest" >&2
    return 0
}

emit_attempt_event() {
    # Args: attempt exit_code outcome duration_seconds xcresult_path
    local attempt="$1"
    local exit_code="$2"
    local outcome="$3"
    local duration="$4"
    local xcresult_path="$5"
    case "$outcome" in
        passed|xcode_false_negative_passed|isolated_passed) ;;
        *) preserve_diagnostic_xcresult "$xcresult_path" ;;
    esac
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
            sleep "$((delay_tenths / 10)).$((delay_tenths % 10))"
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
    if [ "$derived_data_is_caller_owned" = "yes" ]; then
        echo "Keeping caller-pinned derived data: $derived_data_dir" >&2
        return 0
    fi
    cleanup_derived_data "$derived_data_dir"
}

trap 'cleanup' EXIT

# ---------------------------------------------------------------------------
# xcodebuild argument assembly
# ---------------------------------------------------------------------------

populate_xcodebuild_args() {
    # Populates the global `xcodebuild_args` array in place.
    # Args: derived_data attempt_xcresult phase
    local dd="$1"
    local attempt_result="$2"
    local phase="${3:-main}"
    # xcodebuild refuses to start when -resultBundlePath already exists. A
    # caller-pinned derived-data directory survives the run, so every bundle the
    # previous invocation wrote (main attempts, fresh-host attempts, the merge)
    # is still sitting there. Clearing here covers every phase, because every
    # phase reaches xcodebuild through this function. The failing bundle has
    # already been copied into the diagnostics directory by
    # `preserve_diagnostic_xcresult`, so this drops a duplicate, not evidence.
    rm -rf "$attempt_result"
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
        SWIFT_ENABLE_EXPLICIT_MODULES=NO
        SWIFT_COMPILATION_MODE=singlefile
        SWIFT_ENABLE_BATCH_MODE=NO
        CODE_SIGNING_ALLOWED=NO
        CODE_SIGNING_REQUIRED=NO
    )
    if [[ "$phase" == "isolated" ]]; then
        for filter in "${isolated_test_filters[@]}"; do
            xcodebuild_args+=("-only-testing:$filter")
        done
    else
        for filter in "${test_filters[@]}"; do
            xcodebuild_args+=("-only-testing:$filter")
        done
        if [[ "$run_isolated_test_phase" == "1" ]]; then
            for filter in "${main_skip_test_filters[@]}"; do
                xcodebuild_args+=("-skip-testing:$filter")
            done
        fi
    fi
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
    if [[ "${TEST_RUNNER_OPENBURNBAR_SKIP_SNAPSHOTS:-}" == "true" ]]; then
        # Exported TEST_RUNNER_* values are not forwarded consistently by
        # every Xcode/macOS test-host combination. Pass the guard as an
        # explicit test-runner build setting so the normal full-suite gate
        # cannot wedge while opening source-tree snapshot references.
        xcodebuild_args+=("TEST_RUNNER_OPENBURNBAR_SKIP_SNAPSHOTS=true")
    fi
}

if [[ "${CI:-}" == "true" ]]; then
    export TEST_RUNNER_CI=true
fi
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    export TEST_RUNNER_GITHUB_ACTIONS=true
fi
if [[ -n "${RUNNER_OS:-}" ]]; then
    export TEST_RUNNER_RUNNER_OS="${RUNNER_OS}"
fi
if [[ -z "${OPENBURNBAR_SNAPSHOT_RECORD:-}" && "${OPENBURNBAR_RUN_SNAPSHOT_TESTS:-}" != "YES" ]]; then
    # Visual snapshot rendering can wedge under the full macOS app-test host on
    # some Xcode/macOS pairs. The normal app gate matches GitHub by skipping
    # snapshots; local snapshot audits stay available on demand.
    export TEST_RUNNER_OPENBURNBAR_SKIP_SNAPSHOTS=true
fi

# Canonical coverage xcresult location consumed by extract-coverage.sh
canonical_xcresult_path="$artifact_root/OpenBurnBar_TestCoverage.xcresult"
if [[ "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" ]]; then
    rm -rf "$canonical_xcresult_path"
fi

validate_fresh_host_xcresult() {
    local xcresult_path="$1"
    local expected_count="$isolated_test_expected_count"

    xcrun xcresulttool get test-results summary \
        --path "$xcresult_path" \
        --format json |
        python3 -c '
import json
import sys

expected = int(sys.argv[1])
summary = json.load(sys.stdin)
actual = int(summary.get("totalTestCount", 0))
passed = int(summary.get("passedTests", 0))
failed = int(summary.get("failedTests", 0))
result = summary.get("result")
if actual != expected or passed != expected or failed != 0 or result != "Passed":
    print(
        "error: fresh-host xcresult did not record the exact mandatory test set "
        f"(expected={expected}, actual={actual}, passed={passed}, failed={failed}, result={result})",
        file=sys.stderr,
    )
    raise SystemExit(1)
' "$expected_count"
}

# Truncate the per-invocation telemetry stream so each fresh run is self-
# contained for diagnostics. Append-only within the run. The preserved-xcresult
# diagnostics directory is reset for the same reason.
: > "$attempt_log_path"
rm -rf "$diagnostics_dir"

"$repo_root/scripts/lib/prepare-signal-ffi-xcframework.sh"

# ---------------------------------------------------------------------------
# Hang detection
# ---------------------------------------------------------------------------

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
        echo ">>> Retry attempt $test_attempt of $max_test_attempts after retryable XCTest/SwiftPM infrastructure failure. Sleeping ${wait_for}s."
        sleep "$wait_for"
        if (( test_attempt % 2 == 1 )); then
            echo ">>> Refreshing derived data for attempt $test_attempt."
            cleanup_derived_data "$derived_data_dir"
            derived_data_dir="$(create_derived_data_dir)"
        else
            echo ">>> Reusing derived data for attempt $test_attempt (warm-cache retry)."
        fi
    fi

    preclean_stale_processes

    attempt_xcresult="$derived_data_dir/OpenBurnBarTests-attempt-$test_attempt.xcresult"
    xcodebuild_log="$(mktemp "$derived_data_root/openburnbar-app-tests-log-XXXXXX")"

    # Assemble args for this attempt (per-attempt derived data + result bundle).
    populate_xcodebuild_args "$derived_data_dir" "$attempt_xcresult" main

    attempt_start_epoch="$(date +%s)"
    set +e
    xcodebuild test "${xcodebuild_args[@]}" 2>&1 | tee "$xcodebuild_log"
    last_test_exit_code=${PIPESTATUS[0]}
    set -e
    attempt_end_epoch="$(date +%s)"
    attempt_duration=$((attempt_end_epoch - attempt_start_epoch))

    if openburnbar_app_test_has_terminal_concrete_xctest_failure "$xcodebuild_log"; then
        emit_attempt_event "$test_attempt" "$last_test_exit_code" "test_failure" "$attempt_duration" "$attempt_xcresult"
        echo ">>> Detected concrete XCTest failure in xcodebuild log; failing attempt even though xcodebuild exited $last_test_exit_code."
        final_exit_code="$last_test_exit_code"
        if [ "$final_exit_code" -eq 0 ]; then
            final_exit_code=65
        fi
        final_outcome="test_failure"
        final_xcresult="$attempt_xcresult"
        break
    fi

    if [ "$last_test_exit_code" -eq 0 ]; then
        emit_attempt_event "$test_attempt" "$last_test_exit_code" "passed" "$attempt_duration" "$attempt_xcresult"
        final_exit_code=0
        final_outcome="passed"
        final_xcresult="$attempt_xcresult"
        break
    fi

    if is_xcode_false_negative_pass "$xcodebuild_log"; then
        emit_attempt_event "$test_attempt" "$last_test_exit_code" "xcode_false_negative_passed" "$attempt_duration" "$attempt_xcresult"
        echo ">>> xcodebuild exited $last_test_exit_code after XCTest reported Selected tests passed with 0 failures; accepting attempt as passed."
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

    if is_swiftpm_dependency_resolution_transient "$xcodebuild_log"; then
        emit_attempt_event "$test_attempt" "$last_test_exit_code" "swiftpm_dependency_retry" "$attempt_duration" "$attempt_xcresult"
        echo ">>> Detected transient SwiftPM dependency resolution failure on attempt $test_attempt (exit $last_test_exit_code)."
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
    populate_xcodebuild_args "$derived_data_dir" "$derived_data_dir/safety-net.xcresult" main
    xcodebuild build-for-testing "${xcodebuild_args[@]}" || true
fi

# The default full-bundle run keeps state-sensitive tests out of the long-lived
# host, then executes them against the same built products in a clean XCTest
# process. Both phases must pass, and their result bundles are merged into the
# canonical evidence artifact consumed by test-count and coverage gates.
if [[ "$final_outcome" == "passed" && "$run_isolated_test_phase" == "1" ]]; then
    main_xcresult="$final_xcresult"
    isolated_attempt=1
    isolated_passed=0
    isolated_xcresult=""

    while [[ "$isolated_attempt" -le "$max_isolated_test_attempts" ]]; do
        if [[ "$isolated_attempt" -gt 1 ]]; then
            echo ">>> Retrying fresh-host tests (attempt $isolated_attempt of $max_isolated_test_attempts)."
            sleep 5
        fi

        preclean_stale_processes
        isolated_xcresult="$derived_data_dir/OpenBurnBarTests-fresh-host-attempt-$isolated_attempt.xcresult"
        if [[ -n "$xcodebuild_log" ]]; then
            rm -f "$xcodebuild_log" 2>/dev/null || true
        fi
        xcodebuild_log="$(mktemp "$derived_data_root/openburnbar-app-isolated-log-XXXXXX")"
        populate_xcodebuild_args "$derived_data_dir" "$isolated_xcresult" isolated

        isolated_start_epoch="$(date +%s)"
        set +e
        xcodebuild test-without-building "${xcodebuild_args[@]}" 2>&1 | tee "$xcodebuild_log"
        isolated_exit_code=${PIPESTATUS[0]}
        set -e
        isolated_end_epoch="$(date +%s)"
        isolated_duration=$((isolated_end_epoch - isolated_start_epoch))

        if openburnbar_app_test_has_terminal_concrete_xctest_failure "$xcodebuild_log"; then
            emit_attempt_event "$isolated_attempt" "$isolated_exit_code" "isolated_test_failure" "$isolated_duration" "$isolated_xcresult"
            final_exit_code="$isolated_exit_code"
            if [[ "$final_exit_code" -eq 0 ]]; then
                final_exit_code=65
            fi
            final_outcome="isolated_test_failure"
            break
        fi

        if [[ "$isolated_exit_code" -eq 0 ]] || is_xcode_false_negative_pass "$xcodebuild_log"; then
            if validate_fresh_host_xcresult "$isolated_xcresult"; then
                emit_attempt_event "$isolated_attempt" "$isolated_exit_code" "isolated_passed" "$isolated_duration" "$isolated_xcresult"
                isolated_passed=1
                break
            fi

            emit_attempt_event "$isolated_attempt" 65 "isolated_evidence_failure" "$isolated_duration" "$isolated_xcresult"
            final_exit_code=65
            final_outcome="isolated_evidence_failure"
            break
        fi

        if is_known_hang "$xcodebuild_log" || is_swiftpm_dependency_resolution_transient "$xcodebuild_log"; then
            emit_attempt_event "$isolated_attempt" "$isolated_exit_code" "isolated_infrastructure_retry" "$isolated_duration" "$isolated_xcresult"
            isolated_attempt=$((isolated_attempt + 1))
            continue
        fi

        emit_attempt_event "$isolated_attempt" "$isolated_exit_code" "isolated_test_failure" "$isolated_duration" "$isolated_xcresult"
        final_exit_code="$isolated_exit_code"
        if [[ "$final_exit_code" -eq 0 ]]; then
            final_exit_code=65
        fi
        final_outcome="isolated_test_failure"
        break
    done

    if [[ "$isolated_passed" == "1" ]]; then
        merged_xcresult="$derived_data_dir/OpenBurnBarTests-merged.xcresult"
        rm -rf "$merged_xcresult"
        if xcrun xcresulttool merge --output-path "$merged_xcresult" "$main_xcresult" "$isolated_xcresult"; then
            final_xcresult="$merged_xcresult"
            echo ">>> Main-suite and fresh-host xcresults merged at $merged_xcresult"
        else
            echo "error: failed to merge main-suite and fresh-host xcresults" >&2
            final_exit_code=65
            final_outcome="xcresult_merge_failure"
        fi
    elif [[ "$final_outcome" == "passed" ]]; then
        echo "error: fresh-host test attempts exhausted without a passing result" >&2
        final_exit_code="${isolated_exit_code:-65}"
        if [[ "$final_exit_code" -eq 0 ]]; then
            final_exit_code=65
        fi
        final_outcome="isolated_exhausted_retries"
    fi
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
