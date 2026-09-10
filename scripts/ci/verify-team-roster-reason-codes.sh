#!/usr/bin/env bash
# Team-roster reason-code mirror gate (memory program D16 / P22).
#
# The nine team-roster callables attach a machine-readable `details.reason` to
# every refusal (`functions/src/teamRosterReasons.ts`) and the Mac app switches
# on it (`TeamRosterReasonCode` in
# `AgentLens/Services/CloudSync/TeamRosterDirectory.swift`). That replaced
# matching substrings of the server's English message, which was a text contract
# across a network boundary — but a shared enumeration maintained by hand on two
# sides in two languages is only a contract while something checks it.
#
# THE REPO HAD NO SUCH MECHANISM. There is no generated binding for these codes:
# `tools/schema-sync/` emits Firestore DOCUMENT schemas from TypeSpec, and the
# hand-maintained TS surface budget is at zero headroom, so adding the reason
# enumeration there was not available. The nearest precedent is
# `verify-team-memory-copy-inventory.sh`, which checks one hand-maintained Swift
# list against the declarations it claims to cover; this gate is the same idea
# across the two languages, and this comment is the honest statement of how it
# works rather than a claim that an emitter guarantees it.
#
# THREE CHECKS:
#   1. Every reason declared server-side has a Swift case with that raw value.
#      Without it a new server refusal reaches a shipped Mac as an unknown code
#      and degrades to generic copy, silently.
#   2. Every Swift case names a reason the server still declares. Without it the
#      client carries dead branches that look like handled cases in review.
#   3. Every declared reason is actually THROWN somewhere under functions/src.
#      A reason nothing raises is a claim, not a contract — and check 1 would
#      force the Swift side to mirror it anyway.
#
# Usage:
#   scripts/ci/verify-team-roster-reason-codes.sh
#   scripts/ci/verify-team-roster-reason-codes.sh --self-test
set -euo pipefail
cd "$(dirname "$0")/../.."

TS_SOURCE="functions/src/teamRosterReasons.ts"
SWIFT_SOURCE="AgentLens/Services/CloudSync/TeamRosterDirectory.swift"
THROW_ROOT="functions/src"

# Server-declared reasons: `KEY: { code: "...", reason: "KEY" },` one per line.
# The key and the reason must be the SAME string — a mismatch is reported rather
# than silently preferring one of them, because check 3 greps by key.
# sed, not awk: BSD awk has no capture groups, and this gate runs on developer
# Macs as well as on the Ubuntu runners.
declared_pairs() {
  sed -nE 's/^[[:space:]]*([A-Z_]+): [{] code: "[a-z-]+", reason: "([A-Z_]+)" [}],.*/\1 \2/p' "$1"
}

declared_reasons() {
  local key reason mismatch=0
  while read -r key reason; do
    [[ -n "$key" ]] || continue
    if [[ "$key" != "$reason" ]]; then
      echo "KEY/REASON MISMATCH: ${key} declares reason ${reason}" >&2
      mismatch=1
      continue
    fi
    echo "$key"
  done < <(declared_pairs "$1") | sort -u
  return "$mismatch"
}

# Client-mirrored reasons: `case someName = "REASON"` inside the enum.
mirrored_reasons() {
  sed -n '/^enum TeamRosterReasonCode: String/,/^}/p' "$1" |
    sed -nE 's/^[[:space:]]*case [A-Za-z0-9_]+ = "([A-Z_]+)".*/\1/p' | sort -u
}

check_pair() {
  local ts_file="$1" swift_file="$2" throw_root="${3:-}"
  local status=0

  for file in "$ts_file" "$swift_file"; do
    if [[ ! -f "$file" ]]; then
      echo "verify-team-roster-reason-codes: missing $file" >&2
      return 2
    fi
  done

  local declared mirrored
  declared="$(declared_reasons "$ts_file")" || return 2
  mirrored="$(mirrored_reasons "$swift_file")"

  if [[ -z "$declared" ]]; then
    echo "verify-team-roster-reason-codes: no reasons found in $ts_file" >&2
    return 2
  fi
  if [[ -z "$mirrored" ]]; then
    echo "verify-team-roster-reason-codes: no TeamRosterReasonCode cases found in $swift_file" >&2
    return 2
  fi

  local missing extra
  missing="$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$mirrored"))"
  extra="$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$mirrored"))"

  if [[ -n "$missing" ]]; then
    status=1
    while IFS= read -r reason; do
      [[ -n "$reason" ]] && echo "MISSING from TeamRosterReasonCode: ${reason}" >&2
    done <<<"$missing"
  fi
  if [[ -n "$extra" ]]; then
    status=1
    while IFS= read -r reason; do
      [[ -n "$reason" ]] && echo "UNKNOWN to the server, still mirrored in Swift: ${reason}" >&2
    done <<<"$extra"
  fi

  # Check 3 is skipped when no throw root is given (the self-test fixtures have
  # no call sites); the real run always passes one.
  if [[ -n "$throw_root" ]]; then
    while IFS= read -r reason; do
      [[ -n "$reason" ]] || continue
      if ! grep -rqE "REASON\.${reason}([^A-Z_]|$)" "$throw_root" --include='*.ts'; then
        status=1
        echo "DECLARED BUT NEVER RAISED: ${reason} (no REASON.${reason} under ${throw_root})" >&2
      fi
    done <<<"$declared"
  fi

  return "$status"
}

