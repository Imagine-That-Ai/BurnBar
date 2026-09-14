---
name: performance-efficiency
description: Speed up BurnBar with measured wins on graphics rendering, local GRDB mining, and quota discovery. Use when asked to improve performance, efficiency, frame rate, database scans, quota parsers, SwarmCanvas, DashboardLiveCostCurve, DatabaseWorkspaceView, or ProviderQuotaService.
---

# BurnBar performance efficiency

Goal: Make BurnBar feel instant on graphics rendering, local database mining, and quota mining, while keeping visuals and quota/usage semantics bit-identical.

Success means:
- Each of the three lanes has a written baseline (cost, measurement method, owning file).
- Each lane ships a measured win with tests, or an evidence-backed named blocker that the path already meets its budget.
- Displayed usage totals, quota remaining %, reset times, and confidence labels stay bit-identical on fixtures.
- Graphics stay visually identical at the existing motion budgets.

Stop when: all three lanes are closed with a win or named blocker, cheap relevant tests are green, and `docs/architecture/macos-performance.md` plus `CHANGELOG.md` record the change.

Paste-ready mission text lives in [`.agents/prompts/performance-efficiency.md`](../../prompts/performance-efficiency.md).

## Load first

Read these before editing:

1. [`docs/architecture/macos-performance.md`](../../../docs/architecture/macos-performance.md) — frame caps, `usagesVersion`, refresh-tick marker, swarm fills.
2. [`docs/architecture/background-cadence.md`](../../../docs/architecture/background-cadence.md) — the only home for timer-driven background work.
3. [`docs/PERFORMANCE_SCALABILITY_REVIEW.md`](../../../docs/PERFORMANCE_SCALABILITY_REVIEW.md) — known N+1, MainActor, and scan costs.
4. [`docs/SCHEMA_SQLITE.sql`](../../../docs/SCHEMA_SQLITE.sql) — GRDB schema; update it with any migration.
5. [`docs/PROVIDERS.md`](../../../docs/PROVIDERS.md) — quota confidence and session-log paths.
6. [`docs/runbooks/slos.md`](../../../docs/runbooks/slos.md) — search p50/p95 and dashboard refresh budgets.
7. [`.agents/skills/swiftui-expert-skill/references/performance-patterns.md`](../swiftui-expert-skill/references/performance-patterns.md) — SwiftUI invalidation rules.

Query mem0 (`user_id` `burnbar`) for navigation, then verify every fact against committed files.

## Method

1. **Measure.** Capture the current cost with Instruments, `os_signpost`, `OpenBurnBarQueryTracer`, parser timings, or refresh skip counts. Write the baseline in the PR body before claiming a win.
2. **Search.** Extend the existing ticker, cache, checkpoint, or cadence. Add a type only when no current owner exists.
3. **Change the hot path.** Keep derived work off `@MainActor`. Rebuild view models from `usagesVersion` or an `Equatable` cache key. Batch GRDB reads. Resume parsers from `parser_checkpoints`.
4. **Pin it.** Add tests that fail if the skip gate, query budget, frame clamp, or checkpoint is removed.
5. **Record it.** Update `docs/architecture/macos-performance.md` for Mac graphics/refresh wins and `CHANGELOG.md` for user-visible speed.

## Lane 1 — Graphics rendering

Own the live draw path, then the data that feeds it.

| Surface | Where | What "fast" looks like |
|---|---|---|
| Ember swarm wallpaper / tray | `OpenBurnBarCore/.../SwarmCanvasView.swift` | Honor `maxFrameRate` (30 Hz wallpaper, battery-aware). Bucket fills by `RGBA.bucketKey`. Coalesce pointer moves. Use async Canvas. |
| Live cost curve | `AgentLens/Views/Dashboard/Components/DashboardLiveCostCurve.swift` | Rebuild samples only when `usagesRevision` / cache key changes. Keep static `Shape` drawing for the all-day dashboard. |
| Quota dials | `AgentLens/Views/Dashboard/Quota/QuotaArcDial.swift` | Animate 0 → actual once on appear. Unavailable buckets stay dashed, not zero. |
| Chart Studio / Insight canvases | `OpenBurnBarMobile/Views/ChartStudio/`, Android `ui/chartstudio/`, Insight canvas views | Replay and layout from cached canvas models. Keep grid math pure and testable. |
| Constellation / substrate chrome | `ConstellationBackgroundView`, `SwarmSubstrateBox` | TimelineView for on-screen motion; idle when off-screen. |

Rules:

