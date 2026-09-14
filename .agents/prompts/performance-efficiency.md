# BurnBar performance mission prompt

Paste the **Mission brief** below into Cursor, Claude Code, Codex, or Zenith. Load [`.agents/skills/performance-efficiency/SKILL.md`](../skills/performance-efficiency/SKILL.md) as the operating method.

---

## Why this prompt exists

The seed request was:

> improve performance across the board; efficiency is key for everything but specifically for rendering of our graphcis, and mining databases and quotas for burnbar

That seed names the right product pressure and then leaves an agent with no destination, no measurement, and no stop. This rewrite keeps the intent and makes the work finishable.

---

## Mission brief

```
Goal: Make BurnBar feel instant on the three surfaces that currently burn CPU and I/O — graphics rendering, local database mining, and quota mining — while keeping displayed numbers, visuals, and parser/quota semantics bit-identical to today.

Success means:
  - A written baseline for each lane: what is slow, how it was measured, which file and function own the cost.
  - Each lane either ships a measured win with tests, or records a named blocker with evidence that the path already meets the documented budget.
  - Graphics stay visually identical: same swarm motion, same quota dials, same cost curves, same Chart Studio canvases.
  - Quota remaining %, reset times, confidence (.exact / .estimated / .unavailable), and usage totals stay bit-identical on fixtures.
  - Database changes use existing GRDB migrations plus a matching docs/SCHEMA_SQLITE.sql update when indexes or tables change.
  - The PR body includes a review map, before/after measurements, validation run, and remaining risks.

Stop when: all three lanes have a measured win or an evidence-backed named blocker, tests for the touched path are green, and macos-performance.md plus CHANGELOG record what changed.

Constraints:
  - Efficiency is the product requirement. Spend the work where frames, scans, and quota refreshes actually cost CPU, disk, or network.
  - Extend the existing performance architecture. Reuse usagesVersion tickers, bucketed Canvas fills, refreshIfNeeded, OpenBurnBarQueryTracer, BackgroundCadenceCoordinator, parser_checkpoints, and UsageTableWriteMarker.
  - Preserve Computer Use safety invariants and quota confidence labels from docs/PROVIDERS.md.
  - Shared OpenBurnBarCore changes must keep macOS, iOS, Android, Windows, and Linux consumers compiling.

Work the three lanes in this order: measure, then graphics, then database mining, then quota mining.

Lane 1 — Graphics rendering
  Read docs/architecture/macos-performance.md and .agents/skills/swiftui-expert-skill/references/performance-patterns.md first.
  Profile and then speed up the live draw path:
    - SwarmCanvasView (wallpaper, tray, substrate): frame-rate clamp, bucketed fills, pointer coalescing, battery-aware cadence.
    - DashboardLiveCostCurve: versioned sample cache, static Shape drawing on a dashboard that stays open all day.
    - QuotaArcDial and SubscriptionCard: ring animation on appear only.
    - Chart Studio / Insight canvases on macOS, iOS, and Android.
  Keep TimelineView for on-screen motion. Rebuild derived chart data only when usagesVersion or an Equatable cache key changes. Cap wallpaper and idle chrome at the existing 30 Hz organic-motion budget unless a surface is actively interactive.

Lane 2 — Database mining
  Read docs/SCHEMA_SQLITE.sql, docs/PERFORMANCE_SCALABILITY_REVIEW.md, and AgentLens/Services/DataStore/OpenBurnBarQueryTracer.swift.
  Profile and then speed up the local GRDB/SQLite mine:
    - token_usage refresh ticks (reloadUsagesIfChanged / UsageTableWriteMarker).
    - DatabaseWorkspaceView snapshot rebuilds.
    - Search hydration, FTS, and conversation fullText scans.
    - Parser checkpoint incremental scans in RefreshBackgroundWork.
  Batch reads. Use covering indexes already in schema, and add a migration only when EXPLAIN QUERY PLAN shows a scan that an index would collapse. Assert query counts with OpenBurnBarQueryTracer.resetLog() / assertMaxQueries(count:). Keep idle refresh ticks to one actor hop when token_usage content is unchanged.

Lane 3 — Quota mining
  Read docs/PROVIDERS.md, docs/HOSTED_QUOTA_SYNC.md, ProviderQuotaService.refreshIfNeeded, and the per-provider adapters under AgentLens/Services/LogParser/ plus OpenBurnBarCore quota adapters.
  Profile and then speed up how BurnBar discovers remaining quota:
    - Local session-log parsers (Codex ~/.codex/sessions/, Claude ~/.claude/projects/, Grok ~/.grok/sessions/, and the rest of the catalog).
    - parser_checkpoints so re-scans resume instead of walking the whole tree.
    - ProviderQuotaService.refreshIfNeeded with the existing staleness gate and four-wide fan-out cap.
    - provider_quota_snapshots persistence and the hosted refresh path in functions/src.
  Keep confidence labels honest. Reuse cached snapshots when they are fresher than maxAge. Parse new bytes only. Leave "Not available" providers as unavailable.

Method
  Search existing types before adding new ones. Query mem0 (user_id burnbar) for navigation, then verify against committed files.
  Measure before changing: Instruments / os_signpost / query tracer / parser timings / refresh skip counts.
  Change one coherent win per commit when possible; keep the PR as one reviewable performance unit if the three lanes share a cache or schema change.
  Add or update tests in AgentLensTests (bundle OpenBurnBarTests), OpenBurnBarCore tests, and daemon tests for the touched behavior.
  Run the cheapest relevant checks for the touched area, then commit, push, and open a PR that a reviewer can decide from measurements alone.

Return
  A PR whose description a staff engineer can review without reproducing the profile: baseline, change, after, tests, visual/quota invariance, and leftover named blockers.
```
