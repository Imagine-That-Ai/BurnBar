# Budget-enforcement contract vectors

Platform-neutral decision vectors for the budget-enforcement engine (Wave-5 WS3). One
fixture, consumed by every platform's gate, so a divergence fails a **build** instead of an
audit months later.

## Why

`BudgetGate` is a single shared implementation in `OpenBurnBarCore` (macOS + iOS). Android
re-implements the same contract in Kotlin (`com.openburnbar.data.budget.BudgetGate`) and
cannot share Swift. These vectors are the cross-language parity contract: rules × request ×
ledger → expected decision, derived from and pinned against the Swift reference
implementation at `OpenBurnBarCore/Sources/OpenBurnBarCore/Budget/BudgetGate.swift`.

## Copies (kept byte-identical)

| path | consumer |
|---|---|
| `tests/fixtures/budget-enforcement/budget-enforcement-vectors.json` | canonical source of truth |
| `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/budget-enforcement-vectors.json` | `BudgetGateContractVectorTests` (Apple, PR-gated via `swiftpm-native`) |
| `android/app/src/test/resources/budget-enforcement/budget-enforcement-vectors.json` | Android JUnit consumer (follow-up) |

`scripts/ci/check-budget-enforcement-fixture.mjs` (workflow `budget-enforcement-contract.yml`)
pins all copies byte-identical, **fails on deletion**, structurally validates every vector,
and asserts the coverage matrix. Editing the fixture means editing **all** copies in the same
commit.

## Schema (schemaVersion 1)

```jsonc
{
  "id": "kebab-unique",
  "description": "...",
  "rules": [{
    "id": "r1",
    "scope": "credential | project | global | organization",
    "identifier": null,            // org-scope match key (vs slotID/displayLabel/providerAccountID/providerAccountLabel)
    "providerID": "openrouter",    // credential scope
    "accountID": "slot-1",         // credential scope
    "projectName": null,           // project scope
    "label": "…",
    "amountUSD": 100,
    "period": "day | week | month | allTime",
    "behavior": "warnThenBlock | hardBlock | warnOnly | hardBlockWithFallback",
    "isEnabled": true,
    "fallbackCredentialIDs": [],   // rule ids to promote (hardBlockWithFallback)
    "pausedUntil": null            // ISO-8601; a future value makes the rule report `paused`
  }],
  "request": {
    "providerID": "openrouter", "slotID": "slot-1", "displayLabel": "…",
    "providerAccountID": null, "providerAccountLabel": null,
    "billingMode": "perUsage | subscription | unknown",
    "projectName": null, "estimatedCost": 1.0
  },
  "ledger": {
    "reference": "2026-06-15T12:00:00Z",  // clock for paused checks
    "spend": { "r1": 99.0 },              // current spend per rule id
    "unreadable": []                      // rule ids whose ledger read THROWS (fail-closed path).
                                          // A rule that is evaluated but absent from `spend` also throws.
  },
  "expected": {
    "decision": "allow | warn | block | paused",
    "ruleID": "r1",                       // the rule that produced the decision (null for allow)
    "fallbackCredentialID": "rf",         // the fallback RULE id the gate resolved (null if none)
    "used": 99.0, "limit": 100.0, "usedPercent": 0.99,  // optional, asserted when present
    "resumeAt": "…",                      // paused resume time
    "noLedgerReads": true                 // assert the ledger was never touched (subscription / paused / filtered)
  }
}
```

## Decision semantics (from `BudgetGate.swift`)

- `projected = spend + max(0, estimatedCost)`; `projectedPercent = projected / amountUSD`.
- `warnThenBlock`: block ≥ 100%, warn ≥ 80%, else allow.
- `hardBlock`: block ≥ 100%, else allow (no warn band).
- `warnOnly`: warn ≥ 80% (and ≥ 100%) — **never blocks**.
- `hardBlockWithFallback`: block ≥ 100% (+ resolved fallback), warn ≥ 80%, else allow.
- **Fail closed**: an unreadable ledger read → block for block-capable behaviors, **warn** for
  `warnOnly` (never silently allow). Fallback candidates with an unreadable read are disqualified.
- Subscription credentials short-circuit to `allow` before any ledger read.
- Most-restrictive wins: `allow < paused < warn < block`.

## Regenerating / adding vectors

Add the vector to the canonical file, copy it byte-for-byte to the other two paths, and run
`swift test --package-path OpenBurnBarCore --filter BudgetGateContractVectorTests` — the test
runs each vector through the real gate, so a wrong `expected` fails immediately. Then
`node scripts/ci/check-budget-enforcement-fixture.mjs` to confirm byte-identity + coverage.
