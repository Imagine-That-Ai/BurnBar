/**
 * Client aggregates over bounded-range usage events for the /profile explorer.
 *
 * Pure math over `ProfileUsageEvent[]` — the hour × weekday grid, token mix,
 * and day mixes the rollup cannot answer. All keys are UTC (the server's
 * rollup day format) and all output is deterministic.
 */

import type { ProfileUsageEvent } from "./profileEvents";

/** 7 × 24 grid of event counts + tokens, Monday-first row order for display. */
export interface HourWeekdayCell {
  /** 0 = Sunday … 6 = Saturday (matches dayOfWeek). */
  weekday: number;
  hour: number;
  events: number;
  tokens: number;
}

export interface HourWeekdayGrid {
  cells: HourWeekdayCell[];
  maxTokens: number;
  maxEvents: number;
}

function dayKeyOf(iso: string): string {
  return iso.slice(0, 10);
}

function weekdayOfDayKey(dayKey: string): number {
  const [y, m, d] = dayKey.split("-").map(Number);
  return new Date(Date.UTC(y ?? 1970, (m ?? 1) - 1, d ?? 1)).getUTCDay();
}

/**
 * Hour × weekday grid from event timestamps. Events without a timestamp are
 * skipped (they still count in the ledger). `maxTokens`/`maxEvents` drive
 * sqrt-scaled intensity at render time, same perceptual trick as the heatmap.
 */
export function hourWeekdayGrid(events: readonly ProfileUsageEvent[]): HourWeekdayGrid {
  const byCell = new Map<string, { events: number; tokens: number }>();
  for (const e of events) {
    if (!e.startedAt || e.hourUtc == null) continue;
    const weekday = weekdayOfDayKey(dayKeyOf(e.startedAt));
    const key = `${weekday}:${e.hourUtc}`;
    const cur = byCell.get(key) ?? { events: 0, tokens: 0 };
    cur.events += 1;
    cur.tokens += e.totalTokens;
    byCell.set(key, cur);
  }
  const cells: HourWeekdayCell[] = [];
  let maxTokens = 0;
  let maxEvents = 0;
  for (let weekday = 0; weekday < 7; weekday++) {
    for (let hour = 0; hour < 24; hour++) {
      const cur = byCell.get(`${weekday}:${hour}`) ?? { events: 0, tokens: 0 };
      if (cur.tokens > maxTokens) maxTokens = cur.tokens;
      if (cur.events > maxEvents) maxEvents = cur.events;
      cells.push({ weekday, hour, ...cur });
    }
  }
  return { cells, maxTokens, maxEvents };
}

export interface TokenMix {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  reasoning: number;
  total: number;
}

/** Token mix over events — the footer currently admits this is missing. */
export function tokenMix(events: readonly ProfileUsageEvent[]): TokenMix {
  const mix: TokenMix = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0, total: 0 };
  for (const e of events) {
    mix.input += e.inputTokens;
    mix.output += e.outputTokens;
    mix.cacheRead += e.cacheReadTokens;
    mix.cacheWrite += e.cacheWriteTokens;
    mix.reasoning += e.reasoningTokens;
  }
  mix.total = mix.input + mix.output + mix.cacheRead + mix.cacheWrite + mix.reasoning;
  return mix;
}

export interface NamedShare {
  key: string;
  label: string;
  tokens: number;
  events: number;
  cost: number;
}

/** Rank providers / models / harnesses / accounts / devices inside a day or range. */
export function rankShares(
  events: readonly ProfileUsageEvent[],
  by: "provider" | "model" | "harness" | "account" | "device",
): NamedShare[] {
  const acc = new Map<string, { label: string; tokens: number; events: number; cost: number }>();
  for (const e of events) {
    let key: string | undefined;
    let label: string | undefined;
    switch (by) {
      case "provider":
        // Canonical ID groups ("claude-code"); display label kept separate —
        // producers store "Claude Code" and "claude-code" interchangeably in
        // `provider`, and grouping by display would split one provider.
        key = e.providerID ?? e.provider;
        label = e.provider;
        break;
      case "model":
        key = e.model ?? "unknown";
        label = e.model ?? "Unknown model";
        break;
      case "harness":
        key = e.harnessId ?? "unknown";
        label = e.harnessName ?? e.harnessId ?? "Unknown";
        break;
      case "account":
        key = e.accountId ?? `${e.providerID ?? e.provider}:unattributed`;
        label = e.accountLabel ?? key;
        break;
      case "device":
        key = e.deviceId ?? "unknown";
        label = e.deviceId ?? "Unknown device";
        break;
    }
    const cur = acc.get(key) ?? { label: label ?? key, tokens: 0, events: 0, cost: 0 };
    cur.tokens += e.totalTokens;
    cur.events += 1;
    cur.cost += e.costUsd;
    acc.set(key, cur);
  }
  return [...acc.entries()]
    .map(([key, v]) => ({ key, ...v }))
    .sort((a, b) => b.tokens - a.tokens || b.events - a.events);
}

