# Wave 5 — Policy core un-fork, cross-platform contract tests, and the iOS composition seam

Status: PLAN (Wave-5 WS1 + WS3 + WS6). Author: conductor session 2026-07-08. Ledger: `.agent/runs/wave5-2026-07-07/`.

## 0. Re-baselined reality (what the wave brief got wrong)

The brief assumed two forked BudgetGate files (`AgentLens/Services/DataStore/BudgetGate.swift` ~419 vs `OpenBurnBarMobile/Models/BudgetGate.swift` ~307). **That state no longer exists.** Wave 4 (commit `dd4d93bab7`) already un-forked the decision core: both apps consume `OpenBurnBarCore/Sources/OpenBurnBarCore/Budget/BudgetGate.swift` (456 lines, pure, protocol-seamed via `BudgetRuleProviding` + `BudgetLedgerReading`, injectable clock) through ≤41-line seam files, enforced by the `Budget fork drift` CI job (`scripts/ci/check-budget-fork-drift.sh`).

N1 (Android org budgets), N2 (iOS fail-open on unreadable spend), N3 (mac entitlement precedence with lapsed cloud doc) are all **fixed on main** with tests.

What is actually still forked or broken, in priority order:

| # | Surface | State | Action this wave |
|---|---------|-------|------------------|
| 1 | **Android enforcement** | `BudgetGate.evaluate()` in `android/.../data/budget/BudgetGate.kt` has **zero production callers** — budgets are display-only on Android. Also: no fail-closed on DAO errors, `hardBlockWithFallback` returns plain BLOCK ("not fully wired in v1"). | Contract tests expose the gaps (WS3); fail-closed + fallback implemented in Kotlin; the missing call site is a **named product decision** for Alberto (§4). |
| 2 | **Android budget unit tests are now PR-gated** | PR #1396 landed `.github/workflows/android-budget-contract.yml`, which runs the Android budget vector tests on relevant PRs. | Reuse the existing WS3 lane; extend it only when new vectors or budget call sites are added (§3.4). |
| 3 | **BudgetEnforcement pair** (mac 161 / iOS 192 lines) | Same intent, three real divergences: ledger-failure display (`?? 0` mac vs `?? rule.amountUSD` iOS), cost estimation (`ModelPricing.lookup` mac vs hard-coded $3/$15 iOS), identity hashing byte-identical duplicated. | Hoist the pure parts to Core (§2). |
| 4 | **Entitlement precedence** | Mac-only logic inside `MacCloudEntitlementStore` (N3-fixed but unextracted); iOS uses a structurally different server-arbitrated model. | Extract mac arbitration as a pure Core function + KAT-style tests (§2.3). Merging the iOS model is **out of scope** (different trust architecture). |
| 5 | **BudgetSettings / BudgetLedger / BudgetRulesStore pairs** | Architecturally divergent **by design** (GRDB vs Firestore/rollups). Drift gate pins them. | Keep forked. Not debt. |
| 6 | **Daemon plane** | Comments claim daemon enforces budgets (HTTP 402 + `BurnBar-Budget-Limit`); grep shows zero gate references in `OpenBurnBarDaemon/Sources`. | Fix the stale comments now; daemon enforcement is a named follow-up, not Wave 5. |

## 1. Design principle (unchanged from the brief)

ONE pure decision core — inputs: rules, spend snapshots, request descriptor → decision — with thin platform adapters owning I/O. The Swift half of that core **exists** (`BudgetGate` in OpenBurnBarCore). Wave 5 (a) widens the pure core to cover the still-duplicated pure logic, (b) makes Android provably equivalent via platform-neutral fixtures since it cannot share Swift, and (c) proves it forever with build-failing contract tests on all three platforms.

## 2. WS1 — remaining un-fork work (Swift)

### 2.1 `BudgetCredentialIdentity` hashing → Core
`AgentLensCredentialIdentity` (`AgentLens/.../BudgetEnforcement.swift:129-161`) and `MobileCredentialIdentity` (`OpenBurnBarMobile/Models/BudgetEnforcement.swift:161-192`) are byte-identical FNV-1a slot-hash builders. Move once into `OpenBurnBarCore/Sources/OpenBurnBarCore/Budget/BudgetCredentialIdentityBuilder.swift`; seams keep a typealias. Pure move + dedupe; existing tests keep passing.

### 2.2 `BudgetEnforcement` pure parts → Core
Split BudgetEnforcement into:
- **Core (new, pure):** `BudgetContextComposer` — builds the Hermes budget-context prompt section from `[rule, spend?]` pairs. Resolves divergence #3: unreadable spend renders as **"unknown (treated as at-limit)"** — neither `$0` (mac today; understates) nor silently `amountUSD` (iOS today; indistinguishable from real at-limit). One behavior, documented, covered by a Core test.
- **Core (new, pure):** `BudgetCostEstimator` — estimation policy: `ModelPricing.lookup(model:)` when the model is known, explicit documented default (the current iOS $3/$15 per MTok) when not. `ModelPricing` is already Core-visible or moves with it. Resolves divergence #2: iOS stops hard-coding, mac keeps its behavior, unknown-model behavior becomes identical.
- **Platform (stays):** singletons, notification wiring, user-scoped lifecycle (`configuredUserID` is iOS-only and stays iOS).

