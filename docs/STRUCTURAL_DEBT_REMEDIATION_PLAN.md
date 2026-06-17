# Remediate remaining structural debt — execution plan

> Approved remediation plan for the 7-item structural-debt audit. Verified against the live tree on
> branch `feature/the-wand-gated-fanout` (2026-06-16) with an adversarial confidence pass.
> Mirror of `~/.claude/plans/remaining-structural-debt-with-elegant-zephyr.md`.

## Context

A debt analysis flagged 7 structural items in OpenBurnBar. Parallel verification against the live
tree, then an adversarial confidence pass, confirmed some, **corrected two as non-debt**, **found a
latent production bug**, and **caught a wrong-direction fix in the first draft of this plan**. The
scope chosen is the full refactors (not containment) and document-only for the two non-debt items.

This is a **multi-PR program**, sequenced so every PR compiles, ships, and is green on its own. CI
ratchets land first to freeze each baseline and stop regression during paydown.

## Confidence pass — loopholes found and how the plan changed

1. **🔴 (fixed) The DataStore strategy was backwards.** Draft said "move bodies onto `DataStoreActor`
   and `await actor.foo()`." Production uses a GRDB **`DatabasePool` (WAL = concurrent reads)** and the
   `nonisolated` `Sendable` stores let many threads read in parallel today. Funneling ~900 calls through
   one **serial actor executor would destroy read concurrency** and regress dashboard/search.
   **Correct fix:** convert the **store layer** to GRDB **async** (`try await dbQueue.read/write`), which
   runs on the pool's reader connections and *preserves* concurrency. Already idiomatic here (7 existing
   `await dbQueue.read` sites: DataStore.swift:213, BudgetForecast/Ledger, FusionImpactLedger). **Do not
   serialize reads through an actor.**
2. **(fixed) Understated surface.** The real query methods aren't the 153 coordinator pass-throughs —
   they're **~207 store methods** in `*Store+*.swift` extensions, each wrapping one sync `dbQueue.read/write`
   closure. The async conversion is a **two-layer** change (store methods + pass-throughs) plus call sites.
3. **(verified, de-risked) No async cascade inside the store layer.** Store instance methods call
   **static `(_ db: Database)` helpers inside the closure**, not sibling instance methods — so async-ifying
   one method doesn't cascade to others in the store. Confirmed by grep (zero sibling-call hits).
4. **(verified) Containment.** All 92 `.shared` and all 615 app-side `dataStore.*` references are in
   **AgentLens only** — **zero** in OpenBurnBarCore, mobile, or daemon. Neither refactor crosses a module
   boundary. **But** there are **311 more `dataStore.*` call sites in AgentLensTests** → true call-site
   surface ≈ **926**, not ~500. Effort revised up accordingly.
5. **(verified) `init`/`Codable`/`deinit` call sites = empty.** The only sync-context blockers are
   SwiftUI computed getters doing sync SQLite, concentrated in `PrivacyIndexingSettingsView.swift:434-447`
   (4 sites) → convert to `@State` + `.task`.
6. **(verified) DI prerequisites hold.** `AccountManager` conforms to **both** `AccountManaging`
   (Protocols/AccountManaging.swift:19) and `AccountManagerProtocol` (Protocols/AccountManagerProtocol.swift:78),
   so service injection via `AccountManaging` is safe.
7. **(verified) Item 3 is barely debt.** CloudSyncService's `uploadPending`/`downloadRemoteData`/
   `fetchCloudTotal` are already `async` and delegate to off-main services; `@MainActor` is only for the
   `@Observable` UI state — explicitly allowed by ADR 002. **Downgraded to optional.**
8. **(verified) Switcher is the one hard exception.** 75 of 91 direct sub-store accesses are
   `switcherStore`, consumed through a **public, `Sendable`, synchronous** `SwitcherProfileStoreAdapter`
   (OpenBurnBarCore). Async-ifying the store breaks that cross-module sync contract → see **Open Decision**.

### Non-debt (document only)
- **Item 4** OpenBurnBarCore: 84K not 104K; `PixelClockPreviewView` has no platform guards and is correctly
  shared by iOS+macOS. Premise false.
