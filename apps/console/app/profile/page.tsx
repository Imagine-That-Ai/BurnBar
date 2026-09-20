"use client";

/**
 * /profile — the mineable usage explorer.
 *
 * Was a static lifetime poster reading only `users/{uid}/usage_rollups/all_time`.
 * Now every number, bar, day, and record is a drill-in: a sticky filter rail
 * (window + custom dates + provider/model/harness/account/device facets +
 * Tokens/Runs/Spend metric) drives the instant rollup path, and anything the
 * rollup cannot answer comes from the owner-readable `usage` collection iOS
 * already pages.
 *
 * URL is the source of truth — a cell, record, or combo row is shareable, and
 * a hard reload restores the same mine. Rollup answers the scoreboard; events
 * answer the inspector, the ledger, and bounded-range cross-filters. The 91k
 * guard: event facets on an unbounded All window snap to 90d, once.
 *
 * Composition (each section owns its render; the page owns filter state):
 * ProfileFilterRail / ProfileHeatmapSection / ProfileHourGrid /
 * ProfileMixPanel / ProfileBreakdowns / ProfileRecords / ProfileSessionLedger
 * / ProfileInspector + HeroStats / Rhythm / Trend / ProviderMix+Insights.
 * Real data or an elegant zero, never a mock.
 */

import * as React from "react";
import { RefreshCw } from "lucide-react";

import { useAuth } from "@/lib/useAuth";
import { useProfileUsage } from "@/lib/profile/useProfileUsage";
import {
  activeDayCount,
  addDays,
  computeStreaks,
  formatDayLabel,
  peakDay,
  sumTokens,
  toDayKey,
  weekdayRhythm,
} from "@/lib/profile/activityStats";
import {
  clearMineFilters,
  effectiveRange,
  emptyFilters,
  ensureFacetValue,
  parseProfileFilters,
  serializeProfileFilters,
  sliceDailyPoints,
  snapWindowForEventFacets,
  toggleFacetValue,
  unsupportedRollupFacets,
  type ProfileFilters,
} from "@/lib/profile/profileFilters";
import {
  dailyModelProviders,
  dailyModelTokenSplit,
  hourWeekdayGrid,
  rankShares,
  tokenMix,
} from "@/lib/profile/profileAggregates";
import { profileEventErrorCopy } from "@/lib/profile/profileEvents";
import { useProfileEvents } from "@/lib/profile/useProfileEvents";
import { ProfileFilterRail } from "@/components/profile/ProfileFilterRail";
import { ProfileHeatmapSection } from "@/components/profile/ProfileHeatmapSection";
import { ProfileHeroStats } from "@/components/profile/ProfileHeroStats";
import { ProfileHourGrid } from "@/components/profile/ProfileHourGrid";
import {
  ProfileInsightsPanel,
  ProfileProviderMix,
} from "@/components/profile/ProfileInsights";
import { ProfileMixPanel } from "@/components/profile/ProfileMixPanel";
import { ProfileRhythmSection } from "@/components/profile/ProfileRhythmSection";
import {
  ProfileBreakdowns,
  type BreakdownFacet,
} from "@/components/profile/ProfileBreakdowns";
import { ProfileRecords } from "@/components/profile/ProfileRecords";
import { ProfileSessionLedger } from "@/components/profile/ProfileSessionLedger";
import {
  ProfileInspector,
  type InspectorSelection,
} from "@/components/profile/ProfileInspector";
import { ProfileTrendSection } from "@/components/profile/ProfileTrendSection";
import { formatCompact, formatUsd } from "@/components/dashboard/cards/primitives";
import { providerDisplayName } from "@/lib/providerBrand";
import { normalizeRollup, type UsageWindowKey } from "@/lib/usage";
import type { ProfileUsageEvent } from "@/lib/profile/profileEvents";
import { cn } from "@/lib/utils";
import { db } from "@/lib/firebaseClient";
import { doc, getDoc } from "firebase/firestore";

/** Days between an ISO timestamp and a "YYYY-MM-DD" day key (UTC, floor). */
function daysSince(iso: string, today: string): number {
  const start = Date.parse(iso);
  const end = Date.parse(today + "T00:00:00Z");
  if (!Number.isFinite(start) || !Number.isFinite(end)) return 0;
  return Math.max(0, Math.floor((end - start) / 86_400_000));
}

/**
 * Entity-focus updates need a LOWER bound: the entity inspector reads the
 * range event pass, which stays off on unbounded All. Force 90d when the
 * merged filters would otherwise be unbounded (custom dates already bound).
 * Also clears any pinned day — day pins take precedence in the inspector,
 * so a day+entity combo would show the day and swallow the entity.
 */
function boundedEntityFilters(next: ProfileFilters): ProfileFilters {
  const out = { ...next, day: null };
  if (!out.from && !out.to && out.window === "all") {
    out.window = "90d";
  }
  return out;
}

/**
 * Read one windowed rollup doc (`usage_rollups/{window}`) for the explorer's
 * preset windows. Same existing rollup, no new server — fail-soft to null so
 * the page falls back to the all_time doc + token slicing.
 */
async function getWindowRollup(uid: string, window: UsageWindowKey) {
  try {
    const snap = await getDoc(doc(db(), "users", uid, "usage_rollups", window));
    return snap.exists() ? normalizeRollup(snap.data(), window) : null;
  } catch {
    return null;
  }
}

