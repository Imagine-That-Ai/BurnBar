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
  needsEventPath,
  parseProfileFilters,
  serializeProfileFilters,
  sliceDailyPoints,
  snapWindowForEventFacets,
  toggleFacetValue,
  type ProfileFilters,
} from "@/lib/profile/profileFilters";
import {
  hourWeekdayGrid,
  rankShares,
  tokenMix,
} from "@/lib/profile/profileAggregates";
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
import type { ProfileUsageEvent } from "@/lib/profile/profileEvents";
import { cn } from "@/lib/utils";

/** Days between an ISO timestamp and a "YYYY-MM-DD" day key (UTC, floor). */
function daysSince(iso: string, today: string): number {
  const start = Date.parse(iso);
  const end = Date.parse(today + "T00:00:00Z");
  if (!Number.isFinite(start) || !Number.isFinite(end)) return 0;
  return Math.max(0, Math.floor((end - start) / 86_400_000));
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
  // and Suspense-free for the static export.
  const [filters, setFilters] = React.useState<ProfileFilters>(() => emptyFilters());
  const [snapNotice, setSnapNotice] = React.useState<string | null>(null);
  React.useEffect(() => {
    try {
      setFilters(parseProfileFilters(window.location.search));
    } catch {
      /* malformed query — stay on defaults */
    }
  }, []);
  const applyFilters = React.useCallback((next: ProfileFilters) => {
    // The 91k-event guard: event facets on unbounded All snap to 90d, once.
    const snapped = snapWindowForEventFacets(next);
    if (snapped) {
      setSnapNotice("Model / harness / account filters need a bounded range — snapped to 90d.");
      next = snapped;
    }
    setFilters(next);
    try {
      const qs = serializeProfileFilters(next);
      window.history.replaceState(null, "", qs ? `/profile?${qs}` : "/profile");
    } catch {
      /* history unavailable (tests) — filters still apply in-memory */
    }
  }, []);

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
  // (ledger row). Day prev/next steps within the active range.
  const inspector: InspectorSelection | null = filters.day
    ? { kind: "day", day: filters.day }
    : filters.entity
      ? { kind: "entity", entity: filters.entity }
      : null;
  const stepDay = React.useCallback(
    (delta: -1 | 1) => {
      if (!today || !filters.day) return;
      const next = addDays(filters.day, delta);
      if (next > today) return;
      applyFilters({ ...filters, day: next });
    },
    [applyFilters, filters, today],
  );

  // Instant path: slice the all_time daily series to the active range.
  // Provider-only filters recolor the heatmap through dailyProviderTokens;
  // model/harness/account/device facets need the event path below.
  const slicedPoints = React.useMemo(() => {
    if (!today) return rollup.dailyPoints;
    return sliceDailyPoints(rollup.dailyPoints, filters, today);
  }, [rollup.dailyPoints, filters, today]);

  const stats = React.useMemo(() => {
    if (!today) return null;
    const points = slicedPoints;
    const active = new Set(points.filter((p) => p.tokens > 0).map((p) => p.day));
    const streaks = computeStreaks(active, today);
    const peak = peakDay(points);
    const activeDays = activeDayCount(points);
    const totalTokens = sumTokens(points);
    const trend = points.filter((p) => p.day >= addDays(today, -89));
    const sortedActive = [...active].sort();
    const firstBurn = sortedActive.length > 0 ? (sortedActive[0] ?? null) : null;
    const rhythm = weekdayRhythm(points, firstBurn ?? today, today);
    const rhythmMax = Math.max(...rhythm.map((r) => r.avg), 0);
    const spanDays = firstBurn ? daysSince(`${firstBurn}T00:00:00Z`, today) + 1 : 0;
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
  }, [slicedPoints, today]);

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

  // Event path: bounded range + active facets → paginated usage reads.
  // The inspector's day/entity pins force the path on so a pinned day always
  // has events to show; provider-only heatmap recoloring stays rollup-side.
  const range = React.useMemo(() => {
    if (!today) return { fromDay: null as string | null, toDay: null as string | null };
    if (filters.day) return { fromDay: filters.day, toDay: filters.day };
    return effectiveRange(filters, today);
  }, [filters, today]);
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
  const boundedRange = range.fromDay != null || range.toDay != null;
  const eventsEnabled =
    !!today && (needsEventPath(filters) || boundedRange) && range.toDay != null;
  const eventRange = React.useMemo(
    () => ({ fromDay: range.fromDay, toDay: range.toDay }),
    // range is already memoed on [filters, today]; its fields are the deps.
    [range.fromDay, range.toDay],
  );
  const profileEvents = useProfileEvents(eventFacets, eventRange, eventsEnabled);
  const grid = React.useMemo(
    () => (eventsEnabled && !profileEvents.error ? hourWeekdayGrid(profileEvents.events) : null),
    [eventsEnabled, profileEvents.events, profileEvents.error],
  );
  const mix = React.useMemo(
    () => (eventsEnabled && !profileEvents.error ? tokenMix(profileEvents.events) : null),
    [eventsEnabled, profileEvents.events, profileEvents.error],
  );

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

  // Metric-aware top-model insight (Tokens / Runs / Spend re-rank).
  const topModelInsight = React.useMemo(() => {
    const v = (m: (typeof rollup.modelSummaries)[number]) =>
      metric === "tokens" ? m.tokens : metric === "runs" ? m.requests : m.cost;
    return [...rollup.modelSummaries].sort((a, b) => v(b) - v(a))[0] ?? null;
  }, [rollup.modelSummaries, metric]);

  // Hour-cell → pin the most active day of that weekday in range: the honest
  // client-side resolution without a server hour field.
  const pickHourCell = React.useCallback(
    (weekday: number, hour: number) => {
      const counts = new Map<string, number>();
      for (const e of profileEvents.events) {
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
    [applyFilters, filters, profileEvents.events],
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

  const topProviderByTokens = [...rollup.providerSummaries].sort(
    (a, b) => b.totalTokens - a.totalTokens,
  )[0];
  const topModelByTokens = [...rollup.modelSummaries].sort((a, b) => b.tokens - a.tokens)[0];
  const ledgerHint =
    !eventsEnabled && !loading
      ? "Pick a window under All (or a custom range) to page the runs behind this mine."
      : null;
  const isAll = filters.window === "all" && !filters.from && !filters.to;

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
          lifetime={num(stats?.totalTokens ?? 0)}
          lifetimeLabel={isAll ? "Lifetime tokens" : "Tokens in view"}
          peak={num(stats?.peak?.tokens ?? 0)}
          peakLabel={stats?.peak ? formatDayLabel(stats.peak.day) : undefined}
          activeDays={pending ? "—" : String(stats?.activeDays ?? 0)}
          avgPerDay={
            stats ? `${formatCompact(stats.avgPerActiveDay)} avg/day` : undefined
          }
          currentStreak={pending ? "—" : `${stats?.streaks.current ?? 0}d`}
          longestStreak={pending ? "—" : `${stats?.streaks.longest ?? 0}d`}
        />
      </div>

      <div className="mt-token-12 grid min-w-0 gap-token-12 xl:grid-cols-12 xl:gap-token-10">
        <div className="grid min-w-0 content-start gap-token-12 xl:col-span-7">
          {/* Token activity heatmap — click a day to pin the inspector. */}
          <div className="reveal" style={REVEAL.heatmap}>
            {today ? (
              <ProfileHeatmapSection
                points={providerFilteredPoints}
                today={today}
                dailyProviderTokens={rollup.dailyProviderTokens}
                pinnedDay={filters.day}
                onPinDay={(day) => applyFilters({ ...filters, day })}
              />
            ) : (
              <div className="h-40 rounded-lg border border-glass-line" aria-hidden />
            )}
          </div>

          {/* Burn by hour — bounded event aggregates. */}
          <div className="reveal" style={REVEAL.rhythm}>
            <ProfileHourGrid
              grid={grid}
              loading={profileEvents.loading}
              error={profileEvents.error}
              capped={profileEvents.capped}
              eventCount={profileEvents.events.length}
              onPickCell={pickHourCell}
            />
          </div>

          {/* Burn rhythm — mean tokens by weekday, in view. */}
          <div className="reveal" style={REVEAL.rhythm}>
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
          <div className="reveal" style={REVEAL.trend}>
            <ProfileTrendSection trend={stats?.trend ?? []} pending={pending} />
          </div>

          {/* Token mix — bounded event aggregates. */}
          <div className="reveal" style={REVEAL.trend}>
            <ProfileMixPanel
              mix={mix}
              loading={profileEvents.loading}
              error={profileEvents.error}
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
            providers={rollup.providerSummaries}
            metric={metric}
            pending={pending}
            activeProviders={filters.facets.providers}
            onToggleProvider={(id) => toggleFacet({ kind: "provider", id })}
          />

          <ProfileInsightsPanel
            pending={pending}
            activeDays={stats?.activeDays ?? 0}
            avgPerActiveDay={stats?.avgPerActiveDay ?? 0}
            topModel={topModelInsight}
            spendInView={rollup.providerSummaries.reduce((n, p) => n + p.totalCost, 0)}
            freshness={rollup.computedAt ? rollup.computedAt.slice(0, 10) : pending ? "—" : "unknown"}
            onToggleModel={(id) => toggleFacet({ kind: "model", id })}
          />

          {!pending && (
            <ProfileBreakdowns
              data={{
                providers: [],
                models: rollup.modelSummaries,
                harnesses: rollup.executionSourceSummaries,
                combos: rollup.comboSummaries,
                devices: rollup.deviceSummaries,
                accounts: rollup.accountSummaries,
              }}
              metric={metric}
              activeFacets={filters.facets}
              onToggle={toggleFacet}
            />
          )}
          {!pending &&
            rankShares(profileEvents.events, "provider").length > 0 &&
            (filters.facets.models.length > 0 ||
              filters.facets.harnesses.length > 0 ||
              filters.facets.accounts.length > 0) && (
              <div>
                <h2 className="eyebrow mb-token-3">In this filtered view</h2>
                <ul className="space-y-token-2">
                  {rankShares(profileEvents.events, "provider")
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

      {/* Records — clickable hall of fame. */}
      <div className="reveal mt-token-12" style={REVEAL.records}>
        <ProfileRecords
          records={{
            busiestProvider: topProviderByTokens
              ? {
                  id: topProviderByTokens.provider,
                  label: providerDisplayName(topProviderByTokens.provider),
                  share: sharePct(topProviderByTokens.totalTokens, rollup.totals.tokens),
                  title: fmtFull(
                    topProviderByTokens.totalTokens,
                    topProviderByTokens.totalRequests,
                    topProviderByTokens.totalCost,
                  ),
                }
              : null,
            loyalModel: topModelByTokens
              ? {
                  id: topModelByTokens.model,
                  label: topModelByTokens.model,
                  share: sharePct(topModelByTokens.tokens, rollup.totals.tokens),
                  title: topModelByTokens.model,
                }
              : null,
            biggestDay: stats?.peak ? { day: stats.peak.day, tokens: stats.peak.tokens } : null,
            longestStreak: stats?.streaks.longest ?? 0,
            activeDays: stats?.activeDays ?? 0,
            firstBurn: stats?.firstBurn ?? null,
            spanDays: stats?.spanDays ?? 0,
            burnRate:
              stats && stats.spanDays > 0
                ? `${Math.round((stats.activeDays / stats.spanDays) * 100)}%`
                : null,
            pending,
          }}
          onPinDay={(day) => applyFilters({ ...filters, day })}
          onToggleProvider={(id) => toggleFacet({ kind: "provider", id })}
          onToggleModel={(id) => toggleFacet({ kind: "model", id })}
        />
      </div>

      {/* Session ledger — bounded event pages. */}
      <div className="reveal mt-token-12" style={REVEAL.ledger}>
        <ProfileSessionLedger
          events={profileEvents.events}
          loading={profileEvents.loading}
          error={profileEvents.error}
          hasMore={profileEvents.hasMore}
          capped={profileEvents.capped}
          enabledHint={ledgerHint}
          onLoadMore={profileEvents.loadMore}
          onFocusEvent={focusLedgerEvent}
        />
      </div>

      {/* Inspector slide-over — day or entity. */}
      <ProfileInspector
        selection={inspector}
        events={profileEvents.events}
        loading={profileEvents.loading}
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
