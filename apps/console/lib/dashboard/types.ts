/**
 * Typed shape for one usage window powering the dashboard cards.
 *
 * This mirrors the native macOS app's `DashboardUsageWindowSummary`
 * (AgentLens/Views/Dashboard/DashboardUsageViewModel.swift) so that, when a
 * live feed is wired up (see ./useDashboardUsage), the cards need no change —
 * only the loader behind the seam flips from `mock` to `live`.
 */

export type DashboardRange = "today" | "7d" | "30d";

export type DashboardSource = "live" | "mock";

/** One cumulative cost sample across the window (t is normalized 0..1). */
export interface CostSample {
  /** Position within the window, 0 (start) .. 1 (now). */
  t: number;
  /** Cumulative spend in USD up to this point. */
  cumulativeUsd: number;
}

/** Per-provider rollup (mirrors Swift `ProviderSummary`). */
export interface ProviderRow {
  /** Provider id — matches /brand/logos/<id> and the backdrop swarm. */
  id: string;
  label: string;
  costUsd: number;
  tokens: number;
  sessions: number;
  /** 0..1 cache-hit rate for this provider. */
  cacheHitRate: number;
}

/** Fusion ("The Wand") vs normal totals (mirrors Swift `FusionVsNormalTotals`). */
export interface FusionTotals {
  fusionRuns: number;
  fusionCostUsd: number;
  /** What the same work would have cost without fusion routing. */
  baselineCostUsd: number;
  /** baselineCostUsd - fusionCostUsd, floored at 0. */
  savedUsd: number;
}

export interface DashboardWindow {
  range: DashboardRange;
  rangeLabel: string;
  totalCostUsd: number;
  totalTokens: number;
  sessionCount: number;
  /** 0..1 aggregate cache-hit rate (cacheRead / promptBasis). */
  cacheHitRate: number;
  /** Most-recent observed tokens/sec, or null when no aggregate exists. */
  tokensPerSecond: number | null;
  costCurve: CostSample[];
  providers: ProviderRow[];
  fusion: FusionTotals;
}

export interface DashboardUsageResult {
  data: DashboardWindow;
  source: DashboardSource;
  loading: boolean;
}
