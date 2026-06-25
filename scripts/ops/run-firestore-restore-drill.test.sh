#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

script="scripts/ops/run-firestore-restore-drill.sh"
pass=0
fail=0
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/firestore-drill-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

run_case() {
  local want="$1"
  local label="$2"
  shift 2
  local output="$tmp_root/${label}.out"
  local got
  set +e
  "$@" >"$output" 2>&1
  got=$?
  set -e
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1))
    printf '  ok   (exit %s) %s\n' "$got" "$label"
  else
    fail=$((fail + 1))
    printf '  FAIL (exit %s, want %s) %s\n' "$got" "$want" "$label" >&2
    cat "$output" >&2
  fi
}

echo "run-firestore-restore-drill timeout validation self-test"

run_case 0 valid-default-timeouts \
  env FIRESTORE_DRILL_VALIDATE_TIMEOUTS_ONLY=1 bash "$script"

run_case 0 valid-custom-timeouts \
  env FIRESTORE_DRILL_VALIDATE_TIMEOUTS_ONLY=1 \
    FIRESTORE_DRILL_CLEANUP_TIMEOUT_SECONDS=120 \
    FIRESTORE_DRILL_WAIT_TIMEOUT_SECONDS=3600 \
    FIRESTORE_DRILL_WAIT_POLL_SECONDS=5 \
    bash "$script"

run_case 64 arithmetic-expression-timeout-fails \
  env FIRESTORE_DRILL_VALIDATE_TIMEOUTS_ONLY=1 \
    FIRESTORE_DRILL_WAIT_TIMEOUT_SECONDS='1+1' \
    bash "$script"

run_case 64 zero-poll-timeout-fails \
  env FIRESTORE_DRILL_VALIDATE_TIMEOUTS_ONLY=1 \
    FIRESTORE_DRILL_WAIT_POLL_SECONDS=0 \
    bash "$script"

run_case 64 oversized-cleanup-timeout-fails \
  env FIRESTORE_DRILL_VALIDATE_TIMEOUTS_ONLY=1 \
    FIRESTORE_DRILL_CLEANUP_TIMEOUT_SECONDS=999999 \
    bash "$script"

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: ${fail} Firestore restore-drill timeout validation test(s) failed" >&2
  exit 1
fi

echo "PASS: ${pass} Firestore restore-drill timeout validation checks"
