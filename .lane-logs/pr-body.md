Audit wave 4, item 4 — de-fork the budget gate into OpenBurnBarCore and add a CI drift gate for the remaining intentional Budget forks.

**Stack order: #1344 → #1351 → this** (base branch `audit/wave4-ios-budget-scopes`; this stacks on the iOS budget-scopes lane, which stacks on the fail-closed lane).

## Review map

### Commit 1 — `refactor(budget)`: single BudgetGate in OpenBurnBarCore

| What | Where it went |
| --- | --- |
| `BudgetGate` implementation (macOS canonical: protocol seams + fail-closed logging) | `OpenBurnBarCore/Sources/OpenBurnBarCore/Budget/BudgetGate.swift` (all `public`) |
| `BudgetRuleProviding`, `BudgetLedgerReading` seams | same Core file, `public` |
| `BudgetBlockedError` (was byte-identical in both apps) | same Core file, single `public` definition with public memberwise init |
| Ledger read-failure logging | handler-injected `LedgerReadFailureHandler` (`(rule, error, isFallbackPath) -> Void`), init param defaults to nil; nil handler falls back to a Core-scoped `os.Logger(subsystem: "com.openburnbar.core", category: "BudgetGate")` (stderr off-Apple) so failures are never silent |
| `AgentLens/Services/DataStore/BudgetGate.swift` (~419 lines) | **deleted** → `BudgetGate+AgentLens.swift` (40 lines): `BudgetSettings: BudgetRuleProviding` + `BudgetLedger: BudgetLedgerReading` conformances + convenience `init(settings:ledger:warningThreshold:)` passing an AppLogger-backed handler |
| `OpenBurnBarMobile/Models/BudgetGate.swift` (~330 lines) | **deleted** → `BudgetGate+Mobile.swift` (41 lines): same conformances + convenience init passing an os.Logger-backed handler |
| Twin-basename allowlist | stale `BudgetGate.swift` pair removed from `docs/LINT_RATIONALE.md`; `check-twin-basenames.sh` passes (64 pairs) |
| pbxproj | regenerated via `xcodegen` (file delete/add churn only; Core file needs no pbxproj entry — local SwiftPM package) |

**What each app file retains:** ONLY the two protocol conformances and the platform logging factory. Zero gate logic.

**Behavior preserved byte-for-byte:** evaluate ordering, `matchesOrganizationRuleCandidate` (macOS comment kept), `failClosedDecision` (warnOnly→warn, block-capable→block, hardBlockWithFallback resolves fallback), `classify`, `resolveFallback`/`fallbackIdentity` (`normalized ?? "default"` both sides)/`fallbackCanAccept`/`fallbackRuleWouldBlock`, `rulesForContext`, `ledgerSpend`, `pickMoreRestrictive`/`priority`. The two pre-de-fork files differed only in seams, logging call style, and doc comments (~90 lines); the Core file is the macOS superset with logging routed through the handler.

**Call sites:** unchanged — `BudgetGate(settings:ledger:)` (AgentLensApp, AuthGateView, AgentInsightsTabScreen) resolves to the platform convenience init; the macOS test-seam init `BudgetGate(ruleProvider:ledger:warningThreshold:)` is now the Core designated init (4th param defaulted), so `BudgetGateMattersTests` compiles unchanged. All referencing files already `import OpenBurnBarCore`.

**New Core tests:** `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/BudgetGateCoreTests.swift` — 3 direct tests (fail-closed block on unreadable ledger, warnOnly fails to warn, subscription short-circuit with zero ledger reads) so `swift test` in OpenBurnBarCore is a cheap cross-platform parity harness without either app.

### Commit 2 — `ci(budget)`: drift gate + baselines

- `scripts/ci/check-budget-fork-drift.sh` (bash, `set -euo pipefail`, shellcheck-clean):
  1. Fails if `BudgetGate.swift` reappears under `AgentLens/` or `OpenBurnBarMobile/`, or the Core file goes missing.
  2. Fails if either seam file exceeds 120 lines (currently 40/41).
  3. For each remaining fork pair, hashes a normalized diff (strip `//`-comments, blank lines, leading/trailing whitespace) against `scripts/ci/budget-fork-baselines/<name>.sha256`; `--update` regenerates.
