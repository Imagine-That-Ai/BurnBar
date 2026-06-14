# Drive untagged try? in AgentLens/Services to 0

Goal ID: `try-optional-zero`
Started: 2026-06-14T06:18:07Z
Parent goal: none
Mode: full
Ledger path: `.agent/runs/try-optional-zero/`

## Objective

Reduce untagged try? error-debt in AgentLens/Services from 727 to 0 via security-first tranches: tag genuine best-effort with try?-ok, convert matters-sites to tested fail-closed do/catch, never hide a fail-open.

## Goal Mode Coupling

When creating or updating the matching `/goal`, include this ledger pointer in the goal objective:

`Maintain the agent-owned ledger at /Users/albertonunez/Documents/Windsurf/BurnBar/.agent/runs/try-optional-zero/ and keep implementation-notes.html current at checkpoints, before compaction, and before final handoff.`

## Finishing Criteria

- [done] `count-error-debt.py --metric try-optional` reports `total=0` (638 tagged best-effort) (zero UNTAGGED try? in AgentLens/Services). Start 808 → tranche 1: 727.
- [done] `budgets/try-optional-baseline.json` `total` ratcheted to 0 (assert-zero) (then, per plan Phase 6, delete the file + flip the gate to assert-zero).
- [done] Every "matters" site (see `docs/security/try-optional-matters-findings-2026-06-14.md`) is converted to a TESTED fail-closed `do/catch` or `AppLogger.silently`, NOT tagged and NOT laundered with `silently(fallback:)` that preserves a fail-open. Findings doc closed out (each item fixed or formally accepted with rationale).
- [done] `docs/TECH_DEBT_METRICS.md` try? row shows 0; metrics refresher green.
- [doing] PR #381 OPEN, 50/50 checks green + local full app suite TEST SUCCEEDED; awaiting human review/merge (state=BLOCKED on required review only) (Platform Misc try? gate + App XCTest build/tests/diff-coverage + SwiftLint).
- [done] Keep `implementation-notes.html` current at every tranche checkpoint, before compaction, and before handoff.

## Validation Commands

```bash
# untagged count (must reach 0)
python3 tools/error-debt/count-error-debt.py --metric try-optional --format text
# budget gate (fails on increase)
./scripts/debt/check-try-optional-budget.sh
# counter self-test
python3 tools/error-debt/test_count_error_debt.py
```

## Known Blocker (escape-hatch tripped)

`origin/main` SwiftLint `--strict` gate is RED from 10 pre-existing violations in 4 unrelated files (from #362 + the CloudVault rotation fix: 7× `return XCTFail(...)`, 3× trailing-newline). The App XCTest job dies at the SwiftLint step before tests/diff-coverage, so EVERY tranche PR (and all other swarms' PRs) cannot fully go green until those 4 files are fixed. Tranche app-target changes are therefore verified LOCALLY (build-for-testing + targeted tests) until that is resolved.

## Escape Hatch

Pause, ask the user, or mark a scoped item `[blocked]` / `[incomplete]` if:
- validation contradicts the goal
- the goal requires a scope change
- the agent is looping without measurable progress
- the next step risks deleting or rewriting durable memory
- the PRD and actual repo disagree
- the ledger itself contaminates validation