/** Staggered entrance delays for the reveal kit (globals.css .reveal). */
const REVEAL: Record<
  | "header"
  | "filters"
  | "stats"
  | "heatmap"
  | "rhythm"
  | "trend"
  | "insights"
  | "records"
  | "ledger"
  | "footer",
  React.CSSProperties
> = {
  header: { "--d": "0ms" } as React.CSSProperties,
  filters: { "--d": "60ms" } as React.CSSProperties,
  stats: { "--d": "90ms" } as React.CSSProperties,
  heatmap: { "--d": "180ms" } as React.CSSProperties,
  rhythm: { "--d": "240ms" } as React.CSSProperties,
  trend: { "--d": "300ms" } as React.CSSProperties,
  insights: { "--d": "360ms" } as React.CSSProperties,
  records: { "--d": "420ms" } as React.CSSProperties,
  ledger: { "--d": "480ms" } as React.CSSProperties,
  footer: { "--d": "540ms" } as React.CSSProperties,
};

export default function ProfilePage() {
  const { user } = useAuth();
  const { rollup, source, loading, syncing, error, reload } = useProfileUsage();
  // If the IdP avatar fails to load (expired URL, CSP, offline), fall back to
  // the initial tile instead of a broken image.
  const [avatarFailed, setAvatarFailed] = React.useState(false);

  // "Today" only exists client-side; gating on it keeps the static prerender
  // and the first client render byte-identical (no hydration drift).
  const [today, setToday] = React.useState<string | null>(null);
  React.useEffect(() => setToday(toDayKey(new Date())), []);

  // URL is the source of truth. Read once after mount (prerender has no
  // window), then replaceState on every change — shareable, reload-stable,
  // and Suspense-free for the static export. The restore path runs the same
  // 91k-event guard as interactive changes so a shared `?m=…` on All snaps
  // to 90d before any read fires. Mount-guarded: the auth listener can
  // re-fire on tab refocus and must never reset an in-progress mine.
  const [filters, setFilters] = React.useState<ProfileFilters>(() => emptyFilters());
  const [snapNotice, setSnapNotice] = React.useState<string | null>(null);
  const restoredUrl = React.useRef(false);
  const writeUrl = React.useCallback((next: ProfileFilters) => {
    try {
      const qs = serializeProfileFilters(next);
      window.history.replaceState(null, "", qs ? `/profile?${qs}` : "/profile");
    } catch {
      /* history unavailable (tests) — filters still apply in-memory */
    }
  }, []);
  React.useEffect(() => {
    if (restoredUrl.current) return;
    restoredUrl.current = true;
    try {
      const parsed = parseProfileFilters(window.location.search);
      const snapped = snapWindowForEventFacets(parsed);
      if (snapped) {
        setSnapNotice("Model / harness / account filters need a bounded range — snapped to 90d.");
        setFilters(snapped);
        writeUrl(snapped);
      } else {
        setFilters(parsed);
      }
    } catch {
      /* malformed query — stay on defaults */
    }
  }, [writeUrl]);
  const applyFilters = React.useCallback(
    (next: ProfileFilters) => {
      // The 91k-event guard: event facets on unbounded All snap to 90d, once.
      const snapped = snapWindowForEventFacets(next);
      if (snapped) {
        setSnapNotice("Model / harness / account filters need a bounded range — snapped to 90d.");
        next = snapped;
      }
      setFilters(next);
      writeUrl(next);
    },
    [writeUrl],
  );

  const toggleFacet = React.useCallback(
    (f: BreakdownFacet) => {
      const map = {
        provider: "providers",
        model: "models",
        harness: "harnesses",
        account: "accounts",
        device: "devices",
      } as const;
      const group = map[f.kind];
      applyFilters({
        ...filters,
        facets: { ...filters.facets, [group]: toggleFacetValue(filters.facets[group], f.id) },
      });
    },
    [applyFilters, filters],
  );

  // Inspector: a pinned day (heatmap cell / record tile) or a focused entity
  // (record tile, breakdown row, ledger row). Record + breakdown selections
  // set the facet chip AND the entity focus in ONE update (two sequential
  // setFilters calls would race: the second derives from the stale first).
  // Day prev/next clamps to the active range so navigation never leaves the
  // window the rest of the page is scoped to.
  const inspector: InspectorSelection | null = filters.day
    ? { kind: "day", day: filters.day }
    : filters.entity
      ? { kind: "entity", entity: filters.entity }
      : null;

  /** Toggle a facet chip AND focus the matching entity, atomically. */
  const selectFacet = React.useCallback(
    (f: BreakdownFacet) => {
      const map = {
        provider: "providers",
        model: "models",
        harness: "harnesses",
        account: "accounts",
        device: "devices",
      } as const;
      const group = map[f.kind];
      applyFilters(
        boundedEntityFilters({
          ...filters,
          facets: { ...filters.facets, [group]: ensureFacetValue(filters.facets[group], f.id) },
          day: null,
          entity: { kind: f.kind, id: f.id },
        }),
      );
    },
    [applyFilters, filters],
  );

  /** Record drill-in: facet chip + entity focus in one update (see above). */
  const inspectRecord = React.useCallback(
    (kind: "provider" | "model", id: string) => {
      const group = kind === "provider" ? "providers" : "models";
      applyFilters(
        boundedEntityFilters({
          ...filters,
          facets: {
            ...filters.facets,
            [group]: ensureFacetValue(filters.facets[group], id),
          },
          day: null,
          entity: { kind, id },
        }),
      );
    },
    [applyFilters, filters],
  );
  const activeRange = React.useMemo(() => {
    if (!today) return { fromDay: null as string | null, toDay: null as string | null };
    return effectiveRange(filters, today);
  }, [filters, today]);
  const stepDay = React.useCallback(
    (delta: -1 | 1) => {
      if (!today || !filters.day) return;
      const next = addDays(filters.day, delta);
      const toDay = activeRange.toDay ?? today;
      if (next > toDay) return;
      if (activeRange.fromDay && next < activeRange.fromDay) return;
      applyFilters({ ...filters, day: next });
    },
    [applyFilters, filters, today, activeRange],
  );

  // The view's right edge: series math (trend tail, rhythm denominators,
  // heatmap grid) anchors on the range END, not the wall clock — a custom
  // range ending months ago renders its own window, not a blank tail.
  const viewToday = activeRange.toDay ?? today;
  const viewFirst = activeRange.fromDay;

  // Instant path: slice the all_time daily series to the active range.
  // Provider facets additionally recolor through dailyProviderTokens;
  // model/harness/account/device facets are rollup-opaque — the event path
  // below carries those surfaces (see scopedStats).
  const slicedPoints = React.useMemo(() => {
    if (!today) return rollup.dailyPoints;
    return sliceDailyPoints(rollup.dailyPoints, filters, today);
  }, [rollup.dailyPoints, filters, today]);

  // Provider-filtered daily series: recolor the heatmap from the sparse
  // per-day provider split (all_time rollup, counter schema v3+). Days with
  // no split data fall back to the unfiltered value rather than zero — a
  // provider filter on a legacy doc must not blank the grid. Provider facets
  // are the one facet group the rollup CAN fully recompute, so the hero,
  // trend, rhythm, and records below derive from this series whenever a
  // provider facet is active.
  const providerFilteredPoints = React.useMemo(() => {
    if (filters.facets.providers.length === 0) return slicedPoints;
    const wanted = new Set(filters.facets.providers);
    return slicedPoints.map((p) => {
      const split = rollup.dailyProviderTokens[p.day];
      if (!split) return p;
      let tokens = 0;
      for (const [provider, n] of Object.entries(split)) {
        if (wanted.has(provider)) tokens += n;
      }
      return { ...p, tokens };
    });
  }, [slicedPoints, filters.facets.providers, rollup.dailyProviderTokens]);

  const hasEventFacets = unsupportedRollupFacets(filters).length > 0;

  const stats = React.useMemo(() => {
    if (!today || !viewToday) return null;
    const points = providerFilteredPoints;
    const active = new Set(points.filter((p) => p.tokens > 0).map((p) => p.day));
    const streaks = computeStreaks(active, today);
    const peak = peakDay(points);
    const activeDays = activeDayCount(points);
    const totalTokens = sumTokens(points);
    // Trailing 90 days of the VIEW (ends at the range end, not the clock).
    const trend = points.filter((p) => p.day >= addDays(viewToday, -89) && p.day <= viewToday);
    const sortedActive = [...active].sort();
    const firstBurn = sortedActive.length > 0 ? (sortedActive[0] ?? null) : null;
    const rhythmFirst = viewFirst && firstBurn && firstBurn < viewFirst ? viewFirst : (firstBurn ?? viewToday);
    const rhythm = weekdayRhythm(points, rhythmFirst, viewToday);
    const rhythmMax = Math.max(...rhythm.map((r) => r.avg), 0);
    const spanDays = firstBurn ? daysSince(`${firstBurn}T00:00:00Z`, viewToday) + 1 : 0;
    return {
      streaks,
      peak,
      activeDays,
      totalTokens,
      avgPerActiveDay: activeDays > 0 ? Math.round(totalTokens / activeDays) : 0,
      trend,
      firstBurn,
      rhythm,
      rhythmMax,
      spanDays,
    };
  }, [providerFilteredPoints, today, viewToday, viewFirst]);

  // Facet options come from the rollup lists so the pickers are instant.
  const facetOptions = React.useMemo(() => {
    const providers = [...new Set(rollup.providerSummaries.map((p) => p.provider))].sort();
    const models = [...new Set(rollup.modelSummaries.map((m) => m.model))].sort();
    const harnesses = [...rollup.executionSourceSummaries]
      .sort((a, b) => b.totalTokens - a.totalTokens)
      .map((h) => ({ id: h.sourceId, name: h.sourceName }));
    const accounts = [...rollup.accountSummaries]
      .sort((a, b) => b.totalTokens - a.totalTokens)
      .map((a) => ({ id: a.id, label: a.accountLabel }));
    const devices = [...new Set(rollup.deviceSummaries.map((d) => d.deviceId))].sort();
    return { providers, models, harnesses, accounts, devices };
  }, [rollup]);

  // Provider-filtered daily series: recolor the heatmap from the sparse
  // per-day provider split (all_time rollup, counter schema v3+). Days with
  // no split data fall back to the unfiltered value rather than zero — a
  // provider filter on a legacy doc must not blank the grid.
  //
  // NOTE: providerFilteredPoints is computed above (next to slicedPoints) and
  // reused here; this comment marks the seam for reviewers.

  // Event path: TWO hooks with separate scopes. rangeEvents stays on the
  // effective window and drives the hour grid, token mix, filtered ranking,
  // and ledger; dayEvents fetches the pinned inspector day independently so
  // pinning a day never collapses the range surfaces to one day.
  // Boundedness requires a LOWER bound (fromDay): the default All view has
  // none, so it stays off the event path and shows the "pick a window" hint
  // instead of scanning all-time history.
  const eventFacets = React.useMemo(
    () => ({
      providers: filters.facets.providers,
      models: filters.facets.models,
      devices: filters.facets.devices,
      harnesses: filters.facets.harnesses,
      accounts: filters.facets.accounts,
    }),
    [filters.facets],
  );
  const rangeEnabled = !!today && activeRange.fromDay != null && activeRange.toDay != null;
  const rangeEventRange = React.useMemo(
    () => ({ fromDay: activeRange.fromDay, toDay: activeRange.toDay }),
    [activeRange.fromDay, activeRange.toDay],
  );
  const rangeEvents = useProfileEvents(eventFacets, rangeEventRange, rangeEnabled);
  const dayEnabled = !!today && filters.day != null;
  const dayEventRange = React.useMemo(
    () => ({ fromDay: filters.day, toDay: filters.day }),
    [filters.day],
  );
  // The inspector's entity focus reuses the range pass (entity rows come from
  // the ledger); only a pinned DAY gets its own query.
  const dayEvents = useProfileEvents(eventFacets, dayEventRange, dayEnabled);
  const inspectorEvents = filters.day ? dayEvents.events : rangeEvents.events;
  const inspectorLoading = filters.day ? dayEvents.loading : rangeEvents.loading;
  const grid = React.useMemo(
    () => (rangeEnabled && !rangeEvents.error ? hourWeekdayGrid(rangeEvents.events) : null),
    [rangeEnabled, rangeEvents.events, rangeEvents.error],
  );
  const mix = React.useMemo(
    () => (rangeEnabled && !rangeEvents.error ? tokenMix(rangeEvents.events) : null),
    [rangeEnabled, rangeEvents.events, rangeEvents.error],
  );
  // Per-day per-model split + provider attribution from the SAME bounded
  // pass (no extra reads): colors heatmap cells by the day's dominant model
  // wherever the rollup's provider split is absent, and feeds the hover mix.
  const modelSplitForHeatmap = React.useMemo(
    () => (rangeEnabled && !rangeEvents.error ? dailyModelTokenSplit(rangeEvents.events) : undefined),
    [rangeEnabled, rangeEvents.error, rangeEvents.events],
  );
  const modelProvidersForHeatmap = React.useMemo(
    () => (rangeEnabled && !rangeEvents.error ? dailyModelProviders(rangeEvents.events) : undefined),
    [rangeEnabled, rangeEvents.error, rangeEvents.events],
  );

  // Facet-scoped hero: when model/harness/account/device facets are active
  // the rollup cannot recompute totals (no daily splits for those groups),
  // so the hero stat row derives from the bounded event pass instead — with
  // an explicit "events in view" label so the source swap never reads as a
  // silent inconsistency. Provider-only facets stay rollup-side (stats).
  const scopedStats = React.useMemo(() => {
    if (!hasEventFacets || !rangeEnabled || rangeEvents.error) return null;
    const tokens = rangeEvents.events.reduce((n, e) => n + e.totalTokens, 0);
    const runs = rangeEvents.events.length;
    const cost = rangeEvents.events.reduce((n, e) => n + e.costUsd, 0);
    const days = new Set(
      rangeEvents.events.flatMap((e) => (e.startedAt ? [e.startedAt.slice(0, 10)] : [])),
    );
    return { tokens, runs, cost, activeDays: days.size, capped: rangeEvents.capped };
  }, [hasEventFacets, rangeEnabled, rangeEvents.events, rangeEvents.error, rangeEvents.capped]);

  const displayName = user?.displayName || user?.email?.split("@")[0] || "Member";
  const handle = user?.email ? `@${user.email.split("@")[0]}` : null;

  const metric = filters.metric;
  /** Full "12.7B tok · 9,178 runs · $309,479" for hover titles. */
  const fmtFull = (tokens: number, runs: number, cost: number): string =>
    `${formatCompact(tokens)} tok · ${formatCompact(runs)} runs · ${formatUsd(cost)}`;
  const joinedDays =
    today && user?.metadata.creationTime ? daysSince(user.metadata.creationTime, today) : null;
  const initial = displayName.trim().charAt(0).toUpperCase() || "B";

  // Numbers stay as quiet dashes until a rollup has actually landed — a flash
  // of zeros reads as "you have no usage". Once a live doc is on screen, keep
  // showing it through a background rebuild instead of collapsing to dashes.
  const pending = !today || loading || (syncing && source === "empty");
  const num = (v: number) => (pending ? "—" : formatCompact(v));
  const sharePct = (part: number, whole: number): string =>
    whole > 0 ? `${Math.round((part / whole) * 100)}%` : "—";
  /** Winner share under the ACTIVE metric (tokens/runs/spend all divide alike). */
  const metricShare = (tokens: number, runs: number, cost: number): string =>
    metric === "tokens"
      ? sharePct(tokens, rollup.totals.tokens)
      : metric === "runs"
        ? sharePct(runs, rollup.totals.requests)
        : sharePct(cost, rollup.totals.costUsd);

  // All-time records: computed from the UNSLICED lifetime series so the
  // hall of fame never shrinks with the window. Busiest/loyal follow the
  // active metric; day/streak tiles are token-native by definition.
  const lifetime = React.useMemo(() => {
    if (!today) return null;
    const points = rollup.dailyPoints;
    const active = new Set(points.filter((p) => p.tokens > 0).map((p) => p.day));
    const streaks = computeStreaks(active, today);
    const peak = peakDay(points);
    const sortedActive = [...active].sort();
    const firstBurn = sortedActive.length > 0 ? (sortedActive[0] ?? null) : null;
    const spanDays = firstBurn ? daysSince(`${firstBurn}T00:00:00Z`, today) + 1 : 0;
    return { streaks, peak, activeDays: active.size, firstBurn, spanDays };
  }, [rollup.dailyPoints, today]);

  // Windowed rollup doc: presets (7d/30d/90d) read their own
  // `usage_rollups/{window}` doc — same existing rollup, no new server —
  // so hero totals AND breakdown summaries are window-true and metric-true
  // (requests/costUsd live in totals; the daily series is tokens-only).
  // Custom ranges and All fall back to the all_time doc + token slicing.
  const windowKey =
    filters.from || filters.to ? null : filters.window === "all" ? "all_time" : filters.window;
  const [windowRollup, setWindowRollup] = React.useState<typeof rollup | null>(null);
  // A FAILED window-doc read must never silently render lifetime data under
  // a window label — track it explicitly and say so in the hero.
  const [windowRollupFailed, setWindowRollupFailed] = React.useState(false);
  React.useEffect(() => {
    if (!user || !windowKey || windowKey === "all_time") {
      setWindowRollup(null);
      setWindowRollupFailed(false);
      return;
    }
    let cancelled = false;
    setWindowRollupFailed(false);
    getWindowRollup(user.uid, windowKey).then((r) => {
      if (cancelled) return;
      setWindowRollup(r);
      setWindowRollupFailed(r == null);
    });
    return () => {
      cancelled = true;
    };
  }, [user, windowKey]);
  /** Totals/summaries source: window doc when preset-windowed, else all_time. */
  const totalsRollup = windowRollup ?? rollup;

  // Hero stat row: metric-aware (Tokens / Runs / Spend).
  // - Event facets active → bounded event aggregates, labeled "events".
  // - Provider-only facets → the provider-filtered series (tokens) and the
  //   range event pass (runs/spend when bounded, else lifetime-labeled).
  // - No facets → the totals source (window doc when preset-windowed).
  // Token-native series (heatmap, rhythm, trend, hour grid, mix) keep token
  // labels — the metric ranks summaries, not time series.
  const hero = React.useMemo(() => {
    if (scopedStats) {
      const value =
        metric === "tokens"
          ? formatCompact(scopedStats.tokens)
          : metric === "runs"
            ? formatCompact(scopedStats.runs)
            : formatUsd(scopedStats.cost);
      const label =
        metric === "tokens"
          ? "Tokens in view"
          : metric === "runs"
            ? "Runs in view"
            : "Spend in view";
      return {
        value,
        label: `${label} · events${scopedStats.capped ? " (capped)" : ""}`,
        peak: formatCompact(scopedStats.tokens),
        peakLabel: "filtered total",
        activeDays: String(scopedStats.activeDays),
        avgPerDay: undefined as string | undefined,
      };
    }
    const providerOnly =
      filters.facets.providers.length > 0 && !hasEventFacets;
    const t = totalsRollup.totals;
    const scope =
      windowKey === null
        ? "in custom range"
        : windowKey === "all_time"
          ? "Lifetime"
          : `in last ${filters.window}`;
    const fallbackNote = windowRollupFailed ? " · window unavailable, lifetime shown" : "";
    // Tokens follow the provider-filtered series when a provider facet is
    // active; runs/spend follow the range event pass when bounded.
    const tokenValue = providerOnly
      ? sumTokens(providerFilteredPoints)
      : windowKey
        ? t.tokens
        : (stats?.totalTokens ?? 0);
    const eventSums =
      rangeEnabled && !rangeEvents.error
        ? {
            runs: rangeEvents.events.length,
            cost: rangeEvents.events.reduce((n, e) => n + e.costUsd, 0),
          }
        : null;
    const value =
      metric === "tokens"
        ? formatCompact(tokenValue)
        : metric === "runs"
          ? formatCompact(eventSums ? eventSums.runs : t.requests)
          : formatUsd(eventSums ? eventSums.cost : t.costUsd);
    const unit = metric === "tokens" ? "Tokens" : metric === "runs" ? "Runs" : "Spend";
    const eventSourced = metric !== "tokens" && eventSums != null && !providerOnly;
    return {
      value,
      label: `${unit} ${scope === "Lifetime" ? "· lifetime" : scope}${eventSourced ? " · events" : ""}${fallbackNote}`,
      peak: num(stats?.peak?.tokens ?? 0),
      peakLabel: stats?.peak ? formatDayLabel(stats.peak.day) : undefined,
      activeDays: pending ? "—" : String(stats?.activeDays ?? 0),
      avgPerDay: stats ? `${formatCompact(stats.avgPerActiveDay)} avg/day` : undefined,
    };
  }, [
    scopedStats,
    metric,
    totalsRollup,
    windowKey,
    filters.window,
    filters.facets.providers.length,
    hasEventFacets,
    providerFilteredPoints,
    rangeEnabled,
    rangeEvents.events,
    rangeEvents.error,
    stats,
    pending,
    windowRollupFailed,
  ]);

  // Hour-cell → pin the most active day of that weekday in range: the honest
  // client-side resolution without a server hour field.
  const pickHourCell = React.useCallback(
    (weekday: number, hour: number) => {
      const counts = new Map<string, number>();
      for (const e of rangeEvents.events) {
        if (!e.startedAt || e.hourUtc !== hour) continue;
        const day = e.startedAt.slice(0, 10);
        const [y, m, d] = day.split("-").map(Number);
        if (new Date(Date.UTC(y ?? 1970, (m ?? 1) - 1, d ?? 1)).getUTCDay() !== weekday) continue;
        counts.set(day, (counts.get(day) ?? 0) + e.totalTokens);
      }
      let best: string | null = null;
      let bestTokens = 0;
      for (const [day, tokens] of counts) {
        if (tokens > bestTokens) {
          bestTokens = tokens;
          best = day;
        }
      }
      if (best) applyFilters({ ...filters, day: best });
    },
    [applyFilters, filters, rangeEvents.events],
  );

  const focusLedgerEvent = React.useCallback(
    (e: ProfileUsageEvent) => {
      if (e.startedAt) {
        applyFilters({ ...filters, day: e.startedAt.slice(0, 10) });
      } else if (e.sessionId) {
        applyFilters({ ...filters, entity: { kind: "session", id: e.sessionId } });
      }
    },
    [applyFilters, filters],
  );

  const mvOf = (m: (typeof totalsRollup.modelSummaries)[number]) =>
    metric === "tokens" ? m.tokens : metric === "runs" ? m.requests : m.cost;
  // Window-scoped model winner for the insight rail (the records band
  // keeps its own lifetime values below).
  const topModelByMetric = [...totalsRollup.modelSummaries].sort((a, b) => mvOf(b) - mvOf(a))[0];
  // Lifetime-scoped winners for the records band — the hall of fame never
  // shrinks with the window, and shares divide lifetime totals.
  const recordProvider = [...rollup.providerSummaries].sort((a, b) => {
    const va = metric === "tokens" ? a.totalTokens : metric === "runs" ? a.totalRequests : a.totalCost;
    const vb = metric === "tokens" ? b.totalTokens : metric === "runs" ? b.totalRequests : b.totalCost;
    return vb - va;
  })[0];
  const recordModel = [...rollup.modelSummaries].sort((a, b) => {
    const va = metric === "tokens" ? a.tokens : metric === "runs" ? a.requests : a.cost;
    const vb = metric === "tokens" ? b.tokens : metric === "runs" ? b.requests : b.cost;
    return vb - va;
  })[0];
  const ledgerHint =
    !rangeEnabled && !loading
      ? "Pick a 7/30/90-day window (or a custom range) to page the runs behind this mine."
      : null;

  return (
    <div className="mx-auto w-full max-w-6xl">
      {/* Identity header */}
      <header className="reveal flex flex-col items-center gap-token-3 text-center" style={REVEAL.header}>
        {user?.photoURL && !avatarFailed ? (
          <img
            src={user.photoURL}
            alt=""
            referrerPolicy="no-referrer"
            onError={() => setAvatarFailed(true)}
            className="size-20 rounded-full border border-glass-line object-cover"
          />
        ) : (
          <span
            className="flex size-20 items-center justify-center rounded-full border border-glass-line font-display text-3xl text-content-bright"
            style={{ background: "var(--accent-wash)" }}
            aria-hidden
          >
            {initial}
          </span>
        )}
        <div>
          <h1 className="font-display text-3xl text-content-bright">{displayName}</h1>
          {handle && <p className="mt-1 text-sm text-content-mute">{handle}</p>}
        </div>
        <div className="flex flex-wrap items-center justify-center gap-x-3 gap-y-2">
          {joinedDays != null && (
            <span className="folio text-content-dim">Joined {joinedDays} days ago</span>
          )}
          {!pending && (
            <span className="folio text-content-dim">
              {rollup.providerSummaries.length} providers · {rollup.modelSummaries.length} models ·{" "}
              {rollup.executionSourceSummaries.length} harnesses
              {rollup.accountSummaries.length > 0 &&
                ` · ${rollup.accountSummaries.length} accounts`}
              {rollup.deviceSummaries.length > 0 &&
                ` · ${rollup.deviceSummaries.length} devices`}
            </span>
          )}
          <button
            type="button"
            onClick={() => reload(true)}
            disabled={syncing || loading}
            className="inline-flex items-center gap-1.5 rounded-full border border-glass-line px-3 py-1 text-xs text-content-dim transition-colors hover:border-accent hover:text-content-bright disabled:opacity-50"
            title="Re-read and compute usage rollups from cloud usage events"
          >
            <RefreshCw className={cn("size-3", syncing && "animate-spin text-[color:var(--accent-deep)]")} />
            <span>{syncing ? "Syncing…" : "Sync Usage"}</span>
          </button>
        </div>
      </header>

      {error && (
        <div
          role="alert"
          className="mt-token-6 text-center text-sm"
          style={{ color: "var(--color-seal-crimson)" }}
        >
          {error}
        </div>
      )}
      {syncing && (
        <p role="status" className="reveal mt-token-6 text-center text-sm text-content-mute">
          <span className="animate-pulse">Syncing your usage history…</span>{" "}
          <span className="text-content-dim">aggregating tokens, runs, and streaks across all models.</span>
        </p>
      )}
      {!error && !loading && !syncing && source === "empty" && (
        <p className="mt-token-6 text-center text-sm text-content-mute">
          No usage has synced from your devices yet — this page fills in as the
          BurnBar app reports usage to your account.{" "}
          <button
            type="button"
            onClick={() => reload(true)}
            className="font-medium text-[color:var(--accent-deep)] underline-offset-2 hover:underline"
          >
            Re-sync now
          </button>
        </p>
      )}

      {/* Filter rail — sticky under the identity header. */}
      <div className="reveal mt-token-6" style={REVEAL.filters}>
        <ProfileFilterRail
          filters={filters}
          options={facetOptions}
          computedAt={rollup.computedAt}
          snapNotice={snapNotice}
          onChange={applyFilters}
          onClear={() => applyFilters(clearMineFilters(filters))}
        />
      </div>

      {/* Stat row — totals follow the active window slice (All = lifetime). */}
      <div className="reveal mt-token-8" style={REVEAL.stats}>
        <ProfileHeroStats
          pending={pending}
          lifetime={pending ? "—" : hero.value}
          lifetimeLabel={hero.label}
          peak={pending ? "—" : hero.peak}
          peakLabel={!pending ? hero.peakLabel : undefined}
          activeDays={pending ? "—" : hero.activeDays}
          avgPerDay={!pending ? hero.avgPerDay : undefined}
          currentStreak={pending ? "—" : `${stats?.streaks.current ?? 0}d`}
          longestStreak={pending ? "—" : `${stats?.streaks.longest ?? 0}d`}
        />
      </div>

      <div className="mt-token-12 grid min-w-0 gap-token-12 xl:grid-cols-12 xl:gap-token-10">
        <div className="grid min-w-0 content-start gap-token-12 xl:col-span-7">
          {/* Token activity heatmap — click a day to pin the inspector.
              Anchored on the view's right edge so a historical range never
              renders a blank tail past its end. */}
          <div className="reveal min-w-0" style={REVEAL.heatmap}>
            {viewToday ? (
              <ProfileHeatmapSection
                points={providerFilteredPoints}
                today={viewToday > (today ?? viewToday) ? (today ?? viewToday) : viewToday}
                dailyProviderTokens={rollup.dailyProviderTokens}
                dailyModelTokens={modelSplitForHeatmap}
                dailyModelProviders={modelProvidersForHeatmap}
                activeProviders={filters.facets.providers}
                pinnedDay={filters.day}
                onPinDay={(day) => applyFilters({ ...filters, day })}
              />
            ) : (
              <div className="h-40 rounded-lg border border-glass-line" aria-hidden />
            )}
          </div>

          {/* Burn by hour — bounded event aggregates. */}
          <div className="reveal min-w-0" style={REVEAL.rhythm}>
            <ProfileHourGrid
              grid={grid}
              loading={rangeEvents.loading}
              error={rangeEvents.error ? profileEventErrorCopy(rangeEvents.error) : null}
              capped={rangeEvents.capped}
              eventCount={rangeEvents.events.length}
              onPickCell={pickHourCell}
            />
          </div>

          {/* Burn rhythm — mean tokens by weekday, in view. */}
          <div className="reveal min-w-0" style={REVEAL.rhythm}>
            {today && stats ? (
              <ProfileRhythmSection
                rhythm={stats.rhythm}
                rhythmMax={stats.rhythmMax}
                pending={pending}
              />
            ) : (
              <div className="h-36 rounded-lg border border-glass-line" aria-hidden />
            )}
          </div>

          {/* Token trend */}
          <div className="reveal min-w-0" style={REVEAL.trend}>
            <ProfileTrendSection trend={stats?.trend ?? []} pending={pending} />
          </div>

          {/* Token mix — bounded event aggregates. */}
          <div className="reveal min-w-0" style={REVEAL.trend}>
            <ProfileMixPanel
              mix={mix}
              loading={rangeEvents.loading}
              error={rangeEvents.error ? profileEventErrorCopy(rangeEvents.error) : null}
            />
          </div>
        </div>

        {/* Insights rail — full ranked lists, every row a filter control. */}
        <aside
          aria-label="Activity insights"
          className="reveal grid min-w-0 content-start gap-token-8 xl:col-span-5"
          style={REVEAL.insights}
        >
          <ProfileProviderMix
            providers={totalsRollup.providerSummaries}
            metric={metric}
            pending={pending}
            activeProviders={filters.facets.providers}
            onToggleProvider={(id) => selectFacet({ kind: "provider", id })}
          />

          <ProfileInsightsPanel
            pending={pending}
            activeDays={stats?.activeDays ?? 0}
            avgPerActiveDay={stats?.avgPerActiveDay ?? 0}
            topModel={topModelByMetric ?? null}
            spendInView={totalsRollup.providerSummaries.reduce((n, p) => n + p.totalCost, 0)}
            freshness={rollup.computedAt ? rollup.computedAt.slice(0, 10) : pending ? "—" : "unknown"}
            onToggleModel={(id) => selectFacet({ kind: "model", id })}
          />

          {!pending && (
            <ProfileBreakdowns
              data={{
                providers: [],
                models: totalsRollup.modelSummaries,
                harnesses: totalsRollup.executionSourceSummaries,
                combos: totalsRollup.comboSummaries,
                devices: totalsRollup.deviceSummaries,
                accounts: totalsRollup.accountSummaries,
              }}
              metric={metric}
              activeFacets={filters.facets}
              onToggle={toggleFacet}
              onInspect={selectFacet}
            />
          )}
          {!pending &&
            rankShares(rangeEvents.events, "provider").length > 0 &&
            hasEventFacets && (
              <div>
                <h2 className="eyebrow mb-token-3">In this filtered view</h2>
                <ul className="space-y-token-2">
                  {rankShares(rangeEvents.events, "provider")
                    .slice(0, 5)
                    .map((r) => (
                      <li
                        key={r.key}
                        className="flex items-center gap-2 text-sm"
                        title={`${formatCompact(r.tokens)} tok · ${r.events} runs · ${formatUsd(r.cost)} (bounded events)`}
                      >
                        <span className="truncate text-content-bright">
                          {providerDisplayName(r.label)}
                        </span>
                        <span className="ml-auto shrink-0 text-content-mute tabular-nums">
                          {formatCompact(r.tokens)}
                        </span>
                      </li>
                    ))}
                </ul>
              </div>
            )}
        </aside>
      </div>

      {/* Records — the all-time hall of fame, always lifetime-scoped.
          Busiest/loyal follow the active metric INCLUDING their shares;
          day/streak tiles pin days or jump to the rhythm strip. */}
      <div className="reveal mt-token-12" style={REVEAL.records}>
        <ProfileRecords
          records={{
            busiestProvider: recordProvider
              ? {
                  id: recordProvider.provider,
                  label: providerDisplayName(recordProvider.provider),
                  share: metricShare(
                    recordProvider.totalTokens,
                    recordProvider.totalRequests,
                    recordProvider.totalCost,
                  ),
                  title: fmtFull(
                    recordProvider.totalTokens,
                    recordProvider.totalRequests,
                    recordProvider.totalCost,
                  ),
                }
              : null,
            loyalModel: recordModel
              ? {
                  id: recordModel.model,
                  label: recordModel.model,
                  share: metricShare(
                    recordModel.tokens,
                    recordModel.requests,
                    recordModel.cost,
                  ),
                  title: recordModel.model,
                }
              : null,
            biggestDay: lifetime?.peak ? { day: lifetime.peak.day, tokens: lifetime.peak.tokens } : null,
            longestStreak: lifetime?.streaks.longest ?? 0,
            activeDays: lifetime?.activeDays ?? 0,
            firstBurn: lifetime?.firstBurn ?? null,
            spanDays: lifetime?.spanDays ?? 0,
            burnRate:
              lifetime && lifetime.spanDays > 0
                ? `${Math.round((lifetime.activeDays / lifetime.spanDays) * 100)}%`
                : null,
            pending,
          }}
          onPinDay={(day) => applyFilters({ ...filters, day })}
          onToggleProvider={(id) => toggleFacet({ kind: "provider", id })}
          onToggleModel={(id) => toggleFacet({ kind: "model", id })}
          onInspectEntity={inspectRecord}
          onJumpToRhythm={() => {
            document
              .getElementById("profile-burn-rhythm")
              ?.scrollIntoView({ behavior: "smooth", block: "center" });
          }}
        />
      </div>

      {/* Session ledger — bounded event pages (auto-paged to the cap). */}
      <div className="reveal mt-token-12" style={REVEAL.ledger}>
        <ProfileSessionLedger
          events={rangeEvents.events}
          loading={rangeEvents.loading}
          error={rangeEvents.error ? profileEventErrorCopy(rangeEvents.error) : null}
          hasMore={rangeEvents.hasMore}
          capped={rangeEvents.capped}
          enabledHint={ledgerHint}
          onLoadMore={rangeEvents.loadMore}
          onFocusEvent={focusLedgerEvent}
        />
      </div>

      {/* Inspector slide-over — the pinned day (own query) or an entity from
          the range pass. Prev/next clamps to the active range. Query failures
          surface stable copy + retry, never a false zero.
          Closing clears the pin; every number, bar, day, and record row
          reopens it, so the inspector is never stranded unreachable. */}
      <ProfileInspector
        selection={inspector}
        events={inspectorEvents}
        loading={inspectorLoading}
        error={
          filters.day
            ? dayEvents.error
              ? profileEventErrorCopy(dayEvents.error)
              : null
            : rangeEvents.error
              ? profileEventErrorCopy(rangeEvents.error)
              : null
        }
        onRetry={filters.day ? dayEvents.loadMore : rangeEvents.loadMore}
        onClose={() => applyFilters({ ...filters, day: null, entity: null })}
        onPinDay={(day) => applyFilters({ ...filters, day })}
        onPrevDay={() => stepDay(-1)}
        onNextDay={() => stepDay(1)}
      />

      <p className="reveal folio mt-token-12 text-center text-content-dim" style={REVEAL.footer}>
        Only what BurnBar really records — fast mode and skill usage aren&apos;t tracked yet.
      </p>
    </div>
  );
}
