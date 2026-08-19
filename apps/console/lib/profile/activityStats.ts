/**
 * Pure activity math for the profile page.
 *
 * Everything operates on "YYYY-MM-DD" day keys (UTC, the server's rollup day
 * format) and plain numbers — no Intl, no locale, no ambient clock. The
 * console is a static export, so the prerender and the client must produce
 * byte-identical output; `today` is always injected by the caller.
 */

import type { DailyPoint } from "@/lib/usage";

const DAY_MS = 86_400_000;

export const MONTH_NAMES = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec",
] as const;

/** Date (UTC) → "YYYY-MM-DD". */
export function toDayKey(date: Date): string {
  const y = date.getUTCFullYear();
  const m = String(date.getUTCMonth() + 1).padStart(2, "0");
  const d = String(date.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

/** "YYYY-MM-DD" shifted by `delta` days (sign-aware). */
export function addDays(dayKey: string, delta: number): string {
  const [y, m, d] = dayKey.split("-").map(Number);
  return toDayKey(new Date(Date.UTC(y ?? 1970, (m ?? 1) - 1, d ?? 1) + delta * DAY_MS));
}

/** UTC weekday of a day key: 0 = Sunday … 6 = Saturday. */
export function dayOfWeek(dayKey: string): number {
  const [y, m, d] = dayKey.split("-").map(Number);
  return new Date(Date.UTC(y ?? 1970, (m ?? 1) - 1, d ?? 1)).getUTCDay();
}

/** The Sunday on or before `dayKey` — the heatmap's column key. */
export function weekStart(dayKey: string): string {
  return addDays(dayKey, -dayOfWeek(dayKey));
}

/** "2026-02-01" → "Feb 1, 2026" (deterministic, no Intl). */
export function formatDayLabel(dayKey: string): string {
  const [y, m, d] = dayKey.split("-").map(Number);
  return `${MONTH_NAMES[(m ?? 1) - 1]} ${d}, ${y}`;
}

export interface Streaks {
  /** Consecutive active days ending today (a quiet today doesn't break it). */
  current: number;
  /** Longest run of consecutive active days in the full history. */
  longest: number;
}

/**
 * Streaks over a set of active day keys.
 *
 * Current streak: counts back from `today`; if today has no activity yet, the
 * streak is anchored on yesterday instead (the standard contribution-graph
 * grace — a day still in progress never resets a live streak). Longest is a
 * single ascending pass over the sorted unique keys.
 */
export function computeStreaks(activeDays: ReadonlySet<string>, today: string): Streaks {
  if (activeDays.size === 0) return { current: 0, longest: 0 };

  const sorted = [...activeDays].sort();
  let longest = 1;
  let run = 1;
  for (let i = 1; i < sorted.length; i++) {
    run = addDays(sorted[i - 1], 1) === sorted[i] ? run + 1 : 1;
    if (run > longest) longest = run;
  }

  let anchor = today;
  if (!activeDays.has(anchor)) {
    const yesterday = addDays(today, -1);
    if (!activeDays.has(yesterday)) return { current: 0, longest };
    anchor = yesterday;
  }
  let current = 0;
  let cursor = anchor;
  while (activeDays.has(cursor)) {
    current++;
    cursor = addDays(cursor, -1);
  }
  return { current, longest };
}

/** Highest-token day, earliest day winning ties; null when nothing is active. */
export function peakDay(points: readonly DailyPoint[]): DailyPoint | null {
  let best: DailyPoint | null = null;
  for (const p of points) {
    if (p.tokens <= 0) continue;
    if (!best || p.tokens > best.tokens) best = p;
  }
  return best;
}

/** Days with any recorded activity. */
export function activeDayCount(points: readonly DailyPoint[]): number {
  return points.reduce((n, p) => n + (p.tokens > 0 ? 1 : 0), 0);
}

/** Sum of tokens across the given points (caller picks the window). */
export function sumTokens(points: readonly DailyPoint[]): number {
  return points.reduce((n, p) => n + p.tokens, 0);
}

export interface WeekTotal {
  /** Sunday day key identifying the column. */
  weekStart: string;
  tokens: number;
}

/**
 * Per-week token totals, ascending by week. Weeks align to the heatmap's
 * Sunday-start columns so the Weekly mode and the Daily mode share a grid.
 */
export function weeklyTotals(points: readonly DailyPoint[]): WeekTotal[] {  const byWeek = new Map<string, number>();
  for (const p of points) {
    const ws = weekStart(p.day);
    byWeek.set(ws, (byWeek.get(ws) ?? 0) + p.tokens);
  }
  return [...byWeek.entries()]
    .map(([ws, tokens]) => ({ weekStart: ws, tokens }))
    .sort((a, b) => (a.weekStart < b.weekStart ? -1 : 1));
}

/**
 * Heatmap intensity, 0 (empty) – 4 (hottest). Uses a square-root scale
 * against the series max — the same perceptual trick as the native
 * ChartKit heatmap — so one monster day doesn't flatten every other cell.
 */
export function intensityBucket(tokens: number, max: number): 0 | 1 | 2 | 3 | 4 {
  if (tokens <= 0 || max <= 0) return 0;
  const ratio = Math.sqrt(tokens / max);
  if (ratio <= 0.25) return 1;
  if (ratio <= 0.5) return 2;
  if (ratio <= 0.75) return 3;
  return 4;
}
