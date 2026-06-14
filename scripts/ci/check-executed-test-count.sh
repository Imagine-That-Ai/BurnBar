#!/usr/bin/env bash
# Guard against the "Executed 0 tests" false-green.
#
# OpenBurnBar's Xcode project has no synced groups: a new test file that is not
# added to its target's project.pbxproj membership compiles to nothing and the
# bundle runs zero tests while the lane stays green. This asserts the app
# xcresult actually recorded executed tests, so a silently-empty run fails CI.
#
# Usage:
#   scripts/ci/check-executed-test-count.sh <xcresult> [--min N]   # default N=1
set -euo pipefail

XCRESULT="${1:?usage: check-executed-test-count.sh <xcresult> [--min N]}"
shift || true
MIN=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --min) MIN="${2:?--min needs a value}"; shift 2 ;;
    --min=*) MIN="${1#*=}"; shift ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -d "$XCRESULT" ]] || { echo "FAIL: xcresult bundle not found: $XCRESULT" >&2; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo "FAIL: xcrun is required to read xcresult." >&2; exit 1; }

# Prefer the Xcode 16+ structured summary; fall back to the legacy record on
# older toolchains. Either way we only need the total executed-test count.
MODE="summary"
RESULTS_JSON="$(xcrun xcresulttool get test-results summary --path "$XCRESULT" --format json 2>/dev/null || true)"
if [[ -z "$RESULTS_JSON" ]]; then
  MODE="legacy"
  RESULTS_JSON="$(xcrun xcresulttool get --path "$XCRESULT" --format json --legacy 2>/dev/null \
    || xcrun xcresulttool get --path "$XCRESULT" --format json 2>/dev/null || true)"
fi
[[ -n "$RESULTS_JSON" ]] || { echo "FAIL: could not read test results from $XCRESULT" >&2; exit 1; }

RESULTS_JSON_FILE="$(mktemp "${TMPDIR:-/tmp}/openburnbar-xcresult-summary.XXXXXX")"
trap 'rm -f "$RESULTS_JSON_FILE"' EXIT
printf '%s' "$RESULTS_JSON" > "$RESULTS_JSON_FILE"

MIN="$MIN" MODE="$MODE" python3 - "$XCRESULT" "$RESULTS_JSON_FILE" <<'PY'
import json, os, sys

xcresult = sys.argv[1]
json_path = sys.argv[2]
min_total = int(os.environ["MIN"])
mode = os.environ["MODE"]
with open(json_path, encoding="utf-8") as handle:
    data = json.load(handle)

if mode == "summary":
    # Xcode 16+: { "totalTestCount": N, "passedTests": .., "failedTests": .., ... }
    total = int(data.get("totalTestCount") or 0)
else:
    # Legacy ActionsInvocationRecord: { "metrics": { "testsCount": { "_value": "N" } } }
    metrics = data.get("metrics", {}) or {}
    total = int((metrics.get("testsCount", {}) or {}).get("_value") or 0)

if total < min_total:
    print(
        f"FAIL: {xcresult} recorded {total} executed tests (< required {min_total}).\n"
        "      This is the 'Executed 0 tests' false-green — verify the test target's\n"
        "      project.pbxproj membership (no synced groups in this project).",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"PASS: app xcresult recorded {total} executed tests (>= {min_total}).")
PY
