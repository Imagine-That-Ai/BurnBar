#!/usr/bin/env bash
# Positive/negative controls for check-quarantine-freshness.sh (R-GH8).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

script="scripts/ci/check-quarantine-freshness.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fixed "today" so fixtures are deterministic regardless of the wall clock.
AS_OF_FIXED="2026-06-30"
fail=0

# Emit a minimal one-row manifest in the real 7-column table format.
#   $1 dest path, $2 status, $3 target date, $4 test name
make_manifest() {
  cat >"$1" <<EOF
# Quarantine / Archive Manifest (fixture)

| Test Name | Status | Reason | Owner | Source Subsystem | Revival Criteria | Target Date |
|-----------|--------|--------|-------|------------------|------------------|-------------|
| \`$4\` | $2 | Stale contract | AgentLens | Example | Fix the fixture | $3 |
EOF
}

# Run the gate against a fixture and assert exit code (+ optional output needle).
#   $1 description, $2 manifest path, $3 expected exit, [$4 needle]
run_case() {
  local desc="$1" path="$2" want="$3" needle="${4:-}"
  local out rc
  if out="$(AS_OF="$AS_OF_FIXED" bash "$script" "$path" 2>&1)"; then rc=0; else rc=$?; fi
  if [[ "$rc" -ne "$want" ]]; then
    echo "FAIL: $desc: expected exit $want, got $rc" >&2
    echo "$out" >&2
    fail=1
    return
  fi
  if [[ -n "$needle" ]] && ! grep -q "$needle" <<<"$out"; then
    echo "FAIL: $desc: output missing expected text '$needle'" >&2
    echo "$out" >&2
    fail=1
    return
  fi
  echo "ok: $desc (exit $rc)"
}

# Required scenarios.
make_manifest "$tmp/pastdue.md" "Skipped-with-issue" "2020-01-01" "test_pastDueEntry"
run_case "past-due dated entry fails" "$tmp/pastdue.md" 1 "test_pastDueEntry"

make_manifest "$tmp/future.md" "Skipped-with-issue" "2099-12-31" "test_futureEntry"
run_case "future-dated entry passes" "$tmp/future.md" 0

make_manifest "$tmp/legacy.md" "LegacyReference" "2020-01-01" "test_legacyReferenceEntry"
run_case "LegacyReference entry is exempt even when past-due" "$tmp/legacy.md" 0

# Boundary: strictly-before means "== today" is still fresh.
make_manifest "$tmp/today.md" "Skipped-with-issue" "$AS_OF_FIXED" "test_dueExactlyToday"
run_case "Target Date == today is not past-due" "$tmp/today.md" 0

# Non-date target values and non-entry tables must be ignored.
cat >"$tmp/nondate.md" <<'EOF'
# Quarantine (fixture)

| Test Name | Status | Reason | Owner | Source Subsystem | Revival Criteria | Target Date |
|-----------|--------|--------|-------|------------------|------------------|-------------|
| `test_revived` | Done | Revived | CloudSync | Example | — | Done |
| `ParserTests` (monolithic) | LegacyReference | Legacy internals | AgentLens | Parsers | Archived | Archive |

## Totals

| Bucket | Count |
|--------|------:|
| Wave 2 rows | 24 |
EOF
run_case "Done/Archive/totals rows are ignored" "$tmp/nondate.md" 0

# Mixed manifest: exactly one overdue among exempt/fresh/done rows.
cat >"$tmp/mixed.md" <<'EOF'
# Quarantine (fixture)

| Test Name | Status | Reason | Owner | Source Subsystem | Revival Criteria | Target Date |
|-----------|--------|--------|-------|------------------|------------------|-------------|
| `test_exemptLegacy` | LegacyReference | Legacy | AgentLens | Example | Docs only | 2020-01-01 |
| `test_stillFresh` | Skipped-with-issue | Stale | AgentLens | Example | Fix it | 2099-01-01 |
| `test_alreadyRevived` | Done | Revived | AgentLens | Example | — | Done |
| `test_overdueOne` | Skipped-with-issue | Stale | AgentLens | Example | Fix it | 2026-01-15 |
EOF
run_case "mixed manifest fails and names the overdue entry" "$tmp/mixed.md" 1 "test_overdueOne"

# The mixed failure must not flag exempt/fresh/done rows.
if out="$(AS_OF="$AS_OF_FIXED" bash "$script" "$tmp/mixed.md" 2>&1)"; then :; fi
for notneedle in test_exemptLegacy test_stillFresh test_alreadyRevived; do
  if grep -q "$notneedle" <<<"$out"; then
    echo "FAIL: mixed manifest wrongly flagged $notneedle" >&2
    echo "$out" >&2
    fail=1
  fi
done

# Fail closed when the manifest is missing.
run_case "missing manifest fails closed" "$tmp/does-not-exist.md" 1

# Reject a malformed AS_OF override.
if out="$(AS_OF="not-a-date" bash "$script" "$tmp/future.md" 2>&1)"; then rc=0; else rc=$?; fi
if [[ "$rc" -ne 2 ]]; then
  echo "FAIL: malformed AS_OF should exit 2, got $rc" >&2
  echo "$out" >&2
  fail=1
else
  echo "ok: malformed AS_OF is rejected (exit $rc)"
fi

# Regression (R-GH8): the REAL shipped manifest must be fresh as of the day the
# freshness gate went live (2026-07-01). This proves the two rows that were
# already overdue on introduction —
# `test_circuitBreaker_halfOpenToClosed_recovery` (was 2026-05-24) and
# `testMakeConfigurationWithKey_reportsCipherVersion` (was 2026-05-17) — were
# re-dated, and guards against reintroducing a non-exempt past-due Target Date.
real_manifest="AgentLensTests/Quarantine/QUARANTINE_MANIFEST.md"
if out="$(AS_OF="2026-07-01" bash "$script" "$real_manifest" 2>&1)"; then rc=0; else rc=$?; fi
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL: real shipped quarantine manifest is past-due as of 2026-07-01" >&2
  echo "$out" >&2
  fail=1
else
  echo "ok: real shipped manifest is fresh as of 2026-07-01 (exit $rc)"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: check-quarantine-freshness self-test had failures" >&2
  exit 1
fi

echo "PASS: check-quarantine-freshness positive/negative controls"
