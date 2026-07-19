#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
runner="$repo_root/scripts/test-openburnbar-mobile.sh"
explicit_destination="platform=iOS Simulator,id=00000000-0000-0000-0000-000000000042"
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