if [[ "${1:-scan}" == "--self-test" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  cat >"$tmp/good.ts" <<'TS'
export const TEAM_ROSTER_REASON = {
  ALPHA: { code: "not-found", reason: "ALPHA" },
  BETA: { code: "failed-precondition", reason: "BETA" },
} as const satisfies Record<string, TeamRosterRefusal>;
TS
  cat >"$tmp/good.swift" <<'SWIFT'
enum TeamRosterReasonCode: String {
    case alpha = "ALPHA"
    case beta = "BETA"
}
SWIFT
  cat >"$tmp/missing.swift" <<'SWIFT'
enum TeamRosterReasonCode: String {
    case alpha = "ALPHA"
}
SWIFT
  cat >"$tmp/extra.swift" <<'SWIFT'
enum TeamRosterReasonCode: String {
    case alpha = "ALPHA"
    case beta = "BETA"
    case gamma = "GAMMA"
}
SWIFT
  cat >"$tmp/mismatch.ts" <<'TS'
export const TEAM_ROSTER_REASON = {
  ALPHA: { code: "not-found", reason: "ALFA" },
} as const satisfies Record<string, TeamRosterRefusal>;
TS

  if ! check_pair "$tmp/good.ts" "$tmp/good.swift"; then
    echo "SELF-TEST FAILED: a matching pair of enumerations was rejected" >&2
    exit 1
  fi
  if check_pair "$tmp/good.ts" "$tmp/missing.swift" 2>/dev/null; then
    echo "SELF-TEST FAILED: a server code with no Swift case was not detected" >&2
    exit 1
  fi
  if check_pair "$tmp/good.ts" "$tmp/extra.swift" 2>/dev/null; then
    echo "SELF-TEST FAILED: a Swift case with no server code was not detected" >&2
    exit 1
  fi
  if check_pair "$tmp/mismatch.ts" "$tmp/good.swift" 2>/dev/null; then
    echo "SELF-TEST FAILED: a key/reason mismatch was not detected" >&2
    exit 1
  fi
  # Check 3, on a throw root that raises neither reason.
  mkdir -p "$tmp/src"
  echo 'throw rosterError(REASON.ALPHA, "alpha");' >"$tmp/src/only-alpha.ts"
  if check_pair "$tmp/good.ts" "$tmp/good.swift" "$tmp/src" 2>/dev/null; then
    echo "SELF-TEST FAILED: a declared-but-never-raised reason was not detected" >&2
    exit 1
  fi
  echo 'throw rosterError(REASON.BETA, "beta");' >"$tmp/src/beta.ts"
  if ! check_pair "$tmp/good.ts" "$tmp/good.swift" "$tmp/src"; then
    echo "SELF-TEST FAILED: fully-raised reasons were rejected" >&2
    exit 1
  fi

  echo "verify-team-roster-reason-codes: self-test OK"
  exit 0
fi

if check_pair "$TS_SOURCE" "$SWIFT_SOURCE" "$THROW_ROOT"; then
  count="$(declared_reasons "$TS_SOURCE" | wc -l | tr -d ' ')"
  echo "verify-team-roster-reason-codes: OK — ${count} reason codes, server and Swift agree, all raised"
else
  status=$?
  if [[ "$status" == "2" || "$status" == "3" ]]; then exit "$status"; fi
  echo "" >&2
  echo "The server's reason enumeration (${TS_SOURCE}) and the client's mirror" >&2
  echo "(${SWIFT_SOURCE}) must match exactly, and every declared reason must be raised." >&2
  exit 1
fi
