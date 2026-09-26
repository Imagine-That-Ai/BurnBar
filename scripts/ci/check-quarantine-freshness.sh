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
malformed=()
checked=0
table_cols=0

# Terminal (non-date) Target values: an entry carrying one of these is
# explicitly untracked. Anything else non-date on an entry row is a typo
# that would otherwise evade the gate, so it fails closed below.
terminal_target_re='^(Done|Archive|TBD|N/A|—|-)$'
separator_cell_re='^:?-+:?$'

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

  # Separator rows declare their table's width; strictness below is
  # relative to the enclosing table, so the 2-column totals table (which
  # has a backtick row of its own) never trips entry validation.
  is_separator=true
  for cell in "${cells[@]}"; do
    [[ "$(trim "$cell")" =~ $separator_cell_re ]] || { is_separator=false; break; }
  done
  if [[ "$is_separator" == true ]]; then
    table_cols="${#cells[@]}"
    continue
  fi

  # Entry-shaped rows (backtick test name) inside a 7-column entry table
  # must be well-formed: a typo'd row that silently skips the gate is
  # worse than no gate. Anything outside an entry table stays ignored.
  is_entry_row=false
  [[ "$table_cols" -eq 7 && "$(trim "$row")" == '`'* ]] && is_entry_row=true
  if [[ "$is_entry_row" == true && "${#cells[@]}" -ne 7 ]]; then
    malformed+=("entry row has ${#cells[@]} cells, want 7: $(trim "$line")")
    continue
  fi
  [[ "${#cells[@]}" -eq 7 ]] || continue

  name="$(trim "${cells[0]}")"
  status="$(trim "${cells[1]}")"
  target="$(trim "${cells[6]}")"

  # Skip the table header row.
  [[ "$name" == "Test Name" ]] && continue

  # LegacyReference / permanent entries are documentation-only: exempt.
  status_key="$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$status_key" in
    *legacyreference*|*permanent*) continue ;;
  esac

  # Only rows carrying a real Target Date are revival-tracked. Terminal
  # values ("Done", "Archive", "TBD", …) carry no date obligation; any
  # other non-date value on an entry row is a typo that fails closed.
  if [[ ! "$target" =~ $date_re ]]; then
    if [[ "$is_entry_row" == true && ! "$target" =~ $terminal_target_re ]]; then
      display="${name//\`/}"
      malformed+=("$display — unparseable Target Date '$target' (status: ${status:-unset}); use YYYY-MM-DD or a terminal value (Done/Archive/TBD)")
    fi
    continue
  fi

  checked=$((checked + 1))

  # ISO dates: compare as base-10 integers (YYYY-MM-DD -> YYYYMMDD).
  if (( 10#${target//-/} < 10#${today//-/} )); then
    display="${name//\`/}"
    overdue+=("$display — Target Date $target (status: ${status:-unset})")
  fi
done < "$manifest"

if [[ "${#malformed[@]}" -gt 0 ]]; then
  echo "FAIL: ${#malformed[@]} malformed quarantine manifest entr(ies) in $manifest:" >&2
  for entry in "${malformed[@]}"; do
    echo "  - $entry" >&2
  done
  echo >&2
  echo "Entry rows must be well-formed 7-cell rows with a YYYY-MM-DD Target" >&2
  echo "Date or an explicit terminal value (Done/Archive/TBD). Fix the row." >&2
  exit 1
fi

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
