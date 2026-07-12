#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$ROOT/scripts/linux-port/linux-swift-test-manifest.json"
RESULTS_DIR="${OPENBURNBAR_LINUX_SWIFT_TEST_RESULTS:-$ROOT/docs/linux-port/evidence/mission-001-release/linux-swift-tests}"
JOBS="${OPENBURNBAR_LINUX_SWIFT_TEST_JOBS:-4}"
SCRATCH_ROOT="${OPENBURNBAR_LINUX_SWIFT_SCRATCH_ROOT:-${TMPDIR:-/tmp}/openburnbar-linux-swift-tests}"
COVERAGE_ENABLED="${OPENBURNBAR_ENABLE_COVERAGE:-NO}"
COVERAGE_LCOV="${OPENBURNBAR_LINUX_COVERAGE_LCOV:-$RESULTS_DIR/linux-package-coverage.lcov}"
COVERAGE_LINES="${OPENBURNBAR_LINUX_COVERAGE_LINES:-$RESULTS_DIR/linux-package-coverage-lines.json}"

profile_dir="$SCRATCH_ROOT/coverage-profiles"
if [[ "$COVERAGE_ENABLED" == "YES" ]]; then
  rm -rf "$profile_dir"
  mkdir -p "$profile_dir"
  export LLVM_PROFILE_FILE="$profile_dir/%p.profraw"
elif [[ "$COVERAGE_ENABLED" != "NO" ]]; then
  echo "FAIL: OPENBURNBAR_ENABLE_COVERAGE must be YES or NO (got: $COVERAGE_ENABLED)" >&2
  exit 2
fi

cd "$ROOT"
mkdir -p "$RESULTS_DIR"
find "$RESULTS_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

python3 scripts/linux-port/verify_linux_swift_tests.test.py
python3 scripts/linux-port/verify_linux_swift_tests.py contract --root "$ROOT"

IFS=$'\t' read -r BUILD_TIMEOUT_SECONDS PER_TEST_TIMEOUT_SECONDS TERMINATION_GRACE_SECONDS < <(
  python3 - "$MANIFEST" <<'PY'
import json
import sys

execution = json.load(open(sys.argv[1], encoding="utf-8"))["execution"]
print("\t".join(str(execution[key]) for key in (
    "buildTimeoutSeconds", "perTestTimeoutSeconds", "terminationGraceSeconds"
)))
PY
)

while IFS=$'\t' read -r package_path description_file; do
  swift package \
    --package-path "$ROOT/$package_path" \
    describe \
    --type json > "$RESULTS_DIR/$description_file"
done < <(
  python3 - "$MANIFEST" <<'PY'
import json
import re
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
for package_path in sorted({suite["packagePath"] for suite in manifest["suites"]}):
    safe_path = re.sub(r"[^A-Za-z0-9_.-]+", "__", package_path)
    print(f"{package_path}\tgraph-{safe_path}.json")
PY
)

python3 scripts/linux-port/verify_linux_swift_tests.py \
  graph \
  --root "$ROOT" \
  --results-dir "$RESULTS_DIR"

while IFS=$'\t' read -r suite_id package_path filter minimum scratch_path; do
  log="$RESULTS_DIR/${suite_id}.log"
  xunit="$RESULTS_DIR/${suite_id}.xml"
  scratch="$SCRATCH_ROOT/$scratch_path"
  mkdir -p "$scratch"
  echo "==> Linux Swift suite: $suite_id ($filter, minimum $minimum)"
  set +e
  timeout --kill-after="${TERMINATION_GRACE_SECONDS}s" "${BUILD_TIMEOUT_SECONDS}s" swift build \
    --package-path "$ROOT/$package_path" \
    --scratch-path "$scratch" \
    --disable-automatic-resolution \
    --jobs "$JOBS" \
    --build-tests 2>&1 | tee "$log"
  status="${PIPESTATUS[0]}"
  set -e
  if [[ "$status" -ne 0 ]]; then
    echo "FAIL: Linux Swift suite $suite_id build exited $status; see $log" >&2
    exit "$status"
  fi

  bin_path="$(swift build \
    --package-path "$ROOT/$package_path" \
    --scratch-path "$scratch" \
    --disable-automatic-resolution \
    --show-bin-path)"
  mapfile -t xctest_binaries < <(find "$bin_path" -maxdepth 1 -type f -name '*PackageTests.xctest' -print)
  if [[ "${#xctest_binaries[@]}" -ne 1 ]]; then
    echo "FAIL: expected exactly one XCTest binary for $suite_id in $bin_path; found ${#xctest_binaries[@]}" >&2
    exit 1
  fi

  set +e
  python3 scripts/linux-port/verify_linux_swift_tests.py execute \
    --suite-id "$suite_id" \
    --filter "$filter" \
    --xctest-binary "${xctest_binaries[0]}" \
    --xunit-output "$xunit" \
    --per-test-timeout-seconds "$PER_TEST_TIMEOUT_SECONDS" \
    --termination-grace-seconds "$TERMINATION_GRACE_SECONDS" 2>&1 | tee -a "$log"
  status="${PIPESTATUS[0]}"
  set -e
  if [[ "$status" -ne 0 ]]; then
    echo "FAIL: Linux Swift suite $suite_id execution exited $status; see $log" >&2
    exit "$status"
  fi
