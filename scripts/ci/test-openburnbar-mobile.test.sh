#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
runner="$repo_root/scripts/test-openburnbar-mobile.sh"
explicit_destination="platform=iOS Simulator,id=<IOS_DEVICE_ID>"
sentinel_name="OpenBurnBar Explicit Destination Regression Sentinel"

output="$({
  OPENBURNBAR_IOS_DESTINATION="$explicit_destination" \
    OPENBURNBAR_MOBILE_SIMULATOR="$sentinel_name" \
    OPENBURNBAR_MOBILE_DRY_RUN=1 \
    "$runner"
} 2>&1)"

if ! grep -Fqx "$explicit_destination" <<<"$output"; then
  echo "FAIL: explicit simulator destination was not preserved" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

if grep -Fq "platform=iOS Simulator,name=$sentinel_name" <<<"$output"; then
  echo "FAIL: explicit simulator destination was replaced by the fallback name" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

echo "PASS: explicit mobile test destinations survive simulator fallback resolution."

source "$repo_root/scripts/lib/openburnbar-app-test-classifier.sh"
fixture="$(mktemp)"
trap 'rm -f "$fixture"' EXIT
printf '%s\n' \
  'The test runner failed to initialize for UI testing. (Underlying Error: Timed out while enabling automation mode.)' \
  > "$fixture"

if ! is_known_hang "$fixture"; then
  echo "FAIL: physical-device UI automation setup timeout was not retryable" >&2
  exit 1
fi

echo "PASS: physical-device UI automation setup timeouts are retried."
