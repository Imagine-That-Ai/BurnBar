#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ "$#" -eq 1 ]] || fail "expected one release-binary path"
BINARY="$1"
[[ -f "$BINARY" && -x "$BINARY" ]] || fail "release binary missing or not executable: $BINARY"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$BINARY" --help > "$WORK/help" 2>&1 || fail "release binary --help exited non-zero"
grep -F 'Usage: OpenBurnBarDaemon' "$WORK/help" > /dev/null || fail "release binary --help output unexpected"

if grep -F -e 'gateway-allow-unauthenticated-loopback' -e 'debugOnlyArgument' "$WORK/help" > /dev/null; then
  fail "release help exposes a debug-only escape hatch"
fi

strings "$BINARY" > "$WORK/strings" || fail "release binary strings inspection failed"
if grep -F 'OPENBURNBAR_DAEMON_FORCE_NO_CODEC' "$WORK/strings" > /dev/null; then
  fail "release binary retains the debug-only codec override"
fi

echo "PASS: release binary exists, executes and excludes debug-only escape hatches."
