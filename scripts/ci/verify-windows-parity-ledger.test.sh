#!/usr/bin/env bash
# Positive + negative controls for verify-windows-parity-ledger.py
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
CHECK="scripts/ci/verify-windows-parity-ledger.py"

# Self-tests need PyYAML (same contract as CI).
if ! python3 -c "import yaml" 2>/dev/null; then
  python3 -m pip install --user 'pyyaml>=6,<7' >/dev/null
fi

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
  if [[ -n "$needle" ]] && ! grep -qF -- "$needle" <<<"$out"; then
    echo "FAIL[case $casei]: output missing expected text: $needle" >&2
    echo "$out" >&2
    fail=1
    return
  fi
  echo "ok[case $casei]: expect=$expect needle=${needle:-<none>}"
}

# ── Fixture helpers ─────────────────────────────────────────────────────────
EVIDENCE_BODY=$(cat <<'EOF'
# Evidence artifact for Real row self-tests

**Ledger row:** `fixture-real`
**Status claim:** Real

## What this proves

This fixture is long enough to clear the minimum evidence length floor and
carries the required markers so the honesty gate accepts it as a Real
evidence file during self-tests. It deliberately avoids false-green tokens.
EOF
)

mk_repo() {
  local root="$1"
  mkdir -p \
    "$root/docs/windows-port/evidence" \
    "$root/windows/prod" \
    "$root/windows/tests" \
    "$root/scripts/ci"
  printf '%s\n' "$EVIDENCE_BODY" >"$root/docs/windows-port/evidence/ok.md"
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

real_row() {
  local id="$1"
  local extra="${2:-}"
  cat <<EOF
  - id: $id
    macos_route: extra-$id
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
$extra
EOF
}

# ── 1. Full repo ledger should PASS ─────────────────────────────────────────
run_case pass "windows-parity-ledger: PASS" \
  --repo-root "$(pwd)" \
  --ledger "$(pwd)/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 2. Authored status is rejected ──────────────────────────────────────────
mk_repo "$tmproot/authored"
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

# ── 3b. Real row without tests fails ────────────────────────────────────────
mk_repo "$tmproot/notests"
write_ledger "$tmproot/notests" "$(cat <<EOF
$(all_routes_rows Blocked)
  - id: real-no-tests
    macos_route: extra-notests
    macos_capability: "x"
    windows_route: "y"
    windows_capability: "z"
    status: Real
    evidence:
      - docs/windows-port/evidence/ok.md
    tests: []
    blocking_paths:
      - windows/prod/CleanCore.cs
    owner_lane: test
EOF
)"
run_case fail "Real row requires ≥1 test path" \
  --repo-root "$tmproot/notests" \
  --ledger "$tmproot/notests/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 3c. Real missing test path fails ────────────────────────────────────────
mk_repo "$tmproot/missingtest"
write_ledger "$tmproot/missingtest" "$(cat <<EOF
$(all_routes_rows Blocked)
  - id: real-missing-test
    macos_route: extra-mt
    macos_capability: "x"
    windows_route: "y"
    windows_capability: "z"
    status: Real
    evidence:
      - docs/windows-port/evidence/ok.md
    tests:
      - windows/tests/DoesNotExist.cs
    blocking_paths:
      - windows/prod/CleanCore.cs
    owner_lane: test
EOF
)"
run_case fail "Real test path missing" \
  --repo-root "$tmproot/missingtest" \
  --ledger "$tmproot/missingtest/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 3d. Real missing evidence file fails ────────────────────────────────────
mk_repo "$tmproot/missingevidence"
write_ledger "$tmproot/missingevidence" "$(cat <<EOF
$(all_routes_rows Blocked)
  - id: real-missing-ev
    macos_route: extra-me
    macos_capability: "x"
    windows_route: "y"
    windows_capability: "z"
    status: Real
    evidence:
      - docs/windows-port/evidence/does-not-exist.md
    tests:
      - windows/tests/CleanCoreTests.cs
    blocking_paths:
      - windows/prod/CleanCore.cs
    owner_lane: test
EOF
)"
run_case fail "Real evidence file missing" \
  --repo-root "$tmproot/missingevidence" \
  --ledger "$tmproot/missingevidence/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 3e. Empty evidence file fails ───────────────────────────────────────────
mk_repo "$tmproot/emptyev"
: >"$tmproot/emptyev/docs/windows-port/evidence/ok.md"
write_ledger "$tmproot/emptyev" "$(cat <<EOF
$(all_routes_rows Blocked)
$(real_row real-empty-ev)
EOF
)"
run_case fail "Real evidence file is empty" \
  --repo-root "$tmproot/emptyev" \
  --ledger "$tmproot/emptyev/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 3f. Empty blocking_paths fails ──────────────────────────────────────────