done < <(
  python3 - "$MANIFEST" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
for suite in manifest["suites"]:
    print("\t".join(str(suite[key]) for key in (
        "id", "packagePath", "filter", "minimumExecutedTests", "scratchPath"
    )))
PY
)

if [[ "$COVERAGE_ENABLED" == "YES" ]]; then
  coverage_binaries=()
  while IFS=$'\t' read -r suite_id package_path scratch_path coverage_filter_index coverage_filter; do
    scratch="$SCRATCH_ROOT/$scratch_path"
    coverage_log="$RESULTS_DIR/${suite_id}-coverage-${coverage_filter_index}.log"
    coverage_xunit="$RESULTS_DIR/${suite_id}-coverage-${coverage_filter_index}.xml"

    if [[ "$coverage_filter_index" == "0" ]]; then
      echo "==> Linux Swift coverage build: $suite_id"
      timeout --kill-after="${TERMINATION_GRACE_SECONDS}s" "${BUILD_TIMEOUT_SECONDS}s" swift build \
        --package-path "$ROOT/$package_path" \
        --scratch-path "$scratch" \
        --disable-automatic-resolution \
        --jobs "$JOBS" \
        --enable-code-coverage \
        --build-tests 2>&1 | tee "$coverage_log"
    fi

    bin_path="$(swift build \
      --package-path "$ROOT/$package_path" \
      --scratch-path "$scratch" \
      --disable-automatic-resolution \
      --show-bin-path)"
    mapfile -t xctest_binaries < <(find "$bin_path" -maxdepth 1 -type f -name '*PackageTests.xctest' -print)
    if [[ "${#xctest_binaries[@]}" -ne 1 ]]; then
      echo "FAIL: expected exactly one coverage XCTest binary for $suite_id in $bin_path; found ${#xctest_binaries[@]}" >&2
      exit 1
    fi
    if [[ "$coverage_filter_index" == "0" ]]; then
      coverage_binaries+=("${xctest_binaries[0]}")
    fi

    echo "==> Linux Swift coverage filter: $coverage_filter"
    python3 scripts/linux-port/verify_linux_swift_tests.py execute \
      --suite-id "${suite_id}-coverage-${coverage_filter_index}" \
      --filter "$coverage_filter" \
      --xctest-binary "${xctest_binaries[0]}" \
      --xunit-output "$coverage_xunit" \
      --per-test-timeout-seconds "$PER_TEST_TIMEOUT_SECONDS" \
      --termination-grace-seconds "$TERMINATION_GRACE_SECONDS" 2>&1 | tee -a "$coverage_log"
  done < <(
    python3 - "$MANIFEST" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
for suite in manifest["suites"]:
    for index, coverage_filter in enumerate(suite.get("linuxCoverageFilters", [])):
        print("\t".join((
            suite["id"], suite["packagePath"], suite["scratchPath"], str(index), coverage_filter
        )))
PY
  )
fi

python3 scripts/linux-port/verify_linux_swift_tests.py \
  results \
  --root "$ROOT" \
  --results-dir "$RESULTS_DIR"

if [[ "$COVERAGE_ENABLED" == "YES" ]]; then
  if [[ "${#coverage_binaries[@]}" -eq 0 ]]; then
    echo "FAIL: Linux coverage run produced no XCTest bundles from coverage-owner builds" >&2
    exit 1
  fi
  "$ROOT/scripts/linux-port/export-linux-swift-coverage.sh" \
    "$profile_dir" "$COVERAGE_LCOV" "$COVERAGE_LINES" \
    "${coverage_binaries[@]}"
fi
