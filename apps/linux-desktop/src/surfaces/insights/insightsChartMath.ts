import type { WeeklyPoint } from '../../tauriBridge.js';

/** Normalize numeric series to [0, 1] for SVG plotting; flat or single-value series → 0.5. */
export function normalizeValues(values: number[]): number[] {
  if (values.length === 0) return [];
  const min = Math.min(...values);
  const max = Math.max(...values);
  if (max === min) return values.map(() => 0.5);
  const span = max - min;
  return values.map((v) => (v - min) / span);
}

export function weekOverWeekTokenDeltaPct(weekly: WeeklyPoint[]): number | null {
  if (weekly.length < 2) return null;
  const prev = weekly[weekly.length - 2]!.tokens;
  const last = weekly[weekly.length - 1]!.tokens;
  if (prev === 0) return last > 0 ? 100 : 0;
  return ((last - prev) / prev) * 100;
}

export function mixPercentTotal(entries: { pct: number }[]): number {
  return entries.reduce((sum, e) => sum + e.pct, 0);
}

export function trendAriaSummary(weekly: WeeklyPoint[]): string {
  if (weekly.length === 0) {
    return 'No weekly token usage data yet.';
  }
  const tokens = weekly.map((w) => w.tokens);
  const min = Math.min(...tokens);
  const max = Math.max(...tokens);
  const last = weekly[weekly.length - 1]!;
  const first = weekly[0]!;
  const direction =
    last.tokens > first.tokens ? 'rising' : last.tokens < first.tokens ? 'falling' : 'steady';
  return `Weekly token usage trend over ${weekly.length} weeks, ${direction} from ${first.label} to ${last.label}, ranging from ${min.toLocaleString()} to ${max.toLocaleString()} tokens.`;
}

export function hasInsightsUsage(data: {
  weekly: WeeklyPoint[];
}): boolean {
  if (data.weekly.length === 0) return false;
  return data.weekly.some((w) => w.tokens > 0 || w.costUsd > 0);
}