Same PR must update `scripts/ci/check-budget-fork-drift.sh`: regenerate the `BudgetEnforcement` pair baseline (`--update`) — the pair stays listed (it still exists, thinner), the Core files are new and unpinned.

### 2.3 Entitlement precedence → pure Core function
Extract from `MacCloudEntitlementStore.publishMembershipEntitlements` (+ `preferred(over:)`, tier merge, `activeEntitlementState` parsing) into `OpenBurnBarCore/.../Entitlements/EntitlementArbitration.swift`:

```swift
struct EntitlementArbitration {
    struct CloudDocState { let key: String; let active: Bool; let expiry: Date? }
    struct StoreKitState { let productID: String; let uidBound: Bool; let revoked: Bool; let expiry: Date? }
    static func effectiveTier(cloud: [CloudDocState], storeKit: [StoreKitState], now: Date) -> Arbitration
}
```

Contract encoded (the N3 invariants): active cloud > StoreKit > free; **lapsed cloud docs are invisible** (must not suppress valid StoreKit); StoreKit without UID binding fails closed to free; per-tier max-expiry merge with Ultra⇒Pro⇒Cloud implication. Mac store becomes a caller. The two existing `MacMediaCapabilityGateTests` precedence tests keep passing untouched; new Core tests drive the pure function directly, including the entitlement vectors from the WS3 fixture set (§3.2).

### 2.4 Stale daemon comments
Delete/correct the claims at `Core/Budget/BudgetGate.swift:63-66` and `AgentLensApp.swift:231-232` that the daemon enforces budgets. One honest comment: "daemon enforcement: planned, tracked in <issue>". File that issue.

### 2.5 Explicitly NOT in scope
- Merging iOS `HostedQuotaSubscriptionStore` with mac entitlement arbitration (different trust models: server-arbitrated vs client-arbitrated).
- De-forking BudgetSettings/BudgetLedger/BudgetRulesStore (architecturally divergent; drift gate remains their control).
- Daemon budget enforcement (follow-up issue).

## 3. WS3 — cross-platform enforcement contract tests

PR #1396 already landed the first WS3 infrastructure. This wave reuses that repo pattern: canonical fixture + byte-identical per-platform copies + cheap ubuntu pin job + per-platform loaders. Do not recreate the same fixtures, scripts, or workflows; extend the existing artifacts when WS1 adds new pure behavior.

### 3.1 Canonical fixture
Existing: `tests/fixtures/budget-enforcement/budget-enforcement-vectors.json`, `tests/fixtures/budget-enforcement/README.md`, and `tests/fixtures/budget-enforcement/entitlement-vectors.json`. Add vectors here only when WS1 changes the pure budget or entitlement contract.

Schema (v1):
```jsonc
{
  "schemaVersion": 1,
  "vectors": [
    {
      "id": "org-scope-label-match-blocks",       // unique, kebab-case
      "description": "org rule matched by account label blocks at 100%",
      "rules": [ {                                  // BudgetRule, shared string enums
        "id": "r1", "scope": "organization", "identifier": "acme-org",
        "period": "month", "amountUSD": 100, "behavior": "hardBlock",
        "isEnabled": true, "fallbackCredentialIDs": []
      } ],
      "request": {                                  // BudgetCredentialIdentity descriptor
        "slotID": "slot-1", "displayLabel": "work",
        "providerAccountID": null, "providerAccountLabel": "acme-org",
        "billingMode": "perUsage", "projectName": null, "estimatedCost": 1.0
      },
      "ledger": {                                   // spend per rule id; ABSENT key = unreadable
        "reference": "2026-07-01T12:00:00Z",
        "spend": { "r1": 99.5 }                     // "unreadable": ["r1"] marks a throwing read
      },
      "expected": {
        "decision": "block",                        // allow | warn | block | paused
        "ruleID": "r1",
        "fallbackCredentialID": null
      }
    }
  ]
}
```

Required coverage (each row = ≥1 vector; the pin job asserts the matrix is complete):
- every scope: `credential`, `project`, `global`, `organization`
- every behavior × threshold band: allow (<80%), warn (≥80%), block (≥100%), incl. `warnThenBlock` blocking at 100% without prior warn
- fail-closed: unreadable spend → block for block-capable behaviors, **warn** for `warnOnly`
- org prefilter: identifier vs each of the 4 identity fields, identity-less gateway credential passes prefilter, non-matching org rule ignored, blank-string account fields treated as missing
- fallback: resolved happy path, fallback disqualified by its own cap, by a global rule, by unreadable spend; fallback identity billingMode=unknown
- paused rules; subscription short-circuit (and "no ledger read" asserted where the harness can observe it)
- most-restrictive-wins ordering
- entitlement vectors (separate `entitlement-vectors.json`, same conventions): active-cloud-wins, lapsed-cloud-invisible, StoreKit-unbound-fails-closed, per-tier max-expiry merge, Ultra⇒Pro⇒Cloud implication

