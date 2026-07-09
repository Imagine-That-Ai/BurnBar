#!/usr/bin/env bash
# Positive + negative controls for verify-windows-parity-ledger.py
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
CHECK="scripts/ci/verify-windows-parity-ledger.py"

tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

fail=0
casei=0

run_case() {
  local expect="$1"
  local needle="$2"
  shift 2
  casei=$((casei + 1))
  local out rc=0
  out="$(python3 "$CHECK" "$@" 2>&1)" || rc=$?
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

# ── Fixture helpers ─────────────────────────────────────────────────────────
mk_repo() {
  local root="$1"
  mkdir -p \
    "$root/docs/windows-port/evidence" \
    "$root/windows/prod" \
    "$root/windows/tests" \
    "$root/scripts/ci"
  # minimal primary + required routes coverage
  cat >"$root/docs/windows-port/evidence/ok.md" <<'EOF'
# Evidence
Status claim: Real
No screenshot fakery here.
EOF
  cat >"$root/windows/prod/CleanCore.cs" <<'EOF'
namespace Demo;
public static class CleanCore
{
    public static int Add(int a, int b) => a + b;
}
EOF
  cat >"$root/windows/tests/CleanCoreTests.cs" <<'EOF'
// unit test fixture
public class CleanCoreTests {}
EOF
  cat >"$root/docs/windows-port/PARITY_CERTIFICATION_BUNDLE.md" <<'EOF'
# Bundle
| Flow | Screenshot | Tests |
|------|------------|-------|
| install | _(blocked — Win11 Pro pass pending)_ | tests |
EOF
}

write_ledger() {
  local root="$1"
  local body="$2"
  cat >"$root/docs/windows-port/WINDOWS_PARITY_LEDGER.yml" <<EOF
version: 1
schema_id: windows-parity-ledger-v1
macos_primary_routes:
  - chat
  - quota
  - database
  - projects
  - missions
  - sessionLogs
  - memoryReview
macos_required_routes:
  - overview
  - insights
  - settings
  - flyout
  - budget
  - elderWand
certification_bundle: docs/windows-port/PARITY_CERTIFICATION_BUNDLE.md
rows:
$body
EOF
}

base_row() {
  local id="$1" route="$2" status="$3"
  cat <<EOF
  - id: $id
    macos_route: $route
    macos_capability: "cap-$route"
    windows_route: "win-$route"
    windows_capability: "wincap-$route"
    status: $status
    evidence:
      - docs/windows-port/evidence/ok.md
    tests:
      - windows/tests/CleanCoreTests.cs
    blocking_paths:
      - windows/prod/CleanCore.cs
    owner_lane: test
EOF
}

all_routes_rows() {
  local status="${1:-Blocked}"
  for r in chat quota database projects missions sessionLogs memoryReview overview insights settings flyout budget elderWand; do
    base_row "map-$r" "$r" "$status"
  done
}

# ── 1. Full repo ledger should PASS ─────────────────────────────────────────
run_case pass "windows-parity-ledger: PASS" \
  --repo-root "$(pwd)" \
  --ledger "$(pwd)/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 2. Authored status is rejected ──────────────────────────────────────────
mk_repo "$tmproot/authored"
write_ledger "$tmproot/authored" "$(all_routes_rows Blocked)
$(base_row bad-authored overview Authored | sed 's/map-overview/bad-authored/;s/overview/overview-dup/' || true)
"
# simpler: one Authored row among complete primary maps
{
  echo "$(all_routes_rows Blocked)"
  cat <<'ROW'
  - id: authored-row
    macos_route: extra
    macos_capability: "x"
    windows_route: "y"
    windows_capability: "z"
    status: Authored
    evidence:
      - docs/windows-port/evidence/ok.md
    tests:
      - windows/tests/CleanCoreTests.cs
    blocking_paths:
      - windows/prod/CleanCore.cs
    owner_lane: test
ROW
} >"$tmproot/authored/body.yml"
# rewrite properly
write_ledger "$tmproot/authored" "$(cat <<EOF
$(all_routes_rows Blocked)
  - id: authored-row
    macos_route: extra
    macos_capability: "x"
    windows_route: "y"
    windows_capability: "z"
    status: Authored
    evidence:
      - docs/windows-port/evidence/ok.md
    tests:
      - windows/tests/CleanCoreTests.cs
    blocking_paths:
      - windows/prod/CleanCore.cs
    owner_lane: test
EOF
)"
run_case fail "illegal status 'Authored'" \
  --repo-root "$tmproot/authored" \
  --ledger "$tmproot/authored/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 3. Real row without evidence fails ──────────────────────────────────────
