# P01 — Dashboard overview + cost ticker

**Wave 1 · Route: `overview` · Replaces `OverviewSurface`'s generic data section with the real dashboard.**

## Mission

Rebuild the macOS dashboard overview as the Linux home surface: daemon health hero, live cost ticker, usage summary tiles with sparklines, and recent-activity feed. This is the first surface a user sees; it sets the craft bar for every other packet.

## Read first

- Foundation: `docs/linux-port/ui-parity/README.md` §1–§2 (ground rules, foundation reference).
- Current Linux surface: `apps/linux-desktop/src/surfaces/OverviewSurface.tsx`, `DaemonDataSection.tsx`.
- macOS oracle: `AgentLens/Views/Dashboard/CastleGreatHallView.swift`, `AgentLens/Views/Dashboard/Components/BurnBarTopRail.swift`, `BurnRailBudgetChip.swift`, `CacheHitRateView.swift`, `AgentLens/Views/Components/MiniSparkline.swift`, `SessionLedgerSection.swift`.
- Data semantics: `AgentLens/Services/` usage rollup stores; daemon RPC in `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCUsage.swift`.

## Data contract

1. Discover the usage/rollup RPC methods in `BurnBarDaemonServer+RPCUsage.swift` (do not invent names).
2. Extend the bridge per README §2: Tauri command `usage_summary` → `LinuxShellBridge.usageSummary()` returning `{ todayTokens, todayCostUsd, sevenDay: number[], recentEvents: {id,title,detail,at}[] }` mapped from the real RPC response.
3. Fixture path: append `overview` rows to `FIXTURE_ROWS` only if shapes change; add a `fixtureUsageSummary()` to `src/daemonFixture.ts` mirroring the live shape.
4. Honest tri-state: live (bridge ok) / fixture (fixture mode) / `OfflineNotice` (no daemon). Loading state while the invoke is in flight.

## Files

- Create: `src/state/overviewStore.ts` (lane-local Zustand store: summary, loading, error, `load()`).
- Create: `src/surfaces/overview/UsageTiles.tsx`, `src/surfaces/overview/CostTicker.tsx`, `src/surfaces/overview/RecentActivityList.tsx`.
- Modify: `src/surfaces/OverviewSurface.tsx` (compose hero + tiles + ticker + feed; keep the existing fact grid, Reconnect action, and `DaemonDataSection` fallback when the summary RPC is unavailable).
- Append: `src/styles/app.css` section `/* ---- P01 overview ---- */`.
- Create: `src/surfaces/overview/OverviewSurface.test.tsx`.

## Build steps

1. Write the store: `load()` calls the bridge, sets `{loading, summary, error}`; fixture mode short-circuits to fixture data labelled as such.
2. `UsageTiles`: 2–4 tiles (`.fact`-style cards) with `Sparkline` for the 7-day series; numbers formatted with `Intl.NumberFormat`.
3. `CostTicker`: today's cost, tabular-nums, subtle accent-gradient underline; updates when the store refreshes (poll ≤ every 30s, pause when `document.hidden`).
4. `RecentActivityList`: reuse `DataTable` rows from `recentEvents` with provenance label.
5. Wire into `OverviewSurface`; keep `Reconnect` refreshing both health and summary.

## Required states

| State | Trigger | Rendering |
|---|---|---|
| Populated | live/fixture summary | tiles + ticker + feed with provenance line |
| Loading | invoke in flight | skeleton tiles (`aria-busy="true"`, no layout shift) |
| Empty | summary ok, zero events | "No usage recorded yet" + pointer to Providers |
| Error | invoke rejects | `Banner` degraded with retry action |
| Offline | no bridge/daemon | existing `OfflineNotice` path |

## A11y / Perf / Tests

- Tiles are a `dl`; ticker has `role="status"` `aria-live="polite"` (announce at most once per refresh).
- Perf: no new interval faster than 30s; sparkline is static SVG; route stays under the `route.navigation` budget.
- Tests (five states + interactions): store unit test with a fake bridge; component test per state; Reconnect refreshes both stores; reduced-motion renders without ticker animation.

## Evidence

`npx tsc --noEmit && npm test && npm run build`; screenshot via packaged smoke lands as `screenshot-route-overview.png` (P15 refreshes the book).

## Done / Forbidden

Done per README §4. Forbidden: editing `shellStore.ts`, nav geometry, perf sample names; polling faster than 30s; hex literals; silent mock data.
