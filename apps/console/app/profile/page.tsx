"use client";

/**
 * /profile — the member's usage profile, modeled on the Codex/Cursor public
 * activity pages: identity header, lifetime stat row, a contribution heatmap
 * of daily token activity (Daily / Weekly / Cumulative), a token trend, and
 * honest "most used" breakdowns.
 *
 * Every number comes from users/{uid}/usage_rollups/all_time — the page
 * inherits the console's standing invariant: real data or an elegant zero,
 * never a mock.
 */

import * as React from "react";

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
} from "@/lib/profile/activityStats";
import {
  ContributionHeatmap,
  type HeatmapMode,
} from "@/components/profile/ContributionHeatmap";
import {
  ProportionBar,
  Sparkline,
  formatCompact,
} from "@/components/dashboard/cards/primitives";
import { BrandLogo } from "@/components/BrandLogo";
import { PlanBadge } from "@/components/PlanBadge";
import { useDomainUsage } from "@/lib/useDomainUsage";
import { cn } from "@/lib/utils";

const HEATMAP_MODES: { key: HeatmapMode; label: string }[] = [
  { key: "daily", label: "Daily" },
  { key: "weekly", label: "Weekly" },
  { key: "cumulative", label: "Cumulative" },
];

/** Days between an ISO timestamp and a "YYYY-MM-DD" day key (UTC, floor). */
function daysSince(iso: string, today: string): number {
  const start = Date.parse(iso);
  const end = Date.parse(today + "T00:00:00Z");
  if (!Number.isFinite(start) || !Number.isFinite(end)) return 0;
  return Math.max(0, Math.floor((end - start) / 86_400_000));
}

/** Staggered entrance delays for the reveal kit (globals.css .reveal). */
const REVEAL: Record<"header" | "stats" | "heatmap" | "trend" | "insights" | "footer", React.CSSProperties> = {
  header: { "--d": "0ms" } as React.CSSProperties,
  stats: { "--d": "90ms" } as React.CSSProperties,
  heatmap: { "--d": "180ms" } as React.CSSProperties,
  trend: { "--d": "270ms" } as React.CSSProperties,
  insights: { "--d": "360ms" } as React.CSSProperties,
  footer: { "--d": "450ms" } as React.CSSProperties,
};

function HeaderStat({
  value,
  label,
  sub,
  className,
}: {
  value: React.ReactNode;
  label: string;
  sub?: React.ReactNode;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex flex-col items-center gap-1 px-token-4 py-token-4 text-center",
        className,
      )}
    >
      <span className="font-display text-2xl leading-none text-content-bright tabular-nums">
        {value}
      </span>
      <span className="eyebrow">{label}</span>
      {sub != null && <span className="text-xs text-content-dim">{sub}</span>}
    </div>
  );
}

function InsightRow({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-token-4 py-token-2">
      <span className="text-sm text-content-mute">{label}</span>
      <span className="text-right text-sm text-content-bright tabular-nums">{value}</span>
    </div>
  );
}