mk_repo "$tmproot/noev"
write_ledger "$tmproot/noev" "$(cat <<EOF
$(all_routes_rows Blocked)
  - id: real-no-evidence
    macos_route: extra2
    macos_capability: "x"
    windows_route: "y"
    windows_capability: "z"
    status: Real
    evidence: []
    tests:
      - windows/tests/CleanCoreTests.cs
    blocking_paths:
      - windows/prod/CleanCore.cs
    owner_lane: test
EOF
)"
run_case fail "Real row requires ≥1 evidence path" \
  --repo-root "$tmproot/noev" \
  --ledger "$tmproot/noev/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 4. Real row with SampleData in blocking path fails ──────────────────────
mk_repo "$tmproot/sample"
cat >"$tmproot/sample/windows/prod/Dirty.cs" <<'EOF'
public static class FooSampleData { public static int X => 1; }
EOF
write_ledger "$tmproot/sample" "$(cat <<EOF
$(all_routes_rows Blocked)
  - id: real-dirty
    macos_route: extra3
    macos_capability: "x"
    windows_route: "y"
    windows_capability: "z"
    status: Real
    evidence:
      - docs/windows-port/evidence/ok.md
    tests:
      - windows/tests/CleanCoreTests.cs
    blocking_paths:
      - windows/prod/Dirty.cs
    owner_lane: test
EOF
)"
run_case fail "SampleData" \
  --repo-root "$tmproot/sample" \
  --ledger "$tmproot/sample/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 5. Missing macOS primary route fails ────────────────────────────────────
mk_repo "$tmproot/missing"
write_ledger "$tmproot/missing" "$(cat <<EOF
$(for r in chat quota database projects missions sessionLogs; do base_row "map-$r" "$r" Blocked; done)
  - id: map-overview
    macos_route: overview
    macos_capability: "x"
    windows_route: "y"
    windows_capability: "z"
    status: Blocked
    evidence:
      - docs/windows-port/evidence/ok.md
    tests:
      - windows/tests/CleanCoreTests.cs
    blocking_paths:
      - windows/prod/CleanCore.cs
    owner_lane: test
EOF
)"
# missing memoryReview primary + several required
run_case fail "macOS primary route 'memoryReview'" \
  --repo-root "$tmproot/missing" \
  --ledger "$tmproot/missing/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 6. PLACEHOLDER screenshot paths in certification bundle fail ────────────
mk_repo "$tmproot/ph"
cat >"$tmproot/ph/docs/windows-port/PARITY_CERTIFICATION_BUNDLE.md" <<'EOF'
| Flow | Screenshot |
|------|------------|
| cold install | PLACEHOLDER `screenshots/g5-msix-install.png` |
EOF
write_ledger "$tmproot/ph" "$(all_routes_rows Blocked)"
run_case fail "PLACEHOLDER screenshot path" \
  --repo-root "$tmproot/ph" \
  --ledger "$tmproot/ph/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 7. Clean synthetic Real row passes ──────────────────────────────────────
mk_repo "$tmproot/clean"
write_ledger "$tmproot/clean" "$(cat <<EOF
$(all_routes_rows Blocked)
  - id: real-clean
    macos_route: extra-clean
    macos_capability: "x"
    windows_route: "y"
    windows_capability: "z"
    status: Real
    evidence:
      - docs/windows-port/evidence/ok.md
    tests:
      - windows/tests/CleanCoreTests.cs
    blocking_paths:
      - windows/prod/CleanCore.cs
    owner_lane: test
EOF
)"
run_case pass "windows-parity-ledger: PASS" \
  --repo-root "$tmproot/clean" \
  --ledger "$tmproot/clean/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

if [[ "$fail" -ne 0 ]]; then
  echo "verify-windows-parity-ledger.test.sh: FAILED" >&2
  exit 1
fi

echo "verify-windows-parity-ledger.test.sh: all $casei cases passed"
