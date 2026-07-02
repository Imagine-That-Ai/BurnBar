#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
watchdog="$repo_root/scripts/ci/release-command-watchdog.py"

python3 "$watchdog" --mode test-success --outer-timeout-seconds 5 -- /bin/echo ok

set +e
python3 "$watchdog" --mode test-timeout --outer-timeout-seconds 1 -- /bin/sleep 10
timeout_status=$?
set -e

if [[ "$timeout_status" -ne 124 ]]; then
  echo "FAIL: expected watchdog timeout exit 124, got $timeout_status" >&2
  exit 1
fi

echo "PASS: release command watchdog self-test"
