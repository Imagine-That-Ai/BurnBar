#!/usr/bin/env bash
# Wave 2.4: proves the daemon refuses to serve without the SQLCipher codec,
# like the app. Runs after the daemon Swift lane (which prepares the libsignal
# FFI and warms the daemon build cache), and standalone after any daemon build.
#
# 1. Static: the startup gate call must exist in OpenBurnBarDaemonMain, so a
#    refactor cannot silently drop the refusal.
# 2. Runtime: a DEBUG daemon binary with OPENBURNBAR_DAEMON_FORCE_NO_CODEC=1
#    (the DEBUG-only test hatch, compiled out of release builds) exits non-zero
#    with the typed codec error and binds no socket / creates no database.
# 3. Ordering: --help still works under the override (the gate runs after arg
#    parsing, before anything binds).
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

MAIN="OpenBurnBarDaemon/Sources/OpenBurnBarDaemonExecutable/OpenBurnBarDaemonMain.swift"
CIPHER="OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarDaemonDatabaseCipher.swift"

grep -Eq 'requireCodecForStartup\(\)' "$MAIN" \
  || fail "OpenBurnBarDaemonMain must call requireCodecForStartup()"
grep -Eq 'func requireCodecForStartup' "$CIPHER" \
  || fail "startup gate definition missing from BurnBarDaemonDatabaseCipher"

swift build --package-path OpenBurnBarDaemon --product OpenBurnBarDaemon \
  || fail "daemon DEBUG build failed"
BINARY="OpenBurnBarDaemon/.build/debug/OpenBurnBarDaemon"
[[ -x "$BINARY" ]] || fail "daemon binary missing at $BINARY"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SOCK="$WORK/daemon.sock"
DB="$WORK/index.sqlite"

HELP_OUT="$("$BINARY" --help 2>&1)" || fail "--help exited non-zero"
grep -q 'Usage: OpenBurnBarDaemon' <<<"$HELP_OUT" || fail "--help output unexpected"

set +e
GATE_OUT="$(OPENBURNBAR_DAEMON_FORCE_NO_CODEC=1 \
  OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN=codec-gate-test \
  "$BINARY" --socket-path "$SOCK" --index-database-path "$DB" 2>&1)"
CODE=$?
set -e
[[ "$CODE" -ne 0 ]] || fail "daemon with forced no-codec exited 0; must exit with an error"
grep -q 'SQLCipher codec unavailable' <<<"$GATE_OUT" \
  || fail "missing typed codec error (got: $GATE_OUT)"
[[ -e "$SOCK" ]] && fail "daemon bound a socket despite refusing to serve"
[[ -e "$DB" ]] && fail "daemon created a database despite refusing to serve"

echo "PASS: daemon codec startup gate proven (exit=$CODE, nothing bound or created)."