export interface DayInspectorSummary {
  day: string;
  events: number;
  tokens: number;
  cost: number;
  mix: TokenMix;
  byProvider: NamedShare[];
  byModel: NamedShare[];
  byHarness: NamedShare[];
}

/** One day's events → the day inspector body (mix + top shares). */
export function summarizeDay(
  day: string,
  events: readonly ProfileUsageEvent[],
): DayInspectorSummary {
  const dayEvents = events.filter((e) => e.startedAt && dayKeyOf(e.startedAt) === day);
  return {
    day,
    events: dayEvents.length,
    tokens: dayEvents.reduce((n, e) => n + e.totalTokens, 0),
    cost: dayEvents.reduce((n, e) => n + e.costUsd, 0),
    mix: tokenMix(dayEvents),
    byProvider: rankShares(dayEvents, "provider").slice(0, 5),
    byModel: rankShares(dayEvents, "model").slice(0, 5),
    byHarness: rankShares(dayEvents, "harness").slice(0, 5),
  };
}

/**
 * Filter events to a single day (UTC) — the inspector's prev/next-day jump
 * pages the ledger range once; day switches are client-side slices after that.
 */
export function eventsOnDay(
  events: readonly ProfileUsageEvent[],
  day: string,
): ProfileUsageEvent[] {
  return events.filter((e) => e.startedAt && dayKeyOf(e.startedAt) === day);
}

/**
 * Per-day per-model token totals ("YYYY-MM-DD" → model → tokens) from bounded
 * event aggregates. The rollup carries no model split, so the explorer builds
 * one client-side wherever the event path has loaded — powers per-model
 * heatmap coloring and the hover mix when the provider split is absent.
 */
export function dailyModelTokenSplit(
  events: readonly ProfileUsageEvent[],
): Record<string, Record<string, number>> {
  const out: Record<string, Record<string, number>> = {};
  for (const e of events) {
    if (!e.startedAt || e.totalTokens <= 0) continue;
    const day = dayKeyOf(e.startedAt);
    const model = e.model ?? "unknown";
    const split = out[day] ?? {};
    split[model] = (split[model] ?? 0) + e.totalTokens;
    out[day] = split;
  }
  return out;
}

/**
 * Dominant-share color math for heatmap cells. Given a per-day (or per-week)
 * token split and the series max, returns the cell fill: the DOMINANT
 * provider/model's brand color at sqrt-scaled opacity (same perceptual trick
 * as the intensity buckets), so one-provider days read solid and mixed days
 * read as the winner's hue. Returns null when the split is empty — the
 * caller falls back to the accent fill.
 */
export function dominantShareFill(
  split: Record<string, number> | undefined,
  max: number,
  colorFor: (key: string) => string,
): { fill: string; fillOpacity: number } | null {
  if (!split) return null;
  let bestKey: string | null = null;
  let bestTokens = 0;
  let total = 0;
  for (const [key, tokens] of Object.entries(split)) {
    if (tokens <= 0) continue;
    total += tokens;
    if (tokens > bestTokens) {
      bestTokens = tokens;
      bestKey = key;
    }
  }
  if (!bestKey || total <= 0 || max <= 0) return null;
  const ratio = Math.sqrt(total / max);
  const opacity = ratio <= 0.25 ? 0.28 : ratio <= 0.5 ? 0.48 : ratio <= 0.75 ? 0.72 : 1;
  return { fill: colorFor(bestKey), fillOpacity: opacity };
}

/**
 * Weighted-blend fill for aggregate (weekly) cells: a linear-gradient across
 * the top provider/model shares (up to 3 + remainder), each stop sized by its
 * share — a kernel/conglomerate of the colors weighted by predominance.
 * Returns null when the split is empty (caller falls back to the accent).
 */
export function blendShareFill(
  split: Record<string, number> | undefined,
  colorFor: (key: string) => string,
): string | null {
  if (!split) return null;
  const entries = Object.entries(split)
    .filter(([, tokens]) => tokens > 0)
    .sort((a, b) => b[1] - a[1]);
  const total = entries.reduce((n, [, tokens]) => n + tokens, 0);
  if (entries.length === 0 || total <= 0) return null;
  const top = entries.slice(0, 3);
  const rest = total - top.reduce((n, [, tokens]) => n + tokens, 0);
  const stops: [string, number][] = top.map(([key, tokens]) => [colorFor(key), tokens / total]);
  if (rest > 0) stops.push(["var(--accent)", rest / total]);
  if (stops.length === 1) return stops[0][0];
  let cursor = 0;
  const parts = stops.map(([color, share]) => {
    const from = cursor * 100;
    cursor += share;
    // Hard stops (no interpolation) so each hue reads as its own band.
    return `${color} ${from.toFixed(1)}% ${(cursor * 100).toFixed(1)}%`;
  });
  return `linear-gradient(135deg, ${parts.join(", ")})`;
}
