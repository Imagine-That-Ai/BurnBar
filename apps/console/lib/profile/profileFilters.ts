/**
 * URL-backed filter model for the mineable /profile explorer.
 *
 * The URL is the source of truth (`?w=90d&from=&to=&p=&m=&h=&a=&d=&metric=tokens&day=2026-09-01`)
 * so a cell, a record, or a combo row is shareable: every number, bar, day,
 * and record on the page sets a filter or pins the inspector, and a hard
 * reload restores the same mine.
 *
 * Pure module — no Intl, no ambient clock, no Firestore. Window presets match
 * the dashboard pills (`apps/console/lib/usage.ts` UsageWindowKey minus
 * "today", which the explorer expresses as an explicit custom range).
 */

import { addDays } from "./activityStats";
import type { DailyPoint } from "@/lib/usage";

/** Calendar window presets for the explorer rail. */
export type ProfileWindowKey = "7d" | "30d" | "90d" | "all";

/** Breakdown metric — Tokens / Runs / Spend applies to every surface. */
export type ProfileMetric = "tokens" | "runs" | "spend";

export const PROFILE_WINDOWS: ProfileWindowKey[] = ["7d", "30d", "90d", "all"];

export const PROFILE_WINDOW_DAYS: Record<Exclude<ProfileWindowKey, "all">, number> = {
  "7d": 7,
  "30d": 30,
  "90d": 90,
};

export const PROFILE_METRICS: ProfileMetric[] = ["tokens", "runs", "spend"];

/** Multi-select facet filters. Empty arrays mean "no filter". */
export interface ProfileFacets {
  /** Provider ids (canonical `providerID`, e.g. "claude-code"). */
  providers: string[];
  /** Model ids as stored (`gpt-5.3`, `claude-opus-4.6`). */
  models: string[];
  /** Harness ids (`executionSourceID`, e.g. "claude-code"). */
  harnesses: string[];
  /** Account ids (raw `providerAccountID` or `${providerID}:unattributed`). */
  accounts: string[];
  /** Device ids. */
  devices: string[];
}

export interface ProfileFilters {
  window: ProfileWindowKey;
  /** Custom [from, to] day keys (inclusive). Overrides the preset window. */
  from: string | null;
  to: string | null;
  facets: ProfileFacets;
  metric: ProfileMetric;
  /** Pinned inspector day ("YYYY-MM-DD") or null. */
  day: string | null;
  /** Focused inspector entity ({kind, id}) or null. */
  entity: { kind: "provider" | "model" | "harness" | "account" | "device" | "session"; id: string } | null;
}

const DAY_KEY_RE = /^\d{4}-\d{2}-\d{2}$/;

/**
 * Strict calendar day-key check: shape AND a real UTC date (rejects
 * "2026-99-99", "2026-02-30"). Round-trips through Date.UTC so a shared URL
 * can never smuggle an invalid Date into a Firestore constraint.
 */
export function isDayKey(v: string): boolean {
  if (!DAY_KEY_RE.test(v)) return false;
  const [y, m, d] = v.split("-").map(Number);
  if (!y || !m || !d) return false;
  const dt = new Date(Date.UTC(y, m - 1, d));
  return (
    dt.getUTCFullYear() === y && dt.getUTCMonth() === m - 1 && dt.getUTCDate() === d
  );
}

function parseList(v: string | null): string[] {
  if (!v) return [];
  const seen = new Set<string>();
  for (const part of v.split(",")) {
    const t = part.trim();
    if (t && !seen.has(t)) seen.add(t);
  }
  return [...seen];
}

function encodeList(values: readonly string[]): string | null {
  return values.length > 0 ? values.join(",") : null;
}

function parseWindow(v: string | null): ProfileWindowKey {
  return v === "7d" || v === "30d" || v === "90d" || v === "all" ? v : "all";
}

function parseMetric(v: string | null): ProfileMetric {
  return v === "runs" || v === "spend" ? v : "tokens";
}

function parseEntity(v: string | null): ProfileFilters["entity"] {
  if (!v) return null;
  const idx = v.indexOf(":");
  if (idx <= 0) return null;
  const kind = v.slice(0, idx);
  const id = v.slice(idx + 1).trim();
  if (!id) return null;
  if (
    kind === "provider" ||
    kind === "model" ||
    kind === "harness" ||
    kind === "account" ||
    kind === "device" ||
    kind === "session"
  ) {
    return { kind, id };
  }
  return null;
}

export function emptyFilters(): ProfileFilters {
  return {
    window: "all",
    from: null,
    to: null,
    facets: { providers: [], models: [], harnesses: [], accounts: [], devices: [] },
    metric: "tokens",
    day: null,
    entity: null,
  };
}