mk_repo "$tmproot/noblock"
write_ledger "$tmproot/noblock" "$(cat <<EOF
$(all_routes_rows Blocked)
  - id: real-no-block
    macos_route: extra-nb
    macos_capability: "x"
    windows_route: "y"
    windows_capability: "z"
    status: Real
    evidence:
      - docs/windows-port/evidence/ok.md
    tests:
      - windows/tests/CleanCoreTests.cs
    blocking_paths: []
    owner_lane: test
EOF
)"
run_case fail "Real row requires ≥1 blocking_paths entry" \
  --repo-root "$tmproot/noblock" \
  --ledger "$tmproot/noblock/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 3g. Docs-only blocking_paths fails ──────────────────────────────────────
mk_repo "$tmproot/docsonly"
write_ledger "$tmproot/docsonly" "$(cat <<EOF
$(all_routes_rows Blocked)
  - id: real-docs-only
    macos_route: extra-do
    macos_capability: "x"
    windows_route: "y"
    windows_capability: "z"
    status: Real
    evidence:
      - docs/windows-port/evidence/ok.md
    tests:
      - windows/tests/CleanCoreTests.cs
    blocking_paths:
      - docs/windows-port/evidence/ok.md
    owner_lane: test
EOF
)"
run_case fail "non-test production blocking_paths" \
  --repo-root "$tmproot/docsonly" \
  --ledger "$tmproot/docsonly/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 3g2. Test-tree-only blocking_paths fails (windows/tests/ is not production) ─
mk_repo "$tmproot/testonly"
write_ledger "$tmproot/testonly" "$(cat <<EOF
$(all_routes_rows Blocked)
  - id: real-test-tree-only
    macos_route: extra-tt
    macos_capability: "x"
    windows_route: "y"
    windows_capability: "z"
    status: Real
    evidence:
      - docs/windows-port/evidence/ok.md
    tests:
      - windows/tests/CleanCoreTests.cs
    blocking_paths:
      - windows/tests/CleanCoreTests.cs
    owner_lane: test
EOF
)"
run_case fail "test trees such as windows/tests/" \
  --repo-root "$tmproot/testonly" \
  --ledger "$tmproot/testonly/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 3h. Absolute / .. path fails ────────────────────────────────────────────
mk_repo "$tmproot/escape"
write_ledger "$tmproot/escape" "$(cat <<EOF
$(all_routes_rows Blocked)
  - id: real-escape
    macos_route: extra-esc
    macos_capability: "x"
    windows_route: "y"
    windows_capability: "z"
    status: Real
    evidence:
      - docs/windows-port/evidence/ok.md
    tests:
      - windows/tests/CleanCoreTests.cs
    blocking_paths:
      - ../etc/passwd
    owner_lane: test
EOF
)"
run_case fail "path escape '..' is forbidden" \
  --repo-root "$tmproot/escape" \
  --ledger "$tmproot/escape/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 4. Forbidden-token matrix (each pattern must fail Real) ─────────────────
plant_and_fail_token() {
  local name="$1"
  local src="$2"
  local needle="$3"
  local dir="$tmproot/tok-$name"
  mk_repo "$dir"
  printf '%s\n' "$src" >"$dir/windows/prod/Dirty.cs"
  write_ledger "$dir" "$(cat <<EOF
$(all_routes_rows Blocked)
  - id: real-tok-$name
    macos_route: extra-tok-$name
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
  run_case fail "$needle" \
    --repo-root "$dir" \
    --ledger "$dir/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"
}

plant_and_fail_token SampleData \
  'public static class FooSampleData { public static int X => 1; }' \
  "forbidden token 'SampleData'"

plant_and_fail_token SampleModeEnabled \
  'public static bool SampleModeEnabled => true;' \
  "forbidden token 'SampleModeEnabled'"

plant_and_fail_token DemoHost \
  'public sealed class MissionDispatchDemoHost {}' \
  "forbidden token 'DemoHost'"

plant_and_fail_token MockAttestation \
  'public sealed class MockAttestationProducer {}' \
  "forbidden token 'MockAttestationProducer'"

plant_and_fail_token Stub \
  'public sealed class StubCliStream {}' \
  "forbidden token 'Stub'"

# Bare type Stub (plan token "Stub") must fail — not only Stub* compounds.
plant_and_fail_token StubBare \
  'public sealed class Stub {}' \
  "forbidden token 'Stub'"

plant_and_fail_token IStub \
  'public interface IStubTokenSource {}' \
  "forbidden token 'Stub'"

plant_and_fail_token Placeholder \
  'public sealed class SettingsPlaceholderPage {}' \
  "forbidden token 'Placeholder'"

plant_and_fail_token Unavailable \
  'public sealed class UnavailableChatStreamDriver {}' \
  "forbidden token 'Unavailable'"

plant_and_fail_token devhost \
  '// composition for dev-host only' \
  "forbidden token 'dev-host'"

plant_and_fail_token deferred \
  '// host-deferred until Win11 Pro pass' \
  "forbidden token 'deferred'"

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
run_case fail "macOS primary route 'memoryReview'" \
  --repo-root "$tmproot/missing" \
  --ledger "$tmproot/missing/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 5b. Missing required route fails ────────────────────────────────────────
