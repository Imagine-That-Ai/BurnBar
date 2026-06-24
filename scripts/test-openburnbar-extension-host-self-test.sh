#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=scripts/test-openburnbar-extension-host.sh
source "$repo_root/scripts/test-openburnbar-extension-host.sh"

assert_attempts() {
  local raw="$1"
  local expected="$2"
  local actual
  actual="$(OPENBURNBAR_EXTENSION_HOST_ATTEMPTS="$raw" parse_extension_host_attempts)"
  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: expected attempts ${expected}, got ${actual} for '${raw}'" >&2
    exit 1
  fi
}

assert_rejected() {
  local raw="$1"
  if OPENBURNBAR_EXTENSION_HOST_ATTEMPTS="$raw" parse_extension_host_attempts >/dev/null 2>&1; then
    echo "ERROR: expected retry count '${raw}' to be rejected." >&2
    exit 1
  fi
}

assert_attempts 1 1
assert_attempts 3 3
assert_attempts 999 999

assert_rejected 0
assert_rejected 1000
assert_rejected -1
assert_rejected '1+1'
assert_rejected '3; echo unsafe'

echo "PASS: extension-host retry count self-test"
