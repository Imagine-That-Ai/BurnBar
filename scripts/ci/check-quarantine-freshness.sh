#!/usr/bin/env bash
#
# R-GH8: Quarantine revival freshness gate.
#
# Every quarantined/archived test tracked in
# AgentLensTests/Quarantine/QUARANTINE_MANIFEST.md carries a revival "Target Date"
# (YYYY-MM-DD). This gate fails when any date-tracked entry is *past due* — its
# Target Date is strictly before today — so revival milestones cannot silently
# rot. Entries whose Status is "LegacyReference" (or "permanent") are
# documentation-only per ADR and have no revival obligation, so they are exempt.
#
# Usage:
#   scripts/ci/check-quarantine-freshness.sh [MANIFEST_PATH]
#
# Env:
#   AS_OF=YYYY-MM-DD   Override "today" (for tests / reproducible checks).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

manifest="${1:-AgentLensTests/Quarantine/QUARANTINE_MANIFEST.md}"

date_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'

# Resolve "today". AS_OF makes the check deterministic for tests and CI reruns.
if [[ -n "${AS_OF:-}" ]]; then
  today="$AS_OF"
else
  today="$(date +%Y-%m-%d)"
fi

if [[ ! "$today" =~ $date_re ]]; then
  echo "FAIL: AS_OF must be YYYY-MM-DD, got: '$today'" >&2
  exit 2
fi

if [[ ! -f "$manifest" ]]; then
  echo "FAIL: quarantine manifest not found: $manifest" >&2
  exit 1
fi

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

overdue=()
checked=0

while IFS= read -r line || [[ -n "$line" ]]; do
  row="$(trim "$line")"

  # Only bordered markdown table rows ("| ... |").
  [[ "$row" == \|*\| ]] || continue

  # Strip the outer pipes, then split the interior on '|'. Stripping first
  # normalizes away the empty leading/trailing fields (and any trailing
  # whitespace), so a well-formed manifest entry always yields 7 cells.
  row="${row#|}"
  row="${row%|}"
  IFS='|' read -r -a cells <<< "$row"
  [[ "${#cells[@]}" -eq 7 ]] || continue

  name="$(trim "${cells[0]}")"
  status="$(trim "${cells[1]}")"
  target="$(trim "${cells[6]}")"

  # Skip the table header row.
  [[ "$name" == "Test Name" ]] && continue

  # Only rows carrying a real Target Date are revival-tracked. "Done",
  # "Archive", "—", separators, etc. carry no date obligation.
  [[ "$target" =~ $date_re ]] || continue

  # LegacyReference / permanent entries are documentation-only: exempt.
  status_key="$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$status_key" in
    *legacyreference*|*permanent*) continue ;;
  esac

  checked=$((checked + 1))

  # ISO dates: compare as base-10 integers (YYYY-MM-DD -> YYYYMMDD).
  if (( 10#${target//-/} < 10#${today//-/} )); then
    display="${name//\`/}"
    overdue+=("$display — Target Date $target (status: ${status:-unset})")
  fi
done < "$manifest"

if [[ "${#overdue[@]}" -gt 0 ]]; then
  echo "FAIL: ${#overdue[@]} quarantined test(s) past revival Target Date (as of $today):" >&2
  for entry in "${overdue[@]}"; do
    echo "  - $entry" >&2
  done
  echo >&2
  echo "Resolve each by one of: revive the test into AgentLensTests/Active/ (prove it" >&2
  echo "with ./scripts/test-openburnbar-app.sh), push the Target Date out with a" >&2
  echo "justification, or reclassify it as LegacyReference per ADR in $manifest." >&2
  exit 1
fi

echo "PASS: $checked date-tracked quarantine entr(ies) within revival Target Date (as of $today)."