mk_repo "$tmproot/req"
# all primary, missing settings required
write_ledger "$tmproot/req" "$(cat <<EOF
$(for r in chat quota database projects missions sessionLogs memoryReview overview insights flyout budget elderWand; do base_row "map-$r" "$r" Blocked; done)
EOF
)"
run_case fail "macOS required route 'settings'" \
  --repo-root "$tmproot/req" \
  --ledger "$tmproot/req/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

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

# ── 6b. Evidence body with PLACEHOLDER fails Real ───────────────────────────
mk_repo "$tmproot/phev"
printf '%s\n' "$EVIDENCE_BODY"$'\n\nPLACEHOLDER screenshots/fake.png\n' \
  >"$tmproot/phev/docs/windows-port/evidence/ok.md"
write_ledger "$tmproot/phev" "$(cat <<EOF
$(all_routes_rows Blocked)
$(real_row real-ph-ev)
EOF
)"
run_case fail "must not contain PLACEHOLDER" \
  --repo-root "$tmproot/phev" \
  --ledger "$tmproot/phev/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 6c. --production forbids any PLACEHOLDER cell ───────────────────────────
mk_repo "$tmproot/prodmode"
cat >"$tmproot/prodmode/docs/windows-port/PARITY_CERTIFICATION_BUNDLE.md" <<'EOF'
# Bundle
Still has a PLACEHOLDER narrative cell without a screenshot path.
EOF
write_ledger "$tmproot/prodmode" "$(all_routes_rows Blocked)"
run_case fail "--production forbids any PLACEHOLDER cell" \
  --repo-root "$tmproot/prodmode" \
  --ledger "$tmproot/prodmode/docs/windows-port/WINDOWS_PARITY_LEDGER.yml" \
  --production

# ── 7. Clean synthetic Real row passes ──────────────────────────────────────
mk_repo "$tmproot/clean"
write_ledger "$tmproot/clean" "$(cat <<EOF
$(all_routes_rows Blocked)
$(real_row real-clean)
EOF
)"
run_case pass "windows-parity-ledger: PASS" \
  --repo-root "$tmproot/clean" \
  --ledger "$tmproot/clean/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 8. Substituted may mention SampleData and still PASS ────────────────────
mk_repo "$tmproot/sub"
printf '%s\n' 'public static class TraySampleData {}' >"$tmproot/sub/windows/prod/Dirty.cs"
write_ledger "$tmproot/sub" "$(cat <<EOF
$(all_routes_rows Blocked)
  - id: sub-sample
    macos_route: extra-sub
    macos_capability: "x"
    windows_route: "y"
    windows_capability: "z"
    status: Substituted
    evidence:
      - docs/windows-port/evidence/ok.md
    tests:
      - windows/tests/CleanCoreTests.cs
    blocking_paths:
      - windows/prod/Dirty.cs
    owner_lane: test
EOF
)"
run_case pass "windows-parity-ledger: PASS" \
  --repo-root "$tmproot/sub" \
  --ledger "$tmproot/sub/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 9. DeferredApproved requires revive_trigger ─────────────────────────────
mk_repo "$tmproot/def"
write_ledger "$tmproot/def" "$(cat <<EOF
$(all_routes_rows Blocked)
  - id: def-no-revive
    macos_route: extra-def
    macos_capability: "x"
    windows_route: "y"
    windows_capability: "z"
    status: DeferredApproved
    evidence:
      - docs/windows-port/evidence/ok.md
    tests:
      - windows/tests/CleanCoreTests.cs
    blocking_paths:
      - windows/prod/CleanCore.cs
    owner_lane: test
EOF
)"
run_case fail "DeferredApproved row requires non-empty 'revive_trigger'" \
  --repo-root "$tmproot/def" \
  --ledger "$tmproot/def/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

# ── 10. Non-test-shaped Real test path fails ────────────────────────────────
mk_repo "$tmproot/notshaped"
write_ledger "$tmproot/notshaped" "$(cat <<EOF
$(all_routes_rows Blocked)
  - id: real-bad-test-shape
    macos_route: extra-shape
    macos_capability: "x"
    windows_route: "y"
    windows_capability: "z"
    status: Real
    evidence:
      - docs/windows-port/evidence/ok.md
    tests:
      - windows/prod/CleanCore.cs
    blocking_paths:
      - windows/prod/CleanCore.cs
    owner_lane: test
EOF
)"
run_case fail "not test-shaped" \
  --repo-root "$tmproot/notshaped" \
  --ledger "$tmproot/notshaped/docs/windows-port/WINDOWS_PARITY_LEDGER.yml"

if [[ "$fail" -ne 0 ]]; then
  echo "verify-windows-parity-ledger.test.sh: FAILED" >&2
  exit 1
fi

echo "verify-windows-parity-ledger.test.sh: all $casei cases passed"
