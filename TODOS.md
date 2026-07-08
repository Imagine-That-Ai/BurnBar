# TODOS

## Agent Roadmap

### Add Browser Tools After Core Agent Stabilizes

**What:** Add browser automation tools to OpenBurnBar after the daemon-native coding agent is stable.

**Why:** Browser actions unlock end-to-end UI debugging, auth-flow reproduction, and web app verification that terminal and file tools alone cannot cover.

**Context:** The current review intentionally kept browser tooling out of the v1 coding-agent lake so the team can ship planning, context selection, recovery, journaling, and workspace execution first. OpenBurnBar already has the right daemon/extension split, so browser tools should be added as another policy-governed tool family after the single-agent core is proven reliable.

**Effort:** L
**Priority:** P2
**Depends on:** Stable daemon-native planner, recovery engine, policy engine, and run journal

### Add Rich Run Playback And Diff Inspector

**What:** Add a richer run playback view in the Cursor extension showing plan steps, tool calls, applied edits, terminal commands, approvals, and recovery decisions.

**Why:** Users will need to understand what OpenBurnBar did, why it paused, and how it recovered when real coding runs become common.

**Context:** This review chose a daemon-owned persistent run journal specifically so richer playback can be added later without redesigning the backend. The current extension surfaces only compact run detail and recovery hints; once the full coding agent lands, that will not be enough for trust and debugging.

**Effort:** M
**Priority:** P2
**Depends on:** Run journal with typed planner, tool, approval, and recovery events

### Add Multi-Agent Orchestration After Single-Agent Matures

**What:** Add multi-agent orchestration for parallel investigate/implement/verify workflows after the single-agent system is stable.

**Why:** Multi-agent execution can improve throughput on larger tasks, but it is not necessary to deliver a full single-agent coding experience.

**Context:** The current review explicitly kept multi-agent work out of scope because it would expand the run graph, approvals, arbitration, UI, and test matrix significantly. This should only be revisited once the single-agent daemon-native flow is reliable and well-observed in production-like use.

**Effort:** XL
**Priority:** P3
**Depends on:** Stable single-agent planner, policy engine, run journal, and reconnect/arbitration behavior

### Expand Provider And Model Coverage After Core Agent Launch

**What:** Expand OpenBurnBar’s routed provider/model support beyond the current core set after the full coding agent is stable.

**Why:** Broader model support increases user choice and market coverage, but it should not be mixed into the core agent stabilization work.

**Context:** OpenBurnBar’s current provider scope is intentionally narrow in the docs and current architecture. This review kept provider breadth separate from agent depth so routing/auth/test complexity does not distract from planner, context, recovery, and execution reliability.

**Effort:** L
**Priority:** P3
**Depends on:** Stable daemon-native coding agent core and provider-routing test coverage

## In-code deferrals (audited 2026-07-07, post wave-4 remediation)

Known deferred items living in code comments, each verified against the code on the date
above. Everything previously listed here that no longer exists in code has moved to
"Resolved" below — this file lists only what is still deferred.

- **iOS project-scope budget spend is not measurable** — `UsageRollupDoc` carries no
  per-project breakdown, so `OpenBurnBarMobile/Models/BudgetLedger.swift` (`rollupSpend`,
  `.project` case, ~line 173) throws `projectScopeUnsupported` and the gate fails closed
  (block / warn-only warn) instead of silently enforcing nothing. Real measurement needs
  per-project summaries added to the Cloud Functions rollup pipeline and the rollup schema.
  *Owner note: budget lane; requires functions/ rollup schema work, then delete the throw
  and the Budget Center "not measurable on iOS" copy.*
- **iOS budget periods approximate rollup windows** — `rollupWindowKey(for:)` in
  `OpenBurnBarMobile/Models/BudgetLedger.swift` (~line 238) maps week→7d and month→30d
  because rollups don't align with calendar periods. Conservative but inexact near period
  boundaries. *Owner note: budget lane; needs calendar-aligned rollup windows server-side.*
- **BudgetLedger backend fork is architectural** — macOS sums raw `token_usage` SQL
  (`AgentLens/Services/DataStore/BudgetLedger.swift`); iOS sums Firestore rollups
  (`OpenBurnBarMobile/Models/BudgetLedger.swift`). Intentional (no raw SQL on mobile), and
  guarded: `scripts/ci/check-budget-fork-drift.sh` fails CI when either side of the pair
  (or BudgetEnforcement/BudgetSettings) drifts without a reviewed baseline update. The gate
  itself is no longer forked (single `BudgetGate` in
  `OpenBurnBarCore/Sources/OpenBurnBarCore/Budget/BudgetGate.swift`). *Owner note:
  intentional; revisit only if mobile ever gets a local usage table.*
- **FTS rebuild TODO(C10) page reclamation** — the conversations FTS one-shot repair
  rebuilds rows but does not reclaim freed pages;
  `AgentLens/Services/DataStore/OpenBurnBarDatabase.swift:1528` (after PR #1353's split:
  `OpenBurnBarDatabase+MigrationsV41toV51.swift`). *Owner note: datastore lane; needs an
  incremental-vacuum pass gated on idle.*
- **Diverged Core database twin** —
  `OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase.swift` (~2089 lines) is a
  Linux/SQLCipher-ordered near-copy of the AgentLens migrator and was intentionally left
  untouched by the wave-4 decomposition (PR #1353). *Owner note: linux lane; reconcile or
  drift-gate it the same way the budget forks are gated.*

## Resolved (removed from deferrals after verification)

- ~~SmartHub voice routine hook is a no-op~~ — `POST /voice-refresh` now queues a real
  voice event (`SmartHubBridgeServer.swift`; `voice:"unsupported"` reply is gone).
- ~~BudgetGate Phase 4B fallback resolution deferred~~ — fallback resolution landed
  (`d27db38235`, `faf030625e`) and the gate is now a single Core implementation with
  regression locks on the self-exclusion normalization (wave-4 PRs #1351/#1356).
- ~~MacCloudEntitlementStore reads "free" pending macOS StoreKit~~ — StoreKit entitlement
  reading is integrated; local StoreKit now also outranks a lapsed cloud doc (PR #1346).
- ~~iPhone→Mac calling not implemented~~ — wired over the Mercury control stream
  (`2357e37983`, hardened in `b133d1bf53`).
- ~~MissionGroupObserver Phase B+ synthesis not implemented~~ — synthesis dispatch and
  summary plumbing exist in `MissionGroupObserver.swift`.
- ~~Org-scope budget aggregation approximated (renamed-account gap)~~ — iOS org rules now
  discover member accounts across rollup windows, mirroring the macOS subquery (PR #1351).
  The remaining window-alignment approximation is tracked above.