### 3.2 Consumers
1. **Core (PR-blocking today):** existing copy at `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/`, with `BudgetGateContractVectorTests.swift` loading the vector from `Bundle.module`.
2. **macOS app (PR-blocking today):** extend the existing app-gate resource/test path only if WS1 adds mac-specific seam coverage.
3. **iOS app:** same contract shape applies; PR-gating is handled by the mobile-gate work rather than by duplicating the WS3 fixture lane.
4. **Android (PR-blocking for budget changes today):** existing copy at `android/app/src/test/resources/budget-enforcement/`, with `com.openburnbar.data.budget` tests driven from the vector by `.github/workflows/android-budget-contract.yml`.
5. Windows: out of scope; the checker's copy list leaves room.

Each platform test asserts: vector count > 0, every scope enum value exercised, every vector id unique — a platform that silently loads half the file fails.

### 3.3 Drift pin
Existing: `scripts/ci/check-budget-enforcement-fixture.mjs` plus `.github/workflows/budget-enforcement-contract.yml`. Keep the current byte-identity, deletion, schema, and coverage-matrix checks as the pin. Extend the script only for new required coverage rows.

### 3.4 Android PR job
Existing: `.github/workflows/android-budget-contract.yml` runs setup-java 21 temurin + Gradle cache + Android setup, copies `android/app/google-services.json.template` to `android/app/google-services.json`, and runs `cd android && ./gradlew :app:testDebugUnitTest --tests "com.openburnbar.data.budget.*" --no-daemon` for Android budget changes. Full-suite Android PR CI remains a separate named decision (cost/benefit is Alberto's call); do not add a duplicate budget workflow.

### 3.5 Tripwire check
Fixtures under `tests/fixtures/`, `OpenBurnBarCore/Tests/**/Fixtures/`, `android/app/src/test/resources/` trip **nothing** in `check-no-suppressions.sh` (only `budgets/*.json` and `*baseline*.{xml,yml,yaml}` match). Do not name anything `budgets/…json`.

## 4. Named decision for Alberto (blocking Android enforcement, not the tests)

**Android `BudgetGate.evaluate()` has no production caller.** Wiring it into the Android request path (mirror of iOS `CLIAgentRelayChatTransport.swift:106-131`) is a behavior addition — Android users would start seeing budget blocks. Options:
- **A (recommended):** wire it to the relay chat transport exactly like iOS, same fail-closed contract, ship behind the existing budget-rules UI (users who created rules expect them to bind).
- **B:** land fail-closed + fallback + contract tests only (engine provably correct), leave the call site for a product decision later; ledger records `OPEN_WITH_NAMED_BLOCKER: android-enforcement-callsite`.

WS1/WS3 PRs are sequenced so both options stay open until Alberto answers.

## 5. WS6 — iOS composition seam (scoped to policy edges)

`AppServices.swift` documents a 62-singleton mesh. Wave 5 converts ONLY the edges the contract tests need to fake:
- `BudgetPolicyEnvironment`: a small struct holding `gate: BudgetGate`, `enforcement`, `entitlementStore` handles, built at app boot (where `AuthGateView.swift:55-79` assembles them today), injected via SwiftUI `.environment` / initializer injection into the views and transports that currently reach for `BudgetEnforcement.shared`.
- Call-site conversion is mechanical (GLM lane per written list); the environment type + boot wiring is critical-tier.
- No other singletons move this wave. The pattern is the precedent for future waves.

## 6. Execution lanes & sequencing

| Step | Lane | Tier | PR |
|------|------|------|----|
| Plan doc (this file) | conductor | critical | docs PR (merge first) |
| Fixture schema + canonical vectors + README | conductor/Fable | critical | PR-A |
| Core vector test + Core copy | Fable subagent | critical | PR-A |
| mac/iOS project.yml resource wiring + xcodegen | GLM (mechanical, per this plan) | GLM + critical review | PR-A |
| Pin script + ubuntu workflow + Android PR workflow | GLM from spec | GLM + critical review | PR-A |
| §2.1 identity hoist + §2.2 enforcement split + drift-baseline regen | GLM pure-moves; Core composer/estimator APIs by critical tier | mixed | PR-B |
| §2.3 entitlement arbitration extraction + vectors | Fable subagent | critical | PR-C |
| Android fail-closed + fallback + JUnit vector test | Fable subagent (Kotlin semantics = critical) | critical | PR-D |
| Android call site (if Option A approved) | critical | critical | PR-E |
| §5 BudgetPolicyEnvironment + call-site conversion | critical design + GLM call sites | mixed | PR-F |

Acceptance: all existing budget/entitlement suites pass untouched (Core 3, mac 19+6, iOS 26, Android 6+); every new Core behavior has a Core test; the coverage matrix in §3.1 is fully green on Core+mac+Android (iOS on harness); drift gate updated in the same PR as any pair change; enforce_admins never bypassed.