- **Item 6** Rust remote "stubs": intentional composition seams over 5,350 lines of real crates (ADR 008).

### Latent bug found (item 2)
**Two live `SettingsManager` instances in production.** `context.settingsManager` is `SettingsManager()`
(AgentLensApp.swift:993) while `.shared` is a separate lazy instance. Both back `UserDefaults.standard` so
scalar reads mostly converge, but `@Observable` change-tracking and debounced writes don't cross instances
→ a real stale-read window (AppDelegate wallpaper lagging the Settings UI). PR #B1 fixes it in one line.
`AccountManager` is single (context uses `.shared`).

## Scope
**In:** items 1, 2, 3 (optional), 5, 7 + CI enforcement gates + docs for 4 & 6.
**Out (follow-ups):** the other ~59 `static let shared` singletons; OpenBurnBarCore split; Rust platform
impl; async-ifying `SwitcherProfileStoreAdapter` (Decision B); `UsageAggregator`/`OpenBurnBarDaemonManager`
`@MainActor` demotion.

---

## Foundation — CI ratchets first (PR #0)

ADR 001/002 have **no** automated enforcement today. Land the gates first so baselines can only shrink.
**Reuse the existing idiom verbatim:** `scripts/ci/knip-ratchet.sh` (baseline JSON in `budgets/`,
`::error::`+`exit 1` on growth, `::notice::` on drop) and `tools/schema-sync/check-legacy-budget.mjs`.

1. **`scripts/debt/check-datastore-isolation-budget.sh`** + `budgets/datastore-isolation-baseline.json` —
   counts `nonisolated` members on `DataStore.swift`/`DataStoreCoordinator.swift`/`DataStore+*.swift` **and**
   remaining sync `dbQueue.read/write` store-method sites (start = current ~207). Decrement each stage.
2. **`scripts/debt/check-singleton-budget.sh`** + `budgets/singleton-baseline.json` —
   counts `SettingsManager.shared`+`AccountManager.shared` in AgentLens (exclude `AgentLensTests`, the one
   construction site, and the two `Protocols/*Protocol.swift` doc-comments). Baseline = **92** → target **0**.
   Optional 2nd metric: total `static let shared` in AgentLens (= **61**), budget stable, to stop new singletons.
3. Wire both into `.github/workflows/code-quality.yml` beside the existing `knip-ratchet.sh` steps.

---

## Workstream A — DataStore off-main via GRDB async (items 1 & 7)

**Goal:** all SQLite I/O async/off-main, no `nonisolated` escape hatches, sub-stores not reachable raw —
**while preserving `DatabasePool` read concurrency**.

**Two-layer mechanical recipe (per method):**
- **Layer 1 — store methods (~207).** `func foo(...) throws -> T { try dbQueue.read/write { db in … } }`
  → `func foo(...) async throws -> T { try await dbQueue.read/write { db in … } }`. The closure/SQL and the
  static `(_ db:)` helpers are **unchanged**; no sibling cascade.
- **Layer 2 — coordinator pass-throughs (153).** `nonisolated func foo() throws { try store.foo() }`
  → `func foo() async throws { try await store.foo() }`. Stores are `Sendable`, so the coordinator awaits
  them **directly** — no serial actor hop. `@MainActor func … async` is fine: the `await` suspends main
  (frees UI) while GRDB reads on its pool.
- **Call sites (~615 app + ~311 test).** `try x` → `try await x`. The async-ness cascades up to the
  nearest async boundary (`Task {}`, `.task`, button action, already-async service method). Terminators
  that can't await: the `PrivacyIndexingSettingsView` getters (→ `@State` + `.task`). `init`/`Codable` = none.
- **DataStoreActor's role shrinks:** it stops being a per-call serial gate. Its 9 composite async methods
  become `await store.x()` forwarders or move into store methods. Keep it (or a plain holder) only as the
  store **owner**; remove the 15 `nonisolated` store accessors so callers can't reach raw stores.
- **Direct sub-store accesses (91):** `providerAccountStore` (11) needs ~new async pass-throughs added;
  **`switcherStore` (75)** is the exception — see Open Decision.

