#!/usr/bin/env bash
# Positive + negative controls for verify-windows-storage-prune-waiver.sh.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
CHECK="scripts/ci/verify-windows-storage-prune-waiver.sh"

tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

fail=0
casei=0

# run_case <expect pass|fail> <expect-substring> <workflows-dir> <waiver-doc> <now>
run_case() {
  local expect="$1" needle="$2" wfdir="$3" waiver="$4" now="$5"
  casei=$((casei + 1))
  local out rc=0
  out="$(WINDOWS_PRUNE_WORKFLOWS_DIR="$wfdir" \
         WINDOWS_PRUNE_WAIVER_DOC="$waiver" \
         WINDOWS_PRUNE_NOW="$now" \
         bash "$CHECK" 2>&1)" || rc=$?
  if [[ "$expect" == "pass" && "$rc" -ne 0 ]]; then
    echo "FAIL[case $casei]: expected PASS but exit=$rc" >&2
    echo "$out" >&2
    fail=1
    return
  fi
  if [[ "$expect" == "fail" && "$rc" -eq 0 ]]; then
    echo "FAIL[case $casei]: expected FAIL but exit=0" >&2
    echo "$out" >&2
    fail=1
    return
  fi
  if [[ -n "$needle" ]] && ! grep -qF "$needle" <<<"$out"; then
    echo "FAIL[case $casei]: output missing expected text: $needle" >&2
    echo "$out" >&2
    fail=1
    return
  fi
  echo "ok[case $casei]: expect=$expect needle=${needle:-<none>}"
}

# Fixture builders -------------------------------------------------------------
mk_pruning_wf() {
  local dir="$1" value="$2"
  mkdir -p "$dir"
  cat >"$dir/openburnbar-engine-windows.yml" <<EOF
name: engine
on: [workflow_dispatch]
env:
  OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD: "$value"
jobs:
  build:
    runs-on: windows-latest
    steps:
      - run: swift build
EOF
}

mk_valid_waiver() {
  local path="$1" status="$2" expires="$3" wf="$4"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<EOF
# waiver
<!-- BEGIN:windows-storage-prune-waiver -->
status: $status
expires: $expires
flag: OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD
tracking: docs/windows-port/HANDOFF.md
workflows:
  - $wf
<!-- END:windows-storage-prune-waiver -->
EOF
}

# ── Case 1: pruning + valid, unexpired, naming waiver -> PASS ──────────────────
wf1="$tmproot/c1/wf"
mk_pruning_wf "$wf1" "1"
mk_valid_waiver "$tmproot/c1/waiver.md" "active" "2999-01-01" \
  ".github/workflows/openburnbar-engine-windows.yml"
run_case pass "PASS" "$wf1" "$tmproot/c1/waiver.md" "2026-07-03"

# ── Case 2: pruning + NO waiver doc -> FAIL, names the workflow ────────────────
wf2="$tmproot/c2/wf"
mk_pruning_wf "$wf2" "1"
run_case fail "storage PRUNED" "$wf2" "$tmproot/c2/missing.md" "2026-07-03"

# ── Case 3: pruning + EXPIRED waiver -> FAIL ("EXPIRED") ───────────────────────
wf3="$tmproot/c3/wf"
mk_pruning_wf "$wf3" "1"
mk_valid_waiver "$tmproot/c3/waiver.md" "active" "2026-01-01" \
  ".github/workflows/openburnbar-engine-windows.yml"
run_case fail "EXPIRED" "$wf3" "$tmproot/c3/waiver.md" "2026-07-03"

# ── Case 4: pruning + status not active -> FAIL ───────────────────────────────
wf4="$tmproot/c4/wf"
mk_pruning_wf "$wf4" "true"
mk_valid_waiver "$tmproot/c4/waiver.md" "retired" "2999-01-01" \
  ".github/workflows/openburnbar-engine-windows.yml"
run_case fail "not 'active'" "$wf4" "$tmproot/c4/waiver.md" "2026-07-03"

# ── Case 5: pruning workflow NOT named by the waiver -> FAIL ───────────────────
wf5="$tmproot/c5/wf"
mk_pruning_wf "$wf5" "1"
mk_valid_waiver "$tmproot/c5/waiver.md" "active" "2999-01-01" \
  ".github/workflows/some-other-lane.yml"
run_case fail "does not name" "$wf5" "$tmproot/c5/waiver.md" "2026-07-03"

# ── Case 6: NOT pruning (flag=0) + no waiver -> PASS ───────────────────────────
wf6="$tmproot/c6/wf"
mk_pruning_wf "$wf6" "0"
run_case pass "NOT pruned" "$wf6" "$tmproot/c6/missing.md" "2026-07-03"

# ── Case 7: malformed waiver (two BEGIN markers) + pruning -> FAIL ─────────────
wf7="$tmproot/c7/wf"
mk_pruning_wf "$wf7" "1"
mk_valid_waiver "$tmproot/c7/waiver.md" "active" "2999-01-01" \
  ".github/workflows/openburnbar-engine-windows.yml"
# Duplicate the BEGIN marker to malform the block.
printf '<!-- BEGIN:windows-storage-prune-waiver -->\n' >>"$tmproot/c7/waiver.md"
run_case fail "exactly one BEGIN" "$wf7" "$tmproot/c7/waiver.md" "2026-07-03"

# ── Case 8: expression value (${{ ... }}) treated as pruning (fail-closed) ─────
wf8="$tmproot/c8/wf"
mkdir -p "$wf8"
cat >"$wf8/lane.yml" <<'EOF'
name: expr
on: [workflow_dispatch]
env:
  OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD: "${{ vars.PRUNE }}"
jobs:
  build:
    runs-on: windows-latest
    steps:
      - run: swift build
EOF
run_case fail "storage PRUNED" "$wf8" "$tmproot/c8/missing.md" "2026-07-03"

# ── Case 9: the REAL repo tree + committed waiver -> PASS ──────────────────────
casei=$((casei + 1))
if out="$(bash "$CHECK" 2>&1)"; then
  if grep -qF "PASS" <<<"$out"; then
    echo "ok[case $casei]: real repo tree passes with the committed waiver"
  else
    echo "FAIL[case $casei]: real check exit 0 but no PASS marker" >&2
    echo "$out" >&2
    fail=1
  fi
else
  echo "FAIL[case $casei]: real check FAILED against the committed tree" >&2
  echo "$out" >&2
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: verify-windows-storage-prune-waiver self-test had failures" >&2
  exit 1
fi
echo "PASS: verify-windows-storage-prune-waiver self-test ($casei cases)"
