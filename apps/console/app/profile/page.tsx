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
  formatUsd,
} from "@/components/dashboard/cards/primitives";
import { RefreshCw } from "lucide-react";
import { BrandLogo } from "@/components/BrandLogo";
import { cn } from "@/lib/utils";

const HEATMAP_MODES: { key: HeatmapMode; label: string }[] = [
  { key: "daily", label: "Daily" },
  { key: "weekly", label: "Weekly" },
  { key: "cumulative", label: "Cumulative" },
];

/** The rail's breakdown metric — Tokens / Runs / Spend, all from the rollup. */
type Metric = "tokens" | "runs" | "spend";
const METRICS: { key: Metric; label: string }[] = [
  { key: "tokens", label: "Tokens" },
  { key: "runs", label: "Runs" },
  { key: "spend", label: "Spend" },
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

/** Accent-fill opacity steps for the provider-mix bar — one hue, quiet ramp. */
const MIX_OPACITY = [1, 0.66, 0.46, 0.32, 0.22] as const;

/**
 * Honest empty state: the SHAPE of what's coming (logo tile + share bar),
 * dimmed — a preview of the layout, never invented numbers.
 */
function GhostRows({ rows = 3 }: { rows?: number }) {
  return (
    <div aria-hidden className="space-y-token-3 opacity-40">
      {Array.from({ length: rows }, (_, i) => (
        <div key={i} className="flex items-center gap-2">
          <span className="size-[18px] shrink-0 rounded-[5px] border border-glass-line bg-mercury-wash" />
          <span
            className="h-1.5 rounded-pill bg-mercury-wash"
            style={{ width: `${86 - i * 18}%` }}
          />
        </div>
      ))}
    </div>
  );
}

/** Segmented pill toggle — same idiom as the heatmap's mode switch. */
function MetricToggle({
  metric,
  onChange,
}: {
  metric: Metric;
  onChange: (m: Metric) => void;
}) {
  return (
    <div
      role="group"
      aria-label="Breakdown metric"
      className="flex items-center gap-token-1 rounded-pill border border-glass-line p-0.5"
    >
      {METRICS.map((m) => (
        <button
          key={m.key}
          type="button"
          aria-pressed={metric === m.key}
          onClick={() => onChange(m.key)}
          className={cn(
            "rounded-pill px-token-2 py-0.5 text-[0.68rem] transition-colors duration-150",
            metric === m.key ? "text-content-bright" : "text-content-dim hover:text-content-mute",
          )}
          style={metric === m.key ? { background: "var(--accent-wash)" } : undefined}
        >
          {m.label}
        </button>
      ))}
    </div>
  );
}

export default function ProfilePage() {
  const { user } = useAuth();
  const { rollup, source, loading, syncing, error, reload } = useProfileUsage();
  const [mode, setMode] = React.useState<HeatmapMode>("daily");
  const [metric, setMetric] = React.useState<Metric>("tokens");
  // If the IdP avatar fails to load (expired URL, CSP, offline), fall back to
  // the initial tile instead of a broken image.
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
    // Full lists, deliberately unsliced: "top five" depends on the ACTIVE metric,
    // and the normalizer's fixed order (providers/models by cost, harnesses/combos
    // by tokens) is only correct for one of the three toggles. Ranking happens in
    // the metric-aware `rail` memo below.
    const allProviders = rollup.providerSummaries;
    const allModels = rollup.modelSummaries;
    const allHarnesses = rollup.executionSourceSummaries;
    const allCombos = rollup.comboSummaries;
    // Trend: the trailing 90 days inclusive of today.
    const cutoff = addDays(today, -89);
    const trend = points.filter((p) => p.day >= cutoff);
    return {
      streaks,
      peak,
      activeDays,
      totalTokens,
      avgPerActiveDay: activeDays > 0 ? Math.round(totalTokens / activeDays) : 0,
      allProviders,
      allModels,
      allHarnesses,
      allCombos,
      trend,
    };
  }, [rollup, today]);

  const displayName = user?.displayName || user?.email?.split("@")[0] || "Member";
  const handle = user?.email ? `@${user.email.split("@")[0]}` : null;

  // Metric-aware accessors for the rail's breakdown sections (Tokens / Runs /
  // Spend) — every summary carries all three, so the toggle is pure render.
  const rail = React.useMemo(() => {
    if (!stats) return null;
    const pv = (p: (typeof stats.allProviders)[number]) =>
      metric === "tokens" ? p.totalTokens : metric === "runs" ? p.totalRequests : p.totalCost;
    const mv = (m: (typeof stats.allModels)[number]) =>
      metric === "tokens" ? m.tokens : metric === "runs" ? m.requests : m.cost;
    const hv = (h: (typeof stats.allHarnesses)[number]) =>
      metric === "tokens" ? h.totalTokens : metric === "runs" ? h.totalRequests : h.totalCost;
    const cv = (c: (typeof stats.allCombos)[number]) =>
      metric === "tokens" ? c.tokens : metric === "runs" ? c.requests : c.cost;
    // Rank by the metric the user is actually looking at, THEN take five.
    const byDesc = <T,>(items: readonly T[], value: (item: T) => number): T[] =>
      [...items].sort((a, b) => value(b) - value(a));
    const topProviders = byDesc(stats.allProviders, pv).slice(0, 5);
    const topModels = byDesc(stats.allModels, mv).slice(0, 5);
    const topHarnesses = byDesc(stats.allHarnesses, hv).slice(0, 5);
    const topCombos = byDesc(stats.allCombos, cv).slice(0, 5);

    // The denominator counts EVERY provider, so with more than five the rendered
    // segments would sum to under 100% and the remainder would read as
    // unexplained blank space. Carry the omitted aggregate so the bar and the
    // legend can both account for it.
    const providerTotal = stats.allProviders.reduce((n, p) => n + pv(p), 0);
    const shownProviderTotal = topProviders.reduce((n, p) => n + pv(p), 0);
    return {
      pv,
      mv,
      hv,
      cv,
      topProviders,
      topModels,
      topHarnesses,
      topCombos,
      providerTotal,
      otherProviderValue: Math.max(0, providerTotal - shownProviderTotal),
      modelMax: topModels.length ? Math.max(...topModels.map(mv)) : 0,
      harnessMax: topHarnesses.length ? Math.max(...topHarnesses.map(hv)) : 0,
      comboMax: topCombos.length ? Math.max(...topCombos.map(cv)) : 0,
    };
  }, [stats, metric]);

  /** Value + unit under the active metric ("211 runs" / "5.2M tok" / "$12.40"). */
  const fmtMetric = (v: number): string =>
    metric === "spend" ? formatUsd(v) : `${formatCompact(v)}${metric === "runs" ? " runs" : " tok"}`;
  const joinedDays =
    today && user?.metadata.creationTime ? daysSince(user.metadata.creationTime, today) : null;
  const initial = displayName.trim().charAt(0).toUpperCase() || "B";

  // Numbers stay as quiet dashes until the rollup has actually landed — a
  // flash of zeros reads as "you have no usage", which is a lie while loading.
  const pending = loading || !today;
  const num = (v: number) => (pending ? "—" : formatCompact(v));

  return (
    <div className="mx-auto max-w-3xl xl:mx-0 xl:grid xl:max-w-none xl:grid-cols-[minmax(0,42rem)_minmax(15rem,19rem)] xl:gap-token-12">
      <div className="min-w-0">
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
        <div className="flex items-center gap-3 mt-1">
          {joinedDays != null && (
            <span className="folio text-content-dim">Joined {joinedDays} days ago</span>
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
          className="mt-token-6 text-sm text-center"
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
        <div className="mt-token-6 rounded-lg border border-glass-line bg-surface p-token-4 text-center text-sm text-content-mute">
          <p className="text-content-bright font-medium mb-1">No usage synced to cloud yet</p>
          <p className="text-xs text-content-dim mb-3">
            Open the BurnBar Mac app popover and click the <strong className="text-content-bright">🔄 Refresh</strong> icon at the top right to upload your local sessions.
          </p>
          <button
            type="button"
            onClick={() => reload(true)}
            className="inline-flex items-center gap-1.5 rounded-md bg-[color:var(--accent-wash)] px-3 py-1.5 text-xs font-semibold text-[color:var(--accent-deep)] transition hover:opacity-90"
          >
            <RefreshCw className="size-3" />
            Check & Re-sync Now
          </button>
        </div>
      )}

      {/* Lifetime stat row — a divided bar on sm+, individual tiles on mobile. */}
      <section
        aria-label="Lifetime statistics"
        className="reveal mt-token-8 grid grid-cols-2 gap-2 sm:grid-cols-5 sm:gap-0 sm:divide-x sm:divide-glass-line sm:rounded-lg sm:border sm:border-glass-line"
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
          <ContributionHeatmap
            points={rollup.dailyPoints}
            mode={mode}
            today={today}
            dailyProviderTokens={rollup.dailyProviderTokens}
          />
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
          The harness and combo blocks only appear from md up (they are the
          "when there is space" detail) and only once the rollup actually
          carries execution-source data. */}
      <aside
        aria-label="Activity insights"
        className="reveal mt-token-12 grid content-start gap-token-8 sm:grid-cols-2 xl:mt-0 xl:grid-cols-1"
        style={REVEAL.insights}
      >
        <div className="flex items-center justify-between">
          <span className="eyebrow">Break down by</span>
          <MetricToggle metric={metric} onChange={setMetric} />
        </div>

        {/* Provider mix — the graphic anchor of the rail: one accent-led share
            bar, then legend rows carried by the providers' own brand marks. */}
        <div>
          <h2 className="eyebrow mb-token-3">Provider mix</h2>
          {!pending && stats && rail && rail.topProviders.length > 0 && rail.providerTotal > 0 ? (
            <>
              <div
                role="img"
                aria-label={[
                  ...rail.topProviders.map(
                    (p) => `${p.provider} ${Math.round((rail.pv(p) / rail.providerTotal) * 100)}%`,
                  ),
                  ...(rail.otherProviderValue > 0
                    ? [`Other ${Math.round((rail.otherProviderValue / rail.providerTotal) * 100)}%`]
                    : []),
                ].join(", ")}
                className="flex h-2 gap-px overflow-hidden rounded-pill"
              >
                {rail.topProviders.map((p, i) => (
                  <span
                    key={p.provider}
                    className="h-full"
                    style={{
                      width: `${(rail.pv(p) / rail.providerTotal) * 100}%`,
                      background: "var(--accent)",
                      opacity: MIX_OPACITY[i] ?? MIX_OPACITY[MIX_OPACITY.length - 1],
                    }}
                  />
                ))}
                {rail.otherProviderValue > 0 ? (
                  <span
                    key="__other"
                    className="h-full"
                    style={{
                      width: `${(rail.otherProviderValue / rail.providerTotal) * 100}%`,
                      background: "var(--content-dim)",
                      opacity: 0.35,
                    }}
                  />
                ) : null}
              </div>
              <ul className="mt-token-3 space-y-token-2">
                {rail.topProviders.map((p) => (
                  <li key={p.provider} className="flex items-center gap-2 text-sm">
                    <BrandLogo id={p.provider} label={p.provider} size={18} />
                    <span className="truncate text-content-bright">{p.provider}</span>
                    <span className="ml-auto shrink-0 text-content-mute tabular-nums">
                      {fmtMetric(rail.pv(p))}
                    </span>
                  </li>
                ))}
                {rail.otherProviderValue > 0 ? (
                  <li className="flex items-center gap-2 text-sm">
                    <span
                      aria-hidden
                      className="h-[18px] w-[18px] rounded-pill"
                      style={{ background: "var(--content-dim)", opacity: 0.35 }}
                    />
                    <span className="truncate text-content-mute">Other</span>
                    <span className="ml-auto shrink-0 text-content-mute tabular-nums">
                      {fmtMetric(rail.otherProviderValue)}
                    </span>
                  </li>
                ) : null}
              </ul>
            </>
          ) : (
            <>
              <div aria-hidden className="h-2 rounded-pill bg-mercury-wash opacity-40" />
              <div className="mt-token-3">
                <GhostRows rows={3} />
              </div>
              {!pending && (
                <p className="mt-token-3 text-sm text-content-dim">
                  Your provider mix lands here after the first synced runs.
                </p>
              )}
            </>
          )}
        </div>

        <div>
          <h2 className="eyebrow mb-token-3">Activity insights</h2>
          <div className="divide-y divide-glass-line border-y border-glass-line">
            <InsightRow label="Active days" value={pending ? "—" : (stats?.activeDays ?? 0)} />
            <InsightRow label="Avg tokens per active day" value={num(stats?.avgPerActiveDay ?? 0)} />
            <InsightRow
              label="Most used model"
              value={
                !pending && rail?.topModels[0] ? (
                  <span className="inline-flex items-center gap-2">
                    <BrandLogo
                      id={rail.topModels[0].provider}
                      label={rail.topModels[0].provider}
                      size={18}
                    />
                    {rail.topModels[0].model}
                  </span>
                ) : (
                  "—"
                )
              }
            />
            <InsightRow
              label="Lifetime spend"
              value={pending ? "—" : `$${rollup.totals.costUsd.toFixed(2)}`}
            />
          </div>
        </div>

        <div>
          <h2 className="eyebrow mb-token-3">Most used models</h2>
          {!pending && stats && rail && rail.topModels.length > 0 ? (
            <ul className="space-y-token-3">
              {rail.topModels.map((m) => (
                <li key={`${m.provider}/${m.model}`}>
                  <div className="mb-1 flex items-baseline justify-between gap-token-4">
                    <span className="flex min-w-0 items-center gap-2">
                      <BrandLogo id={m.provider} label={m.provider} size={18} />
                      <span className="truncate text-sm text-content-bright">{m.model}</span>
                    </span>
                    <span className="shrink-0 text-sm text-content-mute tabular-nums">
                      {fmtMetric(rail.mv(m))}
                    </span>
                  </div>
                  <ProportionBar value={rail.modelMax > 0 ? rail.mv(m) / rail.modelMax : 0} />
                </li>
              ))}
            </ul>
          ) : (
            <>
              <GhostRows rows={4} />
              {!pending && (
                <p className="mt-token-3 text-sm text-content-dim">Nothing in this window yet.</p>
              )}
            </>
          )}
        </div>

        {!pending && stats && rail && rail.topHarnesses.length > 0 && (
          <div className="hidden md:block">
            <h2 className="eyebrow mb-token-3">Agent harnesses</h2>
            <ul className="space-y-token-3">
              {rail.topHarnesses.map((h) => (
                <li key={h.sourceId}>
                  <div className="mb-1 flex items-baseline justify-between gap-token-4">
                    <span className="flex min-w-0 items-center gap-2">
                      <BrandLogo id={h.sourceId} label={h.sourceName} />
                      <span className="truncate text-sm text-content-bright">{h.sourceName}</span>
                    </span>
                    <span className="shrink-0 text-sm text-content-mute tabular-nums">
                      {fmtMetric(rail.hv(h))}
                    </span>
                  </div>
                  <ProportionBar value={rail.harnessMax > 0 ? rail.hv(h) / rail.harnessMax : 0} />
                </li>
              ))}
            </ul>
          </div>
        )}

        {!pending && stats && rail && rail.topCombos.length > 0 && (
          <div className="hidden md:block">
            <h2 className="eyebrow mb-token-3">Combos</h2>
            <ul className="space-y-token-3">
              {rail.topCombos.map((c) => (
                <li key={`${c.sourceId}/${c.provider}/${c.model}`}>
                  <div className="mb-1 flex items-baseline justify-between gap-token-4">
                    <span className="flex min-w-0 items-center gap-2">
                      <BrandLogo id={c.sourceId} label={c.sourceName} />
                      <span className="truncate text-sm text-content-bright">
                        {c.sourceName} <span className="text-content-dim">×</span> {c.model}
                      </span>
                    </span>
                    <span className="shrink-0 text-sm text-content-mute tabular-nums">
                      {fmtMetric(rail.cv(c))}
                    </span>
                  </div>
                  <ProportionBar value={rail.comboMax > 0 ? rail.cv(c) / rail.comboMax : 0} />
                </li>
              ))}
            </ul>
          </div>
        )}
      </aside>

      <p className="reveal folio mt-token-12 text-center text-content-dim xl:col-span-2" style={REVEAL.footer}>
        Only what BurnBar really records — fast mode, reasoning mix, and skill
        usage aren&apos;t tracked yet.
      </p>
    </div>
  );
}