**Stage order (each a self-contained, compiling PR; decrement the ratchet each time):**
Device (4) → TextExpansion (7) → Usage (10) → Artifact (19) → ControlPlane (15) → Projection (32) →
Conversation (40) → Search (26) → ProviderAccount (+new pass-throughs) → **Switcher (75 — hard)** →
remove `nonisolated` exposure (compiler-guided) → tests/cleanup. A stage = that store's Layer-1 methods +
its Layer-2 pass-throughs + all app **and test** call sites, in one PR.

**Key files:** `AgentLens/Services/DataStore/{DataStore.swift,DataStoreCoordinator.swift,*Store*.swift,DataStore+*.swift}`,
`OpenBurnBarCore/.../SwitcherBrowserLaunchService.swift` (Switcher). **Tests:** `AgentLensTests` DataStore
suites + the 311 test call sites; use `DataStoreCoordinator.makeInMemoryForTesting()` (DatabaseQueue — async
works there too).

---

## Workstream B — Singleton DI retirement (item 2 + the dual-instance bug)

Retire `SettingsManager.shared`/`AccountManager.shared` onto the **existing** composition root
`OpenBurnBarRuntimeContext` (OpenBurnBarStartupRecovery.swift:181), which already holds both instances and
is injected via `.environment(...)`. Contained to AgentLens (92 sites; 34 in AppDelegate, 15 in
SwitcherDiscoveryService). Views → `@Environment(SettingsManager.self)`/`@Environment(AccountManager.self)`;
AppDelegate → property injection (mirrors `dataStore` at AppDelegate.swift:32, assigned AgentLensApp.swift:1390);
services → constructor injection via `AccountManaging`.

**Phased PRs (green throughout):**
- **#B1 — collapse to one instance (one line; fixes the bug; highest value/lowest risk).**
  AgentLensApp.swift:993 `SettingsManager()` → `SettingsManager.shared`. Every later flip becomes a true no-op.
- **#B2 — inject `accountManager` into the SwiftUI environment** (injected nowhere today) at the
  dashboard / menu-bar-popover / Mercury-chrome roots **before** converting Bucket-A views (a missing
  `@Environment(Observable)` is a runtime fatalError, so root-first, in the same PR). Fix the two
  optional-fallback sheets (`SessionDetailView.swift:13`, `ContextPackSheet.swift:504`).
- **#B3 — services (Bucket C)** except SwitcherDiscoveryService: constructor-inject the stray readers
  (ComputerUseSessionCoordinator, CLIAgentRelayChatExecutor:168, TextExpansionSyncService:41,
  MacMediaCapabilityGate:71, the `deviceId`/`userID` readers).
- **#B4 — the two heavy files** (53 of 92): SwitcherDiscoveryService (15) + AppDelegate (34). Isolate it.
  Move the wallpaper view-model **default-value** reads (AppDelegate.swift:1465) into a post-injection
  `didSet` configure step (they run before injection otherwise).
- **#B5 — tests off `.shared` + deprecate + delete.** Convert the ~7 test offenders mutating global
  `SettingsManager.shared` to `makeSettingsManager()` (AgentLensTests/Support/SettingsTestSupport.swift:157)
  / `FakeAccountManager` (CloudSyncTestSupport.swift:8); rewrite the two construction sites to `Type()` and
  the protocol doc-comments; mark `static let shared` `@available(*, deprecated)`; drive ratchet to 0; delete.

**Leave alone:** DataStoreCoordinator.swift:188 reads `UserDefaults` directly *by design* (runs before
SettingsManager exists). Do not convert it to a SettingsManager read; note in the PR.

---

## Workstream C — bounded fixes (items 3 & 5)

- **Item 3 — CloudSyncService (OPTIONAL, low value).** Already ADR-compliant: I/O delegated off-main,
  `@MainActor` only for `@Observable` UI state (which ADR 002 explicitly allows). The only "debt" is that
  `update-tech-debt-metrics.sh` counts class-level `@MainActor` mechanically. If pursued: extract the 6 UI
  props into `@Observable @MainActor CloudSyncState`, demote `CloudSyncService` to a non-`@MainActor`
  coordinator updating state via `MainActor.run`, shrink the facade metric 3→2. Recommend deferring with
  `UsageAggregator`/`OpenBurnBarDaemonManager` as a single later "demote the 3 facades" PR.
