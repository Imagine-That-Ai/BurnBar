#!/usr/bin/env bash
# Positive + negative controls for verify-windows-storage-architecture.sh.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
CHECK="scripts/ci/verify-windows-storage-architecture.sh"

tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

fail=0
casei=0

# run_case <expect pass|fail> <expect-substring> <workflows-dir> <wpd-doc>
run_case() {
  local expect="$1" needle="$2" wfdir="$3" wpd="$4"
  casei=$((casei + 1))
  local out rc=0
  out="$(WINDOWS_STORAGE_WORKFLOWS_DIR="$wfdir" \
         WINDOWS_STORAGE_WPD_DOC="$wpd" \
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

mk_storage_tests() {
  local dir="$1"
  mkdir -p "$dir"
  printf '<Project Sdk="Microsoft.NET.Sdk" />\n' >"$dir/Fake.Storage.Tests.csproj"
  printf 'public class FakeTests { }\n' >"$dir/FakeTests.cs"
}

mk_valid_wpd() {
  local path="$1" status="$2" tests_dir="$3" wf="$4"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<EOF
# WPD-0005 twin
<!-- BEGIN:windows-storage-architecture -->
status: $status
flag: OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD
storage-tests: $tests_dir
workflows:
  - $wf
<!-- END:windows-storage-architecture -->
EOF
}

# ── Case 1: flag set + valid accepted WPD naming the lane + tests -> PASS ─────
wf1="$tmproot/c1/wf"
mk_pruning_wf "$wf1" "1"
mk_storage_tests "$tmproot/c1/tests"
mk_valid_wpd "$tmproot/c1/wpd.md" "accepted" "$tmproot/c1/tests" \
  ".github/workflows/openburnbar-engine-windows.yml"
run_case pass "PASS" "$wf1" "$tmproot/c1/wpd.md"

# ── Case 2: flag set + NO WPD doc -> FAIL, names the workflow ──────────────────
wf2="$tmproot/c2/wf"
mk_pruning_wf "$wf2" "1"
run_case fail "architecture decision is missing" "$wf2" "$tmproot/c2/missing.md"

# ── Case 3: flag set + status not accepted -> FAIL ─────────────────────────────
wf3="$tmproot/c3/wf"
mk_pruning_wf "$wf3" "true"
mk_storage_tests "$tmproot/c3/tests"
mk_valid_wpd "$tmproot/c3/wpd.md" "proposed" "$tmproot/c3/tests" \
  ".github/workflows/openburnbar-engine-windows.yml"
run_case fail "not 'accepted'" "$wf3" "$tmproot/c3/wpd.md"

# ── Case 4: flag-setting workflow NOT named by the WPD block -> FAIL ───────────
wf4="$tmproot/c4/wf"
mk_pruning_wf "$wf4" "1"
mk_storage_tests "$tmproot/c4/tests"
mk_valid_wpd "$tmproot/c4/wpd.md" "accepted" "$tmproot/c4/tests" \
  ".github/workflows/some-other-lane.yml"
run_case fail "does not name" "$wf4" "$tmproot/c4/wpd.md"

# ── Case 5: NOT pruning (flag=0) + no WPD doc -> PASS ──────────────────────────
wf5="$tmproot/c5/wf"
mk_pruning_wf "$wf5" "0"
run_case pass "No workflow sets" "$wf5" "$tmproot/c5/missing.md"

# ── Case 6: malformed block (two BEGIN markers) + flag set -> FAIL ─────────────
wf6="$tmproot/c6/wf"
mk_pruning_wf "$wf6" "1"
mk_storage_tests "$tmproot/c6/tests"
mk_valid_wpd "$tmproot/c6/wpd.md" "accepted" "$tmproot/c6/tests" \
  ".github/workflows/openburnbar-engine-windows.yml"
# Duplicate the BEGIN marker to malform the block.
printf '<!-- BEGIN:windows-storage-architecture -->\n' >>"$tmproot/c6/wpd.md"
run_case fail "exactly one BEGIN" "$wf6" "$tmproot/c6/wpd.md"

# ── Case 7: expression value (${{ ... }}) treated as flag-set (fail-closed) ────
wf7="$tmproot/c7/wf"
mkdir -p "$wf7"
cat >"$wf7/lane.yml" <<'EOF'
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
run_case fail "architecture decision is missing" "$wf7" "$tmproot/c7/missing.md"

# ── Case 8: storage-tests dir missing -> FAIL ──────────────────────────────────
wf8="$tmproot/c8/wf"
mk_pruning_wf "$wf8" "1"
mk_valid_wpd "$tmproot/c8/wpd.md" "accepted" "$tmproot/c8/no-such-tests" \
  ".github/workflows/openburnbar-engine-windows.yml"
run_case fail "does not exist" "$wf8" "$tmproot/c8/wpd.md"

# ── Case 9: storage-tests dir exists but holds no tests -> FAIL ────────────────
wf9="$tmproot/c9/wf"
mk_pruning_wf "$wf9" "1"
mkdir -p "$tmproot/c9/tests"  # empty: no .csproj, no *Tests.cs
mk_valid_wpd "$tmproot/c9/wpd.md" "accepted" "$tmproot/c9/tests" \
  ".github/workflows/openburnbar-engine-windows.yml"
run_case fail "does not look like a test project" "$wf9" "$tmproot/c9/wpd.md"

# ── Case 10: block missing storage-tests field -> FAIL ─────────────────────────
wf10="$tmproot/c10/wf"
mk_pruning_wf "$wf10" "1"
mkdir -p "$tmproot/c10"
cat >"$tmproot/c10/wpd.md" <<'EOF'
# WPD-0005 twin (no storage-tests)
<!-- BEGIN:windows-storage-architecture -->
status: accepted
flag: OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD
workflows:
  - .github/workflows/openburnbar-engine-windows.yml
<!-- END:windows-storage-architecture -->
EOF
run_case fail "missing 'storage-tests:'" "$wf10" "$tmproot/c10/wpd.md"

# ── Case 11: the REAL repo tree + committed WPD-0005 -> PASS ───────────────────
casei=$((casei + 1))
if out="$(bash "$CHECK" 2>&1)"; then
  if grep -qF "PASS" <<<"$out"; then
    echo "ok[case $casei]: real repo tree passes with the committed WPD-0005"
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
  echo "FAIL: verify-windows-storage-architecture self-test had failures" >&2
  exit 1
fi
echo "PASS: verify-windows-storage-architecture self-test ($casei cases)"