- Pass `usagesVersion` (or a tiny cache key) into expensive views. Compute with a pure `static` function, cache in `@State`, rebuild on version change.
- Use `TimelineView(.periodic)` for visible motion. Let off-screen views sleep.
- Keep organic wallpaper motion at or under 30 Hz. Interactive surfaces may run higher inside `sanitizedFrameRate`'s `[1, 120]` clamp.
- Preserve Reduce Motion and Low Power Mode behavior already wired through power-source monitoring.

## Lane 2 — Database mining

Own the local GRDB/SQLite mine: usage rows, workspace snapshots, search hydration, conversation text, parser watermarks.

| Surface | Where | What "fast" looks like |
|---|---|---|
| Usage refresh tick | `DataStoreCoordinator.reloadUsagesIfChanged`, `UsageTableWriteMarker` | Idle ticks are one actor hop when `token_usage` content is unchanged and the time window has not rolled. |
| Database workspace | `AgentLens/Views/Dashboard/DatabaseWorkspaceView.swift` | Rebuild snapshots on debounced content change, not a poll. |
| Query budgets | `AgentLens/Services/DataStore/OpenBurnBarQueryTracer.swift` | `resetLog()` then `assertMaxQueries(count:)` around the operation. |
| Search / FTS | `SearchService`, `conversations_fts`, `search_chunks_fts` | JOIN hydration in one trip. Keep hybrid search inside the SLO in `docs/runbooks/slos.md` (p50 `< 120 ms`, p95 `< 350 ms`). |
| Incremental parse | `parser_checkpoints`, `RefreshBackgroundWork` | Resume from the checkpoint token. Walk new files only. |
| Indexes | `docs/SCHEMA_SQLITE.sql` plus GRDB migrator | Add a migration when `EXPLAIN QUERY PLAN` shows a scan an index would collapse. |

Rules:

- Configure the tracer with `OpenBurnBarQueryTracer.configure(in: &configuration)` before opening a test database.
- Batch inserts and hydrations. Prefer SQL `GROUP BY` / covering indexes over loading `[TokenUsage]` onto the main actor to reduce it.
- Keep `fetchAllUsage()` call sites inside the ratchet in `scripts/debt/check-usage-refresh-tick-budget.sh`.
- Pair every new migration with `docs/SCHEMA_SQLITE.sql`.

## Lane 3 — Quota mining

Own how BurnBar learns remaining quota from local logs, vendor APIs, and hosted refresh.

| Surface | Where | What "fast" looks like |
|---|---|---|
| Staleness gate | `ProviderQuotaService.refreshIfNeeded` | Skip a full refresh when the snapshot is younger than `maxAge` (5 min on appear, 15 min automatic). |
| Fan-out | quota refresh orchestration | At most four concurrent provider/account fetches. |
| Local parsers | `AgentLens/Services/LogParser/` (`GrokParser`, Claude, Codex, …) | Read `~/.codex/sessions/`, `~/.claude/projects/`, `~/.grok/sessions/` incrementally via checkpoints. |
| Snapshot store | `provider_quota_snapshots` | Upsert on the identity index `(providerID, source, sourceID, period)`. |
| Hosted refresh | `functions/src` scheduled/callable quota paths | Resilience helpers + `providerFetch`. Reuse server rollups (`usage_rollups/90d`) instead of downloading every usage doc. |
| Confidence | `docs/PROVIDERS.md` | Keep `.exact` / `.estimated` / `.unavailable`. Show "Not available" when there is no source. |

Rules:

- Treat `refreshIfNeeded` as the single staleness source of truth.
- Parse new bytes only. Checkpoint after a successful scan.
- Keep hosted secrets in Secret Manager. Local default tracking reads usage logs, not API keys.
- New provider HTTP in `functions/src` goes through `providerFetch` from `functions/src/providers/httpClient.ts`.

## Validation

Run the cheapest relevant check for the files you touched:

- Graphics / dashboard caches: `./scripts/test-openburnbar-app.sh` with `OpenBurnBarTests/SwarmCanvasFrameRateTests`, `DashboardLiveCostCurveCacheTests`, `DataStoreUsagesVersionTests`.
- Database / refresh tick: `OpenBurnBarTests/RefreshTickPerfTests`, `OpenBurnBarDatabaseMigrationTests`, plus tracer assertions in the new test.
- Quota: `OpenBurnBarTests/ProviderQuotaServiceTests` and the adapter/parser tests for the provider you changed.
- Shared schema: keep `docs/SCHEMA_SQLITE.sql` in lockstep with the migrator.

Record before/after in the PR: metric, method, baseline, after, test that pins it.

## Return shape

Write the PR so a reviewer can decide from the description:

1. Baseline per lane.
2. What changed and why that path was the cost.
3. After measurement.
4. Tests and commands run.
5. Visual / quota / usage invariance.
6. Named leftover blockers, or "all three lanes closed."