- **Item 5 — migrate one legacy schema domain to TypeSpec.** Generated emitters already exist for
  `insights`, `provider-account`, `usage-quota` (functions/src/types/generated/). **Spike first** to confirm
  one emitter fully covers its legacy surface, then point runtime callables at the generated types, delete
  the legacy domain module, and **ratchet** `budgets/hand-maintained-ts-baseline.json` (`loc` 2696 → new;
  update `note`). Enforced by `tools/schema-sync/check-legacy-budget.mjs`.

## Workstream D — document non-debt (items 4 & 6)
Add a `docs/TECH_DEBT_STRATEGY.md` / ADR note with the evidence (84K not 104K; PixelClockPreviewView
correctly shared; Rust seams intentional per ADR 008) so they stop resurfacing. No code change.

---

## Cross-workstream sequencing
1. **PR #0** — both CI ratchets (nothing can regress after).
2. **PR #B1** — one-line dual-instance fix (immediate correctness win).
3. Workstreams **A**, **B**, **C/5**, **D** proceed in parallel (independent files; A is the long pole).
4. **PR #B5** (delete `.shared`) and DataStore "remove nonisolated exposure" land **last** in their chains.

## Verification
- **Build + tests after every PR:** build the `AgentLens` scheme; run `AgentLensTests` (DataStore, CloudSync,
  Settings/Account suites). Functions (item 5): `npm run build --prefix functions` + `node
  tools/schema-sync/check-legacy-budget.mjs`.
- **Run new gates locally:** `bash scripts/debt/check-datastore-isolation-budget.sh`,
  `bash scripts/debt/check-singleton-budget.sh` (must pass; baselines decrement as PRs land).
- **Manual smoke** (`verify`/`run` skill): DataStore stages — dashboard, search, session logs, projects,
  switcher load/write correctly **and feel responsive under load** (proving reads still run concurrently, no
  serialization regression). PR #B1 — change a setting; AppDelegate wallpaper/menu-bar reflect it immediately.
- **No-regression bar:** behavior identical except intended wins (off-main I/O, single settings instance,
  frame-late counts on the few getter→`.task` conversions). Spot-check Instruments/main-thread hangs on a
  search-heavy screen before/after a DataStore stage.

## Open decision (blocks DataStore "Switcher" stage only)
`switcherStore` (75 direct accesses) is read via the **public synchronous** `SwitcherProfileStoreAdapter`
used cross-module by `SwitcherBrowserLaunchService` + `CLIProfileStreamFailoverRunner`.
- **A (recommended):** keep `switcherStore` sync + a **single documented `nonisolated` exception**, ratchet
  pinned at 1. Reaches "1 documented exception," not literal 0. Low risk, no cascade.
- **B:** async-ify the public protocol — cascades to ~7 types across the module boundary; post-1.0.
Proceeding with **A**, tracking **B** as follow-up unless told otherwise.

## Honest effort & scope dial
Workstream A is large: ~207 store methods + 153 pass-throughs + ~926 call sites (app+test), all mechanical
but voluminous — realistically a multi-week, ~12-PR effort (or heavily parallelized). It is the long pole;
B/C/D are days. **Scope dial available:** "full" (async-ify all store methods, per the user's choice) vs.
"main-reachable only" (async-ify just methods reachable from `@MainActor`, the actual UI-blocking ones, and
leave already-off-main paths sync). Defaulting to **full** unless told to limit.

## Out of scope / tracked follow-ups
Other ~59 `static let shared` singletons (2nd ratchet metric stops new ones); `UsageAggregator` +
`OpenBurnBarDaemonManager` `@MainActor` demotion; OpenBurnBarCore SharedModels split; Rust per-platform
capture/encode/inject (ADR 008); `SwitcherProfileStoreAdapter` async-ification (Decision B).
