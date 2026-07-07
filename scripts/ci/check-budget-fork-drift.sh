#!/usr/bin/env bash
#
# Budget fork drift gate (audit wave 4, item 4).
#
# BudgetGate was de-forked into OpenBurnBarCore (Budget/BudgetGate.swift): the two app
# trees keep only thin seam files (protocol conformances + a logging convenience init).
# This gate makes the de-fork durable and turns NEW drift in the remaining intentionally
# forked Budget pairs into a conscious, reviewed act:
#
#   1. Fails if a `BudgetGate.swift` reappears under AgentLens/ or OpenBurnBarMobile/
#      (the gate implementation lives only in OpenBurnBarCore).
#   2. Fails if either platform seam file grows beyond conformances + factory
#      (line budget: MAX_SEAM_LINES per file).
#   3. For each remaining intentionally-forked pair, computes a normalized diff
#      (comments, blank lines, and leading whitespace stripped) between the macOS and
#      iOS files and compares its sha256 against a checked-in baseline under
#      scripts/ci/budget-fork-baselines/. A changed hash means the pair drifted —
#      inspect the drift and regenerate the baseline in the same PR with `--update`.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

BASELINE_DIR="scripts/ci/budget-fork-baselines"
MAX_SEAM_LINES=120
UPDATE=0
if [[ "${1:-}" == "--update" ]]; then
  UPDATE=1
fi

fail=0

# ── 1. The de-fork holds: no BudgetGate.swift in either app tree ─────────────
stray_gates=()
while IFS= read -r path; do
  [[ -n "$path" ]] && stray_gates+=("$path")
done < <(git ls-files 'AgentLens/**/BudgetGate.swift' 'AgentLens/BudgetGate.swift' \
                      'OpenBurnBarMobile/**/BudgetGate.swift' 'OpenBurnBarMobile/BudgetGate.swift')
if [[ ${#stray_gates[@]} -gt 0 ]]; then
  echo "FAIL: BudgetGate.swift must live only in OpenBurnBarCore (Budget/BudgetGate.swift)." >&2
  echo "      The gate was de-forked in audit wave 4, item 4 — do not re-fork it:" >&2
  for path in "${stray_gates[@]}"; do
    echo "  - $path" >&2
  done
  fail=1
fi

if [[ ! -f "OpenBurnBarCore/Sources/OpenBurnBarCore/Budget/BudgetGate.swift" ]]; then
  echo "FAIL: OpenBurnBarCore/Sources/OpenBurnBarCore/Budget/BudgetGate.swift is missing." >&2
  echo "      The shared BudgetGate implementation must live in OpenBurnBarCore." >&2
  fail=1
fi

# ── 2. Seam files stay thin (conformances + factory only) ────────────────────
seam_files=(
  "AgentLens/Services/DataStore/BudgetGate+AgentLens.swift"
  "OpenBurnBarMobile/Models/BudgetGate+Mobile.swift"
)
for seam in "${seam_files[@]}"; do
  if [[ ! -f "$seam" ]]; then
    echo "FAIL: platform seam file is missing: $seam" >&2
    fail=1
    continue
  fi
  lines=$(wc -l < "$seam" | tr -d ' ')
  if [[ "$lines" -gt "$MAX_SEAM_LINES" ]]; then
    echo "FAIL: $seam has $lines lines (budget: $MAX_SEAM_LINES)." >&2
    echo "      Seam files hold ONLY protocol conformances + the platform logging factory." >&2
    echo "      Shared gate behavior belongs in OpenBurnBarCore/Sources/OpenBurnBarCore/Budget/BudgetGate.swift." >&2
    fail=1
  fi
done

# ── 3. Remaining intentional forks: normalized-diff hash baselines ───────────
# Strip //-comments, blank lines, and leading whitespace so formatting-only churn
# does not invalidate a baseline; hash the unified diff of the normalized pair.
normalize() {
  sed -e 's|//.*$||' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$' || true
}

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    shasum -a 256
  fi
}

pair_hash() {
  local mac_path="$1" ios_path="$2" diff_out
  # diff exits 1 when the sides differ — the normal case for a fork; only >=2 is trouble.
  diff_out=$(diff <(normalize "$mac_path") <(normalize "$ios_path") || [[ $? -eq 1 ]])
  printf '%s\n' "$diff_out" | sha256_stdin | awk '{print $1}'
}

check_pair() {
  local name="$1" mac_path="$2" ios_path="$3" note="$4"
  local baseline_file="$BASELINE_DIR/$name.sha256"

  for path in "$mac_path" "$ios_path"; do
    if [[ ! -f "$path" ]]; then
      echo "FAIL: forked pair '$name' is missing $path" >&2
      echo "      If the pair was de-forked or moved, update this gate and remove" >&2
      echo "      $baseline_file in the same PR." >&2
      fail=1
      return
    fi
  done

  local actual
  actual=$(pair_hash "$mac_path" "$ios_path")

  if [[ "$UPDATE" -eq 1 ]]; then
    mkdir -p "$BASELINE_DIR"
    printf '%s\n' "$actual" > "$baseline_file"
    echo "updated: $baseline_file"
    return
  fi

  if [[ ! -f "$baseline_file" ]]; then
    echo "FAIL: missing baseline $baseline_file for forked pair '$name'." >&2
    echo "      Run: bash scripts/ci/check-budget-fork-drift.sh --update" >&2
    fail=1
    return
  fi

  local expected
  expected=$(tr -d '[:space:]' < "$baseline_file")
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: budget fork pair '$name' drifted from its reviewed baseline." >&2
    echo "  macOS: $mac_path" >&2
    echo "  iOS:   $ios_path" >&2
    echo "  $note" >&2
    echo "  Inspect the pair drift (does the change belong on BOTH platforms, or in" >&2
    echo "  OpenBurnBarCore?), then regenerate the baseline in the same PR:" >&2
    echo "    bash scripts/ci/check-budget-fork-drift.sh --update" >&2
    fail=1
  fi
}

check_pair "BudgetEnforcement" \
  "AgentLens/Services/DataStore/BudgetEnforcement.swift" \
  "OpenBurnBarMobile/Models/BudgetEnforcement.swift" \
  "This pair is intentionally forked but expected to stay near-parallel; new one-sided edits are usually parity bugs."

check_pair "BudgetSettings" \
  "AgentLens/Services/DataStore/BudgetSettings.swift" \
  "OpenBurnBarMobile/Models/BudgetSettings.swift" \
  "This pair is intentionally forked but expected to stay near-parallel; new one-sided edits are usually parity bugs."

check_pair "BudgetLedger" \
  "AgentLens/Services/DataStore/BudgetLedger.swift" \
  "OpenBurnBarMobile/Models/BudgetLedger.swift" \
  "This pair is ARCHITECTURALLY divergent (macOS reads SQL token_usage; iOS reads synced rollups). The gate exists so NEW drift is a conscious, reviewed act — not to force convergence."

if [[ "$UPDATE" -eq 1 ]]; then
  if [[ "$fail" -ne 0 ]]; then
    echo "FAIL: baselines updated, but structural checks above still fail." >&2
    exit 1
  fi
  echo "PASS: budget fork baselines regenerated under $BASELINE_DIR/."
  exit 0
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

echo "PASS: BudgetGate is de-forked (Core-only) and all budget fork pairs match their reviewed baselines."