- Pairs: `BudgetEnforcement`, `BudgetSettings` (near-parallel forks — drift message says inspect + regenerate in the same PR), `BudgetLedger` (separate message: architecturally divergent by design — SQL `token_usage` vs synced rollups; the gate makes NEW drift a conscious, reviewed act).
- Wired into `.github/workflows/fast-feedback.yml` as a new small ubuntu job `budget-fork-drift`, following the `twin-basenames` sparse-checkout pattern exactly (same pinned checkout SHA). **release.yml untouched.**
- No new `budgets/*.json`, no suppressions, `docs/LINT_RATIONALE.md` only loses the stale twin entry.

## Parity evidence

- **Core package:** `swift build` clean; `swift test --filter BudgetGateCoreTests` → 3/3 passed; full `OpenBurnBarCoreTests` target → 1308 tests, 0 failures (6 pre-existing skips) — the move breaks nothing else in the package.
- **macOS:** `OPENBURNBAR_APP_TEST_FILTER='OpenBurnBarTests/BudgetGateMattersTests' ./scripts/test-openburnbar-app.sh` → 19/19 passed, TEST SUCCEEDED (suite unchanged — no edits to `BudgetGateMattersTests.swift`).
- **iOS:** `OPENBURNBAR_MOBILE_TEST_FILTER='OpenBurnBarMobileTests/BudgetGateTests' FIREBASE_SOURCE_FIRESTORE=1 ./scripts/test-openburnbar-mobile.sh` on the dedicated stack simulator → 23/23 passed, TEST SUCCEEDED (sim UDID 015CF5A3-0A72-4857-B215-66F302A4917B) (suite unchanged — no edits to `BudgetGateTests.swift`).
- Both app suites required **zero** import/visibility adjustments (they already `import OpenBurnBarCore`).

## Drift-gate demo

Green (fresh baselines):

```
$ bash scripts/ci/check-budget-fork-drift.sh
PASS: BudgetGate is de-forked (Core-only) and all budget fork pairs match their reviewed baselines.
```

Forced failure (temporarily appended a function to `OpenBurnBarMobile/Models/BudgetEnforcement.swift`, then reverted):

```
FAIL: budget fork pair 'BudgetEnforcement' drifted from its reviewed baseline.
  macOS: AgentLens/Services/DataStore/BudgetEnforcement.swift
  iOS:   OpenBurnBarMobile/Models/BudgetEnforcement.swift
  This pair is intentionally forked but expected to stay near-parallel; new one-sided edits are usually parity bugs.
  Inspect the pair drift (does the change belong on BOTH platforms, or in
  OpenBurnBarCore?), then regenerate the baseline in the same PR:
    bash scripts/ci/check-budget-fork-drift.sh --update
exit=1
```

`bash -n` + `shellcheck` clean on the script; workflow YAML parses; `check-no-suppressions`, `verify-github-action-pins`, `verify-agent-workflow-boundaries`, `check-twin-basenames` all green locally.

## Risks

- **Logging pipeline change is handler-injected** — event names and metadata are preserved per platform: macOS still emits `budget_gate_ledger_read_failed` / `budget_gate_fallback_ledger_read_failed` through `AppLogger.dataStore` with `ruleScope`/`ruleBehavior`/`errorClass` metadata; iOS still emits the same event names through `os.Logger(subsystem: "com.openburnbar.mobile", category: "BudgetGate")` with `scope=… behavior=… error=…` format. The only pipeline delta: a gate constructed via the Core designated init with a nil handler (today only the test seam) logs through the Core-scoped logger instead of AppLogger — failures stay observable either way.
- The normalized-diff hash is formatting-tolerant (comments/blank lines/leading whitespace) but any semantic one-sided edit to a fork pair flips it — that is the point; `--update` is the one-command escape hatch, in-PR.
- Seam-file line budget (120) is generous headroom over the current 40/41 to allow doc growth without inviting logic back in.

## Rollback

Revert the two commits (`git revert <ci-sha> <refactor-sha>`); the refactor commit is a pure move (git shows it as a rename of the macOS file) — reverting restores both app forks, the twin allowlist entry, and removes the workflow job + baselines. No schema, storage, or wire-format changes anywhere in this PR.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