/** Parse a URL query string (with or without leading "?") into filters. */
export function parseProfileFilters(search: string): ProfileFilters {
  const params = new URLSearchParams(search.startsWith("?") ? search.slice(1) : search);
  const window = parseWindow(params.get("w"));
  const fromRaw = params.get("from");
  const toRaw = params.get("to");
  let from = fromRaw && isDayKey(fromRaw) ? fromRaw : null;
  let to = toRaw && isDayKey(toRaw) ? toRaw : null;
  // A reversed custom range is a malformed URL, not a time machine — drop it.
  if (from && to && from > to) {
    from = null;
    to = null;
  }
  const dayRaw = params.get("day");
  const day = dayRaw && isDayKey(dayRaw) ? dayRaw : null;
  return {
    window,
    from,
    to,
    facets: {
      providers: parseList(params.get("p")),
      models: parseList(params.get("m")),
      harnesses: parseList(params.get("h")),
      accounts: parseList(params.get("a")),
      devices: parseList(params.get("d")),
    },
    metric: parseMetric(params.get("metric")),
    day,
    entity: parseEntity(params.get("entity")),
  };
}

/** Serialize filters back to a query string (no leading "?"; "" when default). */
export function serializeProfileFilters(f: ProfileFilters): string {
  const params = new URLSearchParams();
  if (f.window !== "all") params.set("w", f.window);
  if (f.from) params.set("from", f.from);
  if (f.to) params.set("to", f.to);
  const p = encodeList(f.facets.providers);
  const m = encodeList(f.facets.models);
  const h = encodeList(f.facets.harnesses);
  const a = encodeList(f.facets.accounts);
  const d = encodeList(f.facets.devices);
  if (p) params.set("p", p);
  if (m) params.set("m", m);
  if (h) params.set("h", h);
  if (a) params.set("a", a);
  if (d) params.set("d", d);
  if (f.metric !== "tokens") params.set("metric", f.metric);
  if (f.day) params.set("day", f.day);
  if (f.entity) params.set("entity", `${f.entity.kind}:${f.entity.id}`);
  return params.toString();
}

/**
 * Effective calendar range for the filters: [fromDay, toDay] inclusive, both
 * "YYYY-MM-DD". Custom dates win over the preset; `today` anchors the presets.
 */
export function effectiveRange(
  f: Pick<ProfileFilters, "window" | "from" | "to">,
  today: string,
): { fromDay: string | null; toDay: string } {
  const toDay = f.to && isDayKey(f.to) ? f.to : today;
  if (f.from && isDayKey(f.from)) return { fromDay: f.from, toDay };
  if (f.window === "all") return { fromDay: null, toDay };
  return { fromDay: addDays(toDay, -(PROFILE_WINDOW_DAYS[f.window] - 1)), toDay };
}

/**
 * Slice the all_time daily series to the active calendar range. Provider-only
 * filters recolor through `dailyProviderTokens` at render time; model /
 * harness / account facets need the event path (see `needsEventPath`).
 */
export function sliceDailyPoints(
  points: readonly DailyPoint[],
  f: Pick<ProfileFilters, "window" | "from" | "to">,
  today: string,
): DailyPoint[] {
  const { fromDay, toDay } = effectiveRange(f, today);
  if (!fromDay) return [...points].filter((p) => p.day <= toDay);
  return [...points].filter((p) => p.day >= fromDay && p.day <= toDay);
}

/**
 * Facets the rollup alone cannot answer. Provider-only filtering recolors the
 * heatmap from `dailyProviderTokens`; anything else needs bounded event
 * queries. Returns the list of active unsupported facet groups.
 */
export function unsupportedRollupFacets(f: ProfileFilters): string[] {
  const out: string[] = [];
  if (f.facets.models.length > 0) out.push("models");
  if (f.facets.harnesses.length > 0) out.push("harnesses");
  if (f.facets.accounts.length > 0) out.push("accounts");
  if (f.facets.devices.length > 0) out.push("devices");
  return out;
}

/**
 * Whether the active filters need the event path (paginated `usage` queries).
 * True whenever a model / harness / account / device facet is active, or an
 * hour/token-mix cross-filter is requested. The rollup answers the instant
 * scoreboard; events answer the inspector, the ledger, and bounded-range
 * cross-filters.
 */
export function needsEventPath(f: ProfileFilters): boolean {
  return unsupportedRollupFacets(f).length > 0 || f.day != null || f.entity != null;
}

/**
 * The 91k-event guard: a model / harness / account facet on an unbounded
 * "All" window would scan the whole history. Snap to 90d and say so once.
 * Day/entity pins ride along unchanged — they only narrow the query.
 * Returns the snapped filters, or null when no snap is needed.
 */
export function snapWindowForEventFacets(f: ProfileFilters): ProfileFilters | null {
  if (unsupportedRollupFacets(f).length === 0) return null;
  if (f.window !== "all") return null;
  if (f.from || f.to) return null;
  return { ...f, window: "90d" };
}

/** Toggle one value in a facet list (add when absent, remove when present). */
export function toggleFacetValue(list: readonly string[], value: string): string[] {
  return list.includes(value) ? list.filter((v) => v !== value) : [...list, value];
}

/** Ensure one value is in a facet list (add when absent, keep when present). */
export function ensureFacetValue(list: readonly string[], value: string): string[] {
  return list.includes(value) ? [...list] : [...list, value];
}

/** Drop every filter except the metric (the rail's "clear" action). */
export function clearMineFilters(f: ProfileFilters): ProfileFilters {
  return {
    ...emptyFilters(),
    metric: f.metric,
  };
}
