#!/usr/bin/env bash
# SOTASIGNAL Phase E/F — Signal rollback drill (timed, dry-run by default).
#
# Invariant #10: final activation must be reversible in under 60 seconds via Remote
# Config + environment kill switches. This drill rehearses that path and TIMES the
# locally-verifiable steps. It is DRY-RUN by default: it prints the exact production
# commands and asserts the kill levers EXIST in code, but mutates no production
# state. Pass --live ONLY in an authorized ops session with the right project/creds.
#
# Steps rehearsed (in order):
#   1. RC disable signal_envelope_v4_enabled
#   2. Verify per-domain at-rest Signal rollback boundary
#   3. Set SIGNAL_ENVELOPE_V4_DISABLED for agents/clients/server capability
#   4. Keep dual-read OPEN (never delete Signal rows on rollback)
#   5. Re-run export/delete + rules tests to prove read-tolerance survived
#
# Usage: scripts/ops/signal-rollback-drill.sh [--live] [--evidence <dir>] [--cloudvault-evidence <path>]
set -euo pipefail
cd "$(dirname "$0")/../.."

LIVE="false"
EVIDENCE=""
CLOUDVAULT_EVIDENCE="${CLOUDVAULT_AT_REST_EVIDENCE:-launch-evidence/cloudvault-at-rest-runtime.json}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --live) LIVE="true"; shift ;;
    --evidence) EVIDENCE="$2"; shift 2 ;;
    --cloudvault-evidence) CLOUDVAULT_EVIDENCE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

start_epoch="$(date +%s)"
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
note() { echo "    -> $*"; }

fail=0
assert_code() {
  # assert_code <human> <grep-extended-regex> <file...>
  local human="$1"; shift
  local pat="$1"; shift
  if grep -REq "$pat" "$@" 2>/dev/null; then
    note "OK   kill lever present: $human"
  else
    note "MISS kill lever NOT found in code: $human"
    fail=$((fail + 1))
  fi
}

log "Signal rollback drill — mode=$([[ $LIVE == true ]] && echo LIVE || echo DRY-RUN)"

log "Step 1/5 — disable transport v4"
# HONEST STATUS: the `signal_envelope_v4_enabled` Remote Config key is a PLANNED
# Phase-E lever — it is read by ZERO runtime code today. The OPERATIVE current kill
# lever is the compile-time fail-closed default below (empty production version Set);
# reverting/keeping it empty is what actually stops new v4. Do not pretend the RC
# key works until a future PR wires it.
if grep -REq "signal_envelope_v4_enabled" functions/src 2>/dev/null; then
  note "RC signal_envelope_v4_enabled is wired — $([[ $LIVE == true ]] && echo 'operator sets it false' || echo '[dry-run] would set it false')"
else
  note "RC signal_envelope_v4_enabled is PLANNED (Phase E) — not yet read in functions/src; relying on the compile-time lever below"
fi
# The compile-time fail-closed default that is the REAL current kill lever:
assert_code "empty HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS (REAL current lever)" \
  "HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS *= *new Set<number>\\(\\)" functions/src/hermesGateway.ts

log "Step 2/5 — verify per-domain at-rest Signal rollback boundary"
if grep -Eq '"sealingScheme"\s*:\s*"[^"]*signal' packages/data-domains/registry.json 2>/dev/null; then
  if python3 scripts/ci/check_cloudvault_at_rest_runtime.py "$CLOUDVAULT_EVIDENCE" --repo-root . >/tmp/signal-rollback-cloudvault.log 2>&1; then
    note "OK   at-rest Signal domains are evidence-backed by $CLOUDVAULT_EVIDENCE"
    if [[ "$LIVE" == "true" ]]; then
      note "operator must revert the registry sealingScheme + redeploy rules for a full at-rest rollback"
    else
      note "[dry-run] full at-rest rollback would revert the registry sealingScheme + redeploy rules; transport rollback leaves existing Signal rows readable"
    fi
  else
    note "MISS registry has Signal at-rest domains but CloudVault evidence did not validate (see /tmp/signal-rollback-cloudvault.log)"
    fail=$((fail + 1))
  fi
else
  note "OK   no domain is on a Signal at-rest sealingScheme"
fi

log "Step 3/5 — set SIGNAL_ENVELOPE_V4_DISABLED for agents/clients/server capability"
# HONEST STATUS: SIGNAL_ENVELOPE_V4_DISABLED (L35) is a PLANNED env kill switch. Until
# a producer/capability path reads it, it is a no-op. The drill must NOT claim it works.
if grep -REq "SIGNAL_ENVELOPE_V4_DISABLED" functions/src 2>/dev/null; then
  note "SIGNAL_ENVELOPE_V4_DISABLED is wired — $([[ $LIVE == true ]] && echo 'operator exports =1 + redeploys' || echo '[dry-run] would export =1')"
else
  note "SIGNAL_ENVELOPE_V4_DISABLED is PLANNED (L35) — not yet read in functions/src; implement before relying on it in a live rollback"
fi

log "Step 4/5 — keep dual-read OPEN (do NOT delete Signal rows on rollback)"
note "policy assertion only: rollback never deletes Signal-sealed rows; legacy + Signal both stay readable"

log "Step 5/5 — re-run export/delete + rules read-tolerance proofs"
if [[ "$LIVE" == "true" || "${RUN_TESTS:-true}" == "true" ]]; then
  if command -v npm >/dev/null 2>&1; then
    note "running: npm run test:firestore-rules (read-tolerance + path-binding)"
    if (cd functions && npm run --silent test:firestore-rules >/tmp/signal-rollback-rules.log 2>&1); then
      note "OK   firestore rules suite passed post-rollback"
    else
      note "MISS firestore rules suite FAILED (see /tmp/signal-rollback-rules.log)"; fail=$((fail + 1))
    fi
  else
    note "npm unavailable; skipping test re-run (record manually)"
  fi
fi

end_epoch="$(date +%s)"
elapsed=$((end_epoch - start_epoch))
log "Drill complete in ${elapsed}s (kill-lever assertions: $([[ $fail -eq 0 ]] && echo PASS || echo \"FAIL x$fail\"))"

if [[ "$elapsed" -le 60 ]]; then
  log "Reversibility budget OK: rehearsed kill path within the 60s invariant (${elapsed}s)."
else
  log "NOTE: drill wall-clock ${elapsed}s exceeded 60s — but the 60s budget covers RC propagation, not the full local test re-run. Record RC-only timing separately in a live drill."
fi

if [[ -n "$EVIDENCE" ]]; then
  mkdir -p "$EVIDENCE"
  {
    echo "signal-rollback-drill"
    echo "mode=$([[ $LIVE == true ]] && echo live || echo dry-run)"
    echo "elapsed_seconds=$elapsed"
    echo "kill_lever_failures=$fail"
    echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$EVIDENCE/signal-rollback-drill.txt"
  note "evidence -> $EVIDENCE/signal-rollback-drill.txt"
fi

exit "$([[ $fail -eq 0 ]] && echo 0 || echo 1)"
