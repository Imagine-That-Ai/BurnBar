#!/usr/bin/env bash
#
# R-P1 subprocessor-disclosure guard.
#
# Every third-party data subprocessor that a hosted egress site in
# functions/src actually reaches MUST be disclosed in the subprocessor /
# third-party table in docs/PRIVACY.md. This keeps the user-facing privacy
# doc in sync with where BurnBar Cloud sends data (fail-closed).
#
# The check is a deliberately simple name-list cross-check with two layers:
#
#   1. The curated rows below pair an egress-evidence marker with the name the
#      PRIVACY.md table must disclose. The marker is either an operator-held
#      `defineSecret("<NAME>")` API key, or a hostname / SDK-import substring
#      in the functions source. If the marker is present in the code, the
#      disclosure is REQUIRED — a missing table row fails the check.
#
#   2. Drift guard: every operator-held `*_API_KEY` secret declared via
#      `defineSecret(...)` in functions/src must map to one of the curated
#      rows. A new provider API key nobody disclosed fails the check, so a
#      fresh hosted egress destination cannot slip past the list.
#
# When you add a new hosted egress destination, add a row here AND a row to
# the table in docs/PRIVACY.md.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PRIVACY_DOC="${SUBPROC_PRIVACY_DOC:-${ROOT_DIR}/docs/PRIVACY.md}"
EGRESS_DIR="${SUBPROC_EGRESS_DIR:-${ROOT_DIR}/functions/src}"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$PRIVACY_DOC" ]] || fail "privacy doc not found: ${PRIVACY_DOC}"
[[ -d "$EGRESS_DIR" ]] || fail "egress source dir not found: ${EGRESS_DIR}"

# Curated subprocessor rows: "<name>|<evidence>|<data shared>".
# <evidence> is "secret:NAME" (an operator-held defineSecret API key) or
# "code:MARKER" (a hostname or SDK-import substring, matched case-insensitively).
# No field may contain a literal "|".
SUBPROCESSORS=(
  'Perplexity|secret:PERPLEXITY_API_KEY|hosted Fusion web-search query text'
  'Tavily|secret:TAVILY_API_KEY|hosted Fusion web-search query text (fallback)'
  'OpenRouter|secret:OPENROUTER_API_KEY|Intelligence Brief question + bounded usage digest'
  'MiniMax|code:minimax|default hosted Intelligence Brief model (via OpenRouter)'
  'Amplitude|secret:AMPLITUDE_API_KEY|opt-in product-analytics events'
  'Sentry|code:sentry|opt-in anonymized crash reports'
  'Stripe|code:from "stripe"|subscription billing + webhook processing'
  'Firebase|code:firebase-admin|auth, Firestore, Functions, Secret Manager'
  'OpenTimestamps|code:OpenTimestamps|32-byte audit-chain hash'
)

# --- collect egress source files (exclude test files/dirs) -----------------
EGRESS_FILES=()
while IFS= read -r file; do
  EGRESS_FILES+=("$file")
done < <(find "$EGRESS_DIR" -type f \( -name '*.ts' -o -name '*.js' \) \
  ! -path '*/__tests__/*' ! -name '*.test.ts' ! -name '*.test.js' | sort)
[[ "${#EGRESS_FILES[@]}" -gt 0 ]] || fail "no egress source files under ${EGRESS_DIR}"

# --- markdown table rows from the privacy doc (lines beginning with "|") ----
TABLE_ROWS="$(grep -E '^[[:space:]]*\|' "$PRIVACY_DOC" || true)"
[[ -n "$TABLE_ROWS" ]] || fail "no markdown table rows found in ${PRIVACY_DOC}"

evidence_present() {
  # $1 = evidence spec ("secret:NAME" | "code:MARKER").
  local spec="$1" kind val
  kind="${spec%%:*}"
  val="${spec#*:}"
  case "$kind" in
    secret) grep -lF -- "defineSecret(\"${val}\")" "${EGRESS_FILES[@]}" >/dev/null 2>&1 ;;
    code) grep -liF -- "$val" "${EGRESS_FILES[@]}" >/dev/null 2>&1 ;;
    *) fail "unknown evidence kind '${kind}' (expected secret: or code:)" ;;
  esac
}

disclosed() {
  # $1 = subprocessor display name; must appear in a PRIVACY.md table row.
  printf '%s\n' "$TABLE_ROWS" | grep -qiF -- "$1"
}

# --- layer 1: each live egress site must be disclosed ----------------------
missing=()
skipped=()
verified=()
known_secrets=""
for row in "${SUBPROCESSORS[@]}"; do
  IFS='|' read -r name evidence shared <<<"$row"
  if [[ "$evidence" == secret:* ]]; then
    known_secrets="${known_secrets} ${evidence#secret:}"
  fi
  if evidence_present "$evidence"; then
    if disclosed "$name"; then
      verified+=("$name")
    else
      missing+=("${name} (egress ${evidence}; shares: ${shared})")
    fi
  else
    skipped+=("${name} (no egress evidence ${evidence})")
  fi
done

# --- layer 2: no operator-held *_API_KEY may go unmapped -------------------
unmapped=()
while IFS= read -r secret; do
  [[ -n "$secret" ]] || continue
  case " ${known_secrets} " in
    *" ${secret} "*) : ;;
    *) unmapped+=("$secret") ;;
  esac
done < <(grep -hoE 'defineSecret\("[A-Z0-9_]+_API_KEY"\)' "${EGRESS_FILES[@]}" \
  | grep -oE '[A-Z0-9_]+_API_KEY' | sort -u)

# --- report ----------------------------------------------------------------
status=0
if [[ "${#missing[@]}" -gt 0 ]]; then
  status=1
  {
    echo "Undisclosed data subprocessors — egress is live in functions/src but no"
    echo "matching row exists in the ${PRIVACY_DOC##*/} subprocessor table:"
    for entry in "${missing[@]}"; do echo "  - ${entry}"; done
  } >&2
fi
if [[ "${#unmapped[@]}" -gt 0 ]]; then
  status=1
  {
    echo "Operator-held provider API keys with no disclosed subprocessor mapping"
    echo "(add a row to $(basename "${BASH_SOURCE[0]}") AND to ${PRIVACY_DOC##*/}):"
    for entry in "${unmapped[@]}"; do echo "  - defineSecret(\"${entry}\")"; done
  } >&2
fi
[[ "$status" -eq 0 ]] || fail "subprocessor disclosure is out of sync with hosted egress sites."

echo "PASS: all ${#verified[@]} live egress subprocessor(s) are disclosed in ${PRIVACY_DOC##*/}."
echo "  verified: ${verified[*]}"
if [[ "${#skipped[@]}" -gt 0 ]]; then
  echo "  note: ${#skipped[@]} curated subprocessor(s) have no current egress evidence (not required):"
  for entry in "${skipped[@]}"; do echo "    - ${entry}"; done
fi
