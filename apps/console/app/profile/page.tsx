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

function HeaderStat({
  value,
  label,
  sub,
}: {
  value: React.ReactNode;
  label: string;
  sub?: React.ReactNode;
}) {
  return (
    <div className="flex flex-col items-center gap-1 px-token-4 py-token-5 text-center">
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
  const { rollup, source, loading, error } = useProfileUsage();
  const [mode, setMode] = React.useState<HeatmapMode>("daily");

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
    // Trend: trailing 90 days of the daily series.
    const cutoff = addDays(today, -90);
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
      trend,
    };
  }, [rollup, today]);

  const displayName = user?.displayName || user?.email?.split("@")[0] || "Member";
  const handle = user?.email ? `@${user.email.split("@")[0]}` : null;
  const joinedDays =
    today && user?.metadata.creationTime ? daysSince(user.metadata.creationTime, today) : null;
  const initial = displayName.trim().charAt(0).toUpperCase() || "B";

  return (
    <div className="mx-auto max-w-3xl">
      {/* Identity header */}
      <header className="flex flex-col items-center gap-token-3 text-center">
        {user?.photoURL ? (
          <img
            src={user.photoURL}
            alt=""
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
        {joinedDays != null && (
          <span className="folio text-content-dim">Joined {joinedDays} days ago</span>
        )}
      </header>

      {error && (
        <div role="alert" className="mt-token-6 text-sm" style={{ color: "var(--color-seal-crimson)" }}>
          {error}
        </div>
      )}
      {!error && !loading && source === "empty" && (
        <p className="mt-token-6 text-center text-sm text-content-mute">
          No usage has synced from your devices yet — this page fills in as the
          BurnBar app reports usage to your account.
        </p>
      )}

      {/* Lifetime stat row */}
      <section
        aria-label="Lifetime statistics"
        className="mt-token-8 grid grid-cols-2 divide-glass-line rounded-lg border border-glass-line sm:grid-cols-5 sm:divide-x"
      >
        <HeaderStat value={formatCompact(rollup.totals.tokens)} label="Lifetime tokens" />
        <HeaderStat
          value={formatCompact(stats?.peak?.tokens ?? 0)}
          label="Peak tokens"
          sub={stats?.peak ? formatDayLabel(stats.peak.day) : undefined}
        />
        <HeaderStat value={formatCompact(rollup.totals.requests)} label="Total requests" />
        <HeaderStat
          value={`${stats?.streaks.current ?? 0}d`}
          label="Current streak"
        />
        <HeaderStat value={`${stats?.streaks.longest ?? 0}d`} label="Longest streak" />
      </section>

      {/* Token activity heatmap */}
      <section aria-label="Token activity" className="mt-token-10">
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
      <section aria-label="Token trend" className="mt-token-10">
        <h2 className="eyebrow mb-token-1">Tokens</h2>
        <p className="font-display text-2xl text-content-bright tabular-nums">
          {formatCompact(sumTokens(stats?.trend ?? []))} tokens
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

      {/* Insights */}
      <section
        aria-label="Activity insights"
        className="mt-token-10 grid gap-token-8 sm:grid-cols-2"
      >
        <div>
          <h2 className="eyebrow mb-token-3">Activity insights</h2>
          <div className="divide-y divide-glass-line border-y border-glass-line">
            <InsightRow label="Active days" value={stats?.activeDays ?? 0} />
            <InsightRow
              label="Avg tokens per active day"
              value={formatCompact(stats?.avgPerActiveDay ?? 0)}
            />
            <InsightRow
              label="Most used provider"
              value={
                stats?.topProvider
                  ? `${stats.topProvider.provider} · ${Math.round(stats.topProviderShare * 100)}%`
                  : "—"
              }
            />
            <InsightRow
              label="Most used model"
              value={stats?.topModels[0]?.model ?? "—"}
            />
            <InsightRow
              label="Lifetime spend"
              value={`$${rollup.totals.costUsd.toFixed(2)}`}
            />
          </div>
        </div>
        <div>
          <h2 className="eyebrow mb-token-3">Most used models</h2>
          {stats && stats.topModels.length > 0 ? (
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
      </section>

      <p className="folio mt-token-10 text-center text-content-dim">
        Only what BurnBar really records — fast mode, reasoning mix, and skill
        usage aren&apos;t tracked yet.
      </p>
    </div>
  );
}