export default function ProfilePage() {
  const { user } = useAuth();
  const { rollup, source, loading, error, reload } = useProfileUsage();
  const [rebuilding, setRebuilding] = React.useState(false);
  const { data: domainUsage } = useDomainUsage();
  const [mode, setMode] = React.useState<HeatmapMode>("daily");
  // If the IdP / cloud-profile avatar fails to load, fall back to the initial
  // tile instead of a broken image.
  const [avatarFailed, setAvatarFailed] = React.useState(false);

  // "Today" only exists client-side; gating on it keeps the static prerender
  // and the first client render byte-identical (no hydration drift).
  const [today, setToday] = React.useState<string | null>(null);
  React.useEffect(() => setToday(toDayKey(new Date())), []);

  const stats = React.useMemo(() => {
    if (!today) return null;
    const points = rollup.dailyPoints;
    const active = new Set(points.filter((p) => p.tokens > 0).map((p) => p.day));
    const streaks = computeStreaks(active, today);
    const peak = peakDay(points);
    const activeDays = activeDayCount(points);
    const totalTokens = rollup.totals.tokens || sumTokens(points);
    const topProvider = rollup.providerSummaries[0] ?? null;
    const providerTokens = rollup.providerSummaries.reduce((n, p) => n + p.totalTokens, 0);
    const topModels = rollup.modelSummaries.slice(0, 5);
    const modelMax = topModels.length > 0 ? topModels[0].tokens : 0;
    const topHarnesses = rollup.executionSourceSummaries.slice(0, 5);
    const harnessMax = topHarnesses.length > 0 ? topHarnesses[0].totalTokens : 0;
    const topCombos = rollup.comboSummaries.slice(0, 5);
    const comboMax = topCombos.length > 0 ? topCombos[0].tokens : 0;
    // Trend: the trailing 90 days inclusive of today.
    const cutoff = addDays(today, -89);
    const trend = points.filter((p) => p.day >= cutoff);
    return {
      streaks,
      peak,
      activeDays,
      totalTokens,
      avgPerActiveDay: activeDays > 0 ? Math.round(totalTokens / activeDays) : 0,
      topProvider,
      topProviderShare:
        topProvider && providerTokens > 0 ? topProvider.totalTokens / providerTokens : 0,
      topModels,
      modelMax,
      topHarnesses,
      harnessMax,
      topCombos,
      comboMax,
      trend,
    };
  }, [rollup, today]);

  const cloudProfile = domainUsage?.account?.profile;
  const displayName =
    user?.displayName || cloudProfile?.displayName || user?.email?.split("@")[0] || "Member";
  const handle = user?.email ? `@${user.email.split("@")[0]}` : null;
  const photoURL = user?.photoURL || cloudProfile?.avatarURL || null;
  // Only paint a badge once the callable actually returned a tier — a
  // loading/error flash of "free" is a lie.
  const tier = domainUsage?.tier;
  const joinedDays =
    today && user?.metadata.creationTime ? daysSince(user.metadata.creationTime, today) : null;
  const initial = displayName.trim().charAt(0).toUpperCase() || "B";
  const updatedLabel = rollup.computedAt ? formatDayLabel(rollup.computedAt.slice(0, 10)) : null;

  // Numbers stay as quiet dashes until the rollup has actually landed — a
  // flash of zeros reads as "you have no usage", which is a lie while loading.
  const pending = loading || !today;
  const num = (v: number) => (pending ? "—" : formatCompact(v));

  const recompute = React.useCallback(() => {
    if (rebuilding) return;
    setRebuilding(true);
    reload(true);
  }, [rebuilding, reload]);

  React.useEffect(() => {
    if (!loading) setRebuilding(false);
  }, [loading]);

  return (
    <div className="mx-auto max-w-3xl xl:mx-0 xl:grid xl:max-w-5xl xl:grid-cols-[minmax(0,1fr)_minmax(15rem,18rem)] xl:items-start xl:gap-x-token-12 xl:gap-y-token-10">
      {/* Identity header spans both columns so the plan badge sits opposite
          the name, not tucked against the insights rail. */}
      <header
        className="reveal flex items-start justify-between gap-token-6 xl:col-span-2"
        style={REVEAL.header}
      >
        <div className="flex min-w-0 items-center gap-token-4">
          {photoURL && !avatarFailed ? (
            <img
              src={photoURL}
              alt=""
              referrerPolicy="no-referrer"
              onError={() => setAvatarFailed(true)}
              className="size-16 shrink-0 rounded-full border border-glass-line object-cover"
            />
          ) : (
            <span
              className="flex size-16 shrink-0 items-center justify-center rounded-full border border-glass-line font-display text-2xl text-content-bright"
              style={{ background: "var(--accent-wash)" }}
              aria-hidden
            >
              {initial}
            </span>
          )}
          <div className="min-w-0">
            <h1 className="font-display text-3xl text-content-bright">{displayName}</h1>
            <p className="mt-1.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-sm text-content-mute">
              {handle && <span>{handle}</span>}
              {handle && joinedDays != null && (
                <span aria-hidden className="text-content-dim">
                  ·
                </span>
              )}
              {joinedDays != null && (
                <span className="folio text-content-dim">Joined {joinedDays} days ago</span>
              )}
            </p>
          </div>
        </div>
        {tier && <PlanBadge tier={tier} />}
      </header>

      {error && (
        <div
          role="alert"
          className="mt-token-6 text-sm xl:col-span-2"
          style={{ color: "var(--color-seal-crimson)" }}
        >
          {error}
        </div>
      )}
      {!error && !loading && source === "empty" && (
        <p className="mt-token-6 text-sm text-content-mute xl:col-span-2">
          No usage has synced from your devices yet — this page fills in as the
          BurnBar app reports usage to your account.
        </p>
      )}

      <div className="min-w-0">
      {/* Lifetime stat row — a divided bar on sm+, individual tiles on mobile. */}
      <section
        aria-label="Lifetime statistics"
        className="reveal mt-token-8 grid grid-cols-2 gap-2 sm:grid-cols-5 sm:gap-0 sm:divide-x sm:divide-glass-line sm:rounded-lg sm:border sm:border-glass-line xl:mt-0"
        style={REVEAL.stats}
      >
        <HeaderStat
          value={num(rollup.totals.tokens)}
          label="Lifetime tokens"
          className="rounded-lg border border-glass-line sm:rounded-none sm:border-0"
        />
        <HeaderStat
          value={num(stats?.peak?.tokens ?? 0)}
          label="Peak tokens"
          sub={!pending && stats?.peak ? formatDayLabel(stats.peak.day) : undefined}
          className="rounded-lg border border-glass-line sm:rounded-none sm:border-0"
        />
        <HeaderStat
          value={num(rollup.totals.requests)}
          label="Total requests"
          className="rounded-lg border border-glass-line sm:rounded-none sm:border-0"
        />
        <HeaderStat
          value={pending ? "—" : `${stats?.streaks.current ?? 0}d`}
          label="Current streak"
          className="rounded-lg border border-glass-line sm:rounded-none sm:border-0"
        />
        <HeaderStat
          value={pending ? "—" : `${stats?.streaks.longest ?? 0}d`}
          label="Longest streak"
          className="col-span-2 rounded-lg border border-glass-line sm:col-span-1 sm:rounded-none sm:border-0"
        />
      </section>

      {/* Token activity heatmap */}
      <section aria-label="Token activity" className="reveal mt-token-12" style={REVEAL.heatmap}>
        <div className="mb-token-4 flex items-center justify-between gap-token-4">
          <h2 className="eyebrow">Token activity</h2>
          <div
            role="group"
            aria-label="Heatmap mode"
            className="flex items-center gap-token-1 rounded-pill border border-glass-line p-0.5"
          >
            {HEATMAP_MODES.map((m) => (
              <button
                key={m.key}
                type="button"
                aria-pressed={mode === m.key}
                onClick={() => setMode(m.key)}
                className={cn(
                  "rounded-pill px-token-3 py-1 text-xs transition-colors duration-150",
                  mode === m.key
                    ? "text-content-bright"
                    : "text-content-dim hover:text-content-mute",
                )}
                style={mode === m.key ? { background: "var(--accent-wash)" } : undefined}
              >
                {m.label}
              </button>
            ))}
          </div>
        </div>
        {today ? (
          <ContributionHeatmap points={rollup.dailyPoints} mode={mode} today={today} />
        ) : (
          <div className="h-40 rounded-lg border border-glass-line" aria-hidden />
        )}
      </section>

      {/* Token trend */}
      <section aria-label="Token trend" className="reveal mt-token-12" style={REVEAL.trend}>
        <h2 className="eyebrow mb-token-1">Tokens</h2>
        <p className="font-display text-2xl text-content-bright tabular-nums">
          {pending ? "—" : `${formatCompact(sumTokens(stats?.trend ?? []))} tokens`}
          <span className="ml-2 text-sm font-normal text-content-dim">last 90 days</span>
        </p>
        <div className="mt-token-3 h-36">
          <Sparkline values={(stats?.trend ?? []).map((p) => p.tokens)} className="h-full" />
        </div>
        <div className="mt-token-2 flex justify-between text-xs text-content-dim">
          <span>{stats?.trend[0] ? formatDayLabel(stats.trend[0].day) : "—"}</span>
          <span>Today</span>
        </div>
      </section>
      </div>

      {/* Insights — a right rail on wide screens, stacked below on narrow ones.
          Harness and combo blocks stay hidden until the rollup actually
          carries execution-source data (fail-soft, never mocked). */}
      <aside
        aria-label="Activity insights"
        className="reveal mt-token-12 grid content-start gap-token-8 sm:grid-cols-2 xl:mt-0 xl:grid-cols-1"
        style={REVEAL.insights}
      >
        <div>
          <h2 className="eyebrow mb-token-3">Activity insights</h2>
          <div className="divide-y divide-glass-line border-y border-glass-line">
            <InsightRow label="Active days" value={pending ? "—" : (stats?.activeDays ?? 0)} />
            <InsightRow label="Avg tokens per active day" value={num(stats?.avgPerActiveDay ?? 0)} />
            <InsightRow
              label="Most used provider"
              value={
                !pending && stats?.topProvider
                  ? `${stats.topProvider.provider} · ${Math.round(stats.topProviderShare * 100)}%`
                  : "—"
              }
            />
            <InsightRow
              label="Most used model"
              value={pending ? "—" : (stats?.topModels[0]?.model ?? "—")}
            />
            <InsightRow
              label="Lifetime spend"
              value={pending ? "—" : `$${rollup.totals.costUsd.toFixed(2)}`}
            />
          </div>
        </div>
        <div>
          <h2 className="eyebrow mb-token-3">Most used models</h2>
          {!pending && stats && stats.topModels.length > 0 ? (
            <ul className="space-y-token-3">
              {stats.topModels.map((m) => (
                <li key={`${m.provider}/${m.model}`}>
                  <div className="mb-1 flex items-baseline justify-between gap-token-4">
                    <span className="truncate text-sm text-content-bright">{m.model}</span>
                    <span className="shrink-0 text-sm text-content-mute tabular-nums">
                      {formatCompact(m.requests)} runs
                    </span>
                  </div>
                  <ProportionBar value={stats.modelMax > 0 ? m.tokens / stats.modelMax : 0} />
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-sm text-content-dim">Nothing in this window yet.</p>
          )}
        </div>

        {!pending && stats && stats.topHarnesses.length > 0 && (
          <div>
            <h2 className="eyebrow mb-token-3">Agent harnesses</h2>
            <ul className="space-y-token-3">
              {stats.topHarnesses.map((h) => (
                <li key={h.sourceId}>
                  <div className="mb-1 flex items-baseline justify-between gap-token-4">
                    <span className="flex min-w-0 items-center gap-2">
                      <BrandLogo id={h.sourceId} label={h.sourceName} />
                      <span className="truncate text-sm text-content-bright">{h.sourceName}</span>
                    </span>
                    <span className="shrink-0 text-sm text-content-mute tabular-nums">
                      {formatCompact(h.totalRequests)} runs
                    </span>
                  </div>
                  <ProportionBar value={stats.harnessMax > 0 ? h.totalTokens / stats.harnessMax : 0} />
                </li>
              ))}
            </ul>
          </div>
        )}

        {!pending && stats && stats.topCombos.length > 0 && (
          <div>
            <h2 className="eyebrow mb-token-3">Combos</h2>
            <ul className="space-y-token-3">
              {stats.topCombos.map((c) => (
                <li key={`${c.sourceId}/${c.provider}/${c.model}`}>
                  <div className="mb-1 flex items-baseline justify-between gap-token-4">
                    <span className="flex min-w-0 items-center gap-2">
                      <BrandLogo id={c.sourceId} label={c.sourceName} />
                      <span className="truncate text-sm text-content-bright">
                        {c.sourceName} <span className="text-content-dim">×</span> {c.model}
                      </span>
                    </span>
                    <span className="shrink-0 text-sm text-content-mute tabular-nums">
                      {formatCompact(c.requests)} runs
                    </span>
                  </div>
                  <ProportionBar value={stats.comboMax > 0 ? c.tokens / stats.comboMax : 0} />
                </li>
              ))}
            </ul>
          </div>
        )}
      </aside>

      <p className="reveal folio mt-token-12 text-content-dim xl:col-span-2" style={REVEAL.footer}>
        Only what BurnBar really records — fast mode, reasoning mix, and skill
        usage aren&apos;t tracked yet.
        {updatedLabel && <span className="ml-2">Rollup as of {updatedLabel}.</span>}
        {user && (
          <button
            type="button"
            onClick={recompute}
            disabled={rebuilding || pending}
            className="ml-3 text-content-mute underline-offset-4 transition-colors hover:text-content-bright hover:underline disabled:cursor-wait disabled:no-underline disabled:opacity-50"
          >
            {rebuilding ? "Recomputing…" : "Recompute from devices"}
          </button>
        )}
      </p>
    </div>
  );
}
