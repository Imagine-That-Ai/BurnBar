"use client";

/**
 * GitHub-style contribution heatmap of daily token activity.
 *
 * Hand-rolled SVG in the same idiom as the dashboard Sparkline — no chart
 * library. Columns are Sunday-start weeks, rows are Sun→Sat.
 *
 * COLOR: cells paint the DOMINANT provider/model brand hue at sqrt-scaled
 * opacity (daily mode: that day's winner; weekly mode: a weighted-blend
 * gradient kernel across the week's top shares). Empty cells stay
 * `--color-mercury-wash`. Brand colors are identity (providerBrand 1:1 with
 * native) — the grid reads as a usage fingerprint, not a monochrome chart.
 *
 * Modes (the Codex-style Daily / Weekly / Cumulative toggle):
 *   daily      — each cell is that day's tokens.
 *   weekly     — every cell in a column shares the week's total.
 *   cumulative — each cell is the running total up to that day.
 */

import * as React from "react";
import { createPortal } from "react-dom";

import type { DailyPoint } from "@/lib/usage";
import {
  MONTH_NAMES,
  addDays,
  formatDayLabel,
  intensityBucket,
  weekStart,
  weeklyTotals,
} from "@/lib/profile/activityStats";
import {
  blendShareStops,
  dominantShareFill,
  dominantShareKey,
} from "@/lib/profile/profileAggregates";
import { placeTooltip, type TooltipAnchor } from "@/lib/profile/tooltipPlacement";
import { modelDisplayName, providerBarFill, providerDisplayName } from "@/lib/providerBrand";
import { formatCompact } from "@/components/dashboard/cards/primitives";
import { BrandLogo } from "@/components/BrandLogo";

export type HeatmapMode = "daily" | "weekly" | "cumulative";

const CELL = 11;
const GAP = 3;
const STRIDE = CELL + GAP;
const GUTTER = 26;
const TOP = 18;

/** Accent opacity per intensity bucket (1–4). */
const BUCKET_OPACITY = [0, 0.28, 0.48, 0.72, 1] as const;

/** Hovered cell anchor, in viewport coordinates captured at hover time. */
interface Hover {
  day: string;
  anchor: TooltipAnchor;
}

/** Weekday + full date for the hover card ("Mon, Feb 2"). Client-interaction
 *  only, so Intl is safe here (never prerendered). */
function hoverDateLabel(day: string): string {
  const d = new Date(day + "T00:00:00Z");
  if (Number.isNaN(d.getTime())) return day;
  return d.toLocaleDateString("en-US", {
    weekday: "short",
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  });
}

/**
 * Per-day effective split: the provider map WITH entries wins; an empty
 * provider map falls through to the model map (legacy rollups normalize
 * dailyProviderTokens to {}, which must not shadow real model data).
 * Provider facets narrow the provider map to the visible subset first.
 */
function splitForDay(
  day: string,
  dailyProviderTokens: Record<string, Record<string, number>> | undefined,
  dailyModelTokens: Record<string, Record<string, number>> | undefined,
  visibleProviders: readonly string[] | undefined,
): Record<string, number> | undefined {
  const providers = dailyProviderTokens?.[day];
  if (providers && Object.values(providers).some((n) => n > 0)) {
    if (visibleProviders && visibleProviders.length > 0) {
      const wanted = new Set(visibleProviders);
      const narrowed: Record<string, number> = {};
      for (const [key, tokens] of Object.entries(providers)) {
        if (wanted.has(key) && tokens > 0) narrowed[key] = tokens;
      }
      return Object.keys(narrowed).length > 0 ? narrowed : undefined;
    }
    return providers;
  }
  const models = dailyModelTokens?.[day];
  if (models && Object.values(models).some((n) => n > 0)) return models;
  return undefined;
}

/**
 * The day card, portaled to `document.body` with fixed positioning: the grid
 * lives in a horizontal scroll container whose overflow would clip an
 * in-flow card on every side. Measures itself after mount so placement uses
 * the true card size (the provider split changes its height).
 */
function DayCard({
  hover,
  value,
  mode,
  split,
  splitTotal,
  otherSplit,
  modelSplit,
  modelOther,
  modelTotal,
}: {
  hover: Hover;
  value: number;
  mode: HeatmapMode;
  split: [string, number][];
  splitTotal: number;
  otherSplit: number;
  /** Top model shares for the day (model → tokens), when the event path
   *  has a per-model split and the provider split is absent. */
  modelSplit?: [string, number][];
  /** Remainder past the shown models, so percentages always sum to 100. */
  modelOther?: number;
  /** Full model total the percentages divide by (differs from the cell
   *  value under facet filters and the aggregate cap). */
  modelTotal?: number;
}) {
  const ref = React.useRef<HTMLDivElement>(null);
  const [size, setSize] = React.useState({ width: 192, height: 140 });
  React.useLayoutEffect(() => {
    const el = ref.current;
    if (el && (el.offsetWidth !== size.width || el.offsetHeight !== size.height)) {
      setSize({ width: el.offsetWidth, height: el.offsetHeight });
    }
  });
  const placement = placeTooltip(hover.anchor, size, {
    width: window.innerWidth,
    height: window.innerHeight,
  });
  return (
    <div
      ref={ref}
      aria-hidden
      data-placement={placement.above ? "above" : "below"}
      className="glass-pane glass-pane--elevated pointer-events-none fixed z-50 w-48 px-3 py-2"
      style={{ left: placement.left, top: placement.top }}
    >
      <p className="eyebrow">{hoverDateLabel(hover.day)}</p>
      <p className="mt-0.5 font-display text-base leading-tight text-content-bright tabular-nums">
        {value.toLocaleString("en-US")}
        <span className="ml-1 text-xs font-normal text-content-dim">
          {mode === "cumulative"
            ? "total tokens so far"
            : mode === "weekly"
              ? "tokens that week"
              : "tokens"}
        </span>
      </p>
      {split.length > 0 ? (
        <ul className="mt-1.5 space-y-1 border-t border-glass-line pt-1.5">
          {split.map(([provider, tokens]) => (
            <li
              key={provider}
              className="flex items-center gap-1.5 text-xs"
              title={`${tokens.toLocaleString("en-US")} tokens`}
            >
              <BrandLogo id={provider} label={provider} size={14} />
              <span className="truncate text-content-base">{providerDisplayName(provider)}</span>
              <span className="ml-auto shrink-0 text-content-mute tabular-nums">
                {splitTotal > 0 ? Math.round((tokens / splitTotal) * 100) : 0}%
              </span>
            </li>
          ))}
          {otherSplit > 0 && (
            <li className="flex items-center gap-1.5 text-xs text-content-dim">
              <span className="pl-[22px]">other</span>
              <span className="ml-auto tabular-nums">
                {splitTotal > 0 ? Math.round((otherSplit / splitTotal) * 100) : 0}%
              </span>
            </li>
          )}
        </ul>
      ) : (
        modelSplit &&
        modelSplit.length > 0 && (
          <ul className="mt-1.5 space-y-1 border-t border-glass-line pt-1.5">
            {modelSplit.map(([model, tokens]) => (
              <li
                key={model}
                className="flex items-center gap-1.5 text-xs"
                title={`${tokens.toLocaleString("en-US")} tokens`}
              >
                <span className="truncate text-content-base">{modelDisplayName(model)}</span>
                <span className="ml-auto shrink-0 text-content-mute tabular-nums">
                  {modelTotal != null && modelTotal > 0 ? Math.round((tokens / modelTotal) * 100) : 0}%
                </span>
              </li>
            ))}
            {modelOther != null && modelOther > 0 && (
              <li className="flex items-center gap-1.5 text-xs text-content-dim">
                <span className="pl-[22px]">other</span>
                <span className="ml-auto tabular-nums">
                  {modelTotal != null && modelTotal > 0 ? Math.round((modelOther / modelTotal) * 100) : 0}%
                </span>
              </li>
            )}
          </ul>
        )
      )}
    </div>
  );
}

export function ContributionHeatmap({
  points,
  mode,
  today,
  dailyProviderTokens,
  dailyModelTokens,
  dailyModelProviders,
  visibleProviders,
  onSelectDay,
}: {
  points: readonly DailyPoint[];
  mode: HeatmapMode;
  /** Injected "YYYY-MM-DD" so prerender and client agree. */
  today: string;
  /** Sparse per-day provider split (all_time rollup, counter schema v3+).
   *  When present, the day-hover card breaks the day's tokens down by
   *  provider and cells paint the dominant provider hue; absent → the
   *  model split (below) or the accent. Daily mode only. */
  dailyProviderTokens?: Record<string, Record<string, number>>;
  /** Sparse per-day per-model split (event aggregates, client-built).
   *  Powers per-model cell coloring + the hover mix wherever the provider
   *  split is absent. Keys are raw model ids. */
  dailyModelTokens?: Record<string, Record<string, number>>;
  /** Per-day per-model provider attribution ("day" → model → providerID).
   *  Raw model ids don't resolve in the brand table, so model cells look
   *  up the stored provider instead of guessing from the model prefix. */
  dailyModelProviders?: Record<string, Record<string, string>>;
  /** Active provider-facet selection: colors recompute from this subset so
   *  a filtered day wears the filtered winner's hue, not the day's overall
   *  winner. Absent/empty → the full split. */
  visibleProviders?: readonly string[];
  /** Keyboard + click drill-in: called with the day key when an ACTIVE-day
   *  cell is activated. Active days only are focusable (quiet days pin empty
   *  inspectors, and 365 tab stops would be a trap). Absent → mouse-hover
   *  only, exactly the legacy behavior the grid tests pin. */
  onSelectDay?: (day: string) => void;
}) {
  const [hover, setHover] = React.useState<Hover | null>(null);

  // The card is fixed-positioned from the anchor captured at hover time, so
  // any scroll or resize would strand it — dismiss instead of chasing.
  React.useEffect(() => {
    if (!hover) return;
    const clear = () => setHover(null);
    window.addEventListener("scroll", clear, { capture: true, passive: true });
    window.addEventListener("resize", clear);
    return () => {
      window.removeEventListener("scroll", clear, { capture: true });
      window.removeEventListener("resize", clear);
    };
  }, [hover]);

  const { columns, monthLabels, valueOf, labelOf, max, dailyTokens } = React.useMemo(() => {
    // Daily lookup first — every mode derives from it.
    const daily = new Map<string, number>();
    for (const p of points) daily.set(p.day, p.tokens);

    // Grid range: the earliest active day's week through today's week. With no
    // activity, show the trailing year of empty cells (honest zero state).
    // Min over the series, not points[0] — the component doesn't assume the
    // caller sorted.
    const firstDay =
      points.length > 0
        ? points.reduce((min, p) => (p.day < min ? p.day : min), points[0].day)
        : addDays(today, -364);

    // Value lookup per day key, per mode.
    const valueOf = new Map<string, number>();
    const labelOf = new Map<string, string>();
    if (mode === "weekly") {
      for (const w of weeklyTotals(points)) {
        valueOf.set(w.weekStart, w.tokens);
        labelOf.set(
          w.weekStart,
          `Week of ${formatDayLabel(w.weekStart)} — ${formatCompact(w.tokens)} tokens`,
        );
      }
    } else if (mode === "cumulative") {
      // Running total over EVERY day in range, so a quiet day still shows the
      // true total-so-far instead of a misleading zero.
      let acc = 0;
      for (let day = firstDay; day <= today; day = addDays(day, 1)) {
        acc += daily.get(day) ?? 0;
        valueOf.set(day, acc);
        labelOf.set(day, `${formatDayLabel(day)} — ${formatCompact(acc)} total`);
      }
    } else {
      for (const p of points) {
        valueOf.set(p.day, p.tokens);
        labelOf.set(p.day, `${formatDayLabel(p.day)} — ${formatCompact(p.tokens)} tokens`);
      }
    }

    const startWeek = weekStart(firstDay);
    const endWeek = weekStart(today);
    const weekCount =
      Math.round(
        (Date.parse(endWeek + "T00:00:00Z") - Date.parse(startWeek + "T00:00:00Z")) /
          (7 * 86_400_000),
      ) + 1;

    const columns: { day: string; col: number; row: number }[] = [];
    const monthLabels: { x: number; label: string }[] = [];
    let prevMonth = "";
    let lastLabelCol = -3; // w=0 always labels; later labels need 3 columns of room
    let max = 0;

    for (let w = 0; w < weekCount; w++) {
      const ws = addDays(startWeek, w * 7);
      const month = ws.slice(5, 7);
      // Label a month at the first column that starts inside it — unless it
      // would crowd the previous label (GitHub drops crowded labels too).
      if (month !== prevMonth && w - lastLabelCol >= 3) {
        monthLabels.push({ x: GUTTER + w * STRIDE, label: MONTH_NAMES[Number(month) - 1] ?? "" });
        prevMonth = month;
        lastLabelCol = w;
      }
      for (let row = 0; row < 7; row++) {
        const day = addDays(ws, row);
        if (day > today) continue; // no future cells
        if (day < firstDay) continue; // no cells before the account had data
        const v =
          mode === "weekly"
            ? (valueOf.get(weekStart(day)) ?? 0)
            : (valueOf.get(day) ?? 0);
        if (v > max) max = v;
        columns.push({ day, col: w, row });
      }
    }

    return { columns, monthLabels, valueOf, labelOf, max, dailyTokens: daily };
  }, [points, mode, today]);

  const width = GUTTER + (columns.length > 0 ? (columns[columns.length - 1].col + 1) * STRIDE : 0);
  const height = TOP + 7 * STRIDE;

  // Hover-card value, mode-aware (mirrors the cell math).
  const hoverValue = hover
    ? mode === "weekly"
      ? (valueOf.get(weekStart(hover.day)) ?? 0)
      : (valueOf.get(hover.day) ?? 0)
    : 0;
  const hoverSplit =
    hover && mode === "daily" && dailyProviderTokens
      ? Object.entries(dailyProviderTokens[hover.day] ?? {})
          .filter(([, n]) => n > 0)
          .sort((a, b) => b[1] - a[1])
      : [];
  const splitTotal = hoverSplit.reduce((n, [, v]) => n + v, 0);
  const shownSplit = hoverSplit.slice(0, 3);
  const otherSplit = splitTotal - shownSplit.reduce((n, [, v]) => n + v, 0);
  // Model mix for the hover card when the provider split is absent.
  // Shows the top 3 + an `other` remainder so percentages always sum to 100.
  const hoverModelEntries =
    hover && mode === "daily" && hoverSplit.length === 0 && dailyModelTokens
      ? Object.entries(dailyModelTokens[hover.day] ?? {})
          .filter(([, n]) => n > 0)
          .sort((a, b) => b[1] - a[1])
      : [];
  const hoverModelTotal = hoverModelEntries.reduce((n, [, v]) => n + v, 0);
  const hoverModelShown = hoverModelEntries.slice(0, 3);
  const hoverModelSplit: [string, number][] = hoverModelShown;
  const hoverModelOther: number =
    hoverModelTotal - hoverModelShown.reduce((n, [, v]) => n + v, 0);

  // Per-day effective split: the provider map WITH entries wins; an empty
  // provider map falls through to the model map (legacy rollups normalize
  // dailyProviderTokens to {}, which must not shadow real model data).
  // Provider facets narrow the provider map to the visible subset first.
  // (Module-level pure helper `splitForDay` below the card component.)
  const splitForDayHere = (day: string): Record<string, number> | undefined =>
    splitForDay(day, dailyProviderTokens, dailyModelTokens, visibleProviders);

  // Model display color: stored providerID first, raw model id never —
  // raw ids ("gpt-5.3") don't resolve in the brand table and would all
  // collapse to the generic accent.
  const modelColorFor = (day: string) => (model: string): string => {
    const provider = dailyModelProviders?.[day]?.[model];
    return providerBarFill(provider ?? model);
  };

  // Days actually on screen (the sliced point range): weekly blends only
  // aggregate these, so edge weeks never borrow out-of-range usage.
  const visibleDays = React.useMemo(() => new Set(points.map((p) => p.day)), [points]);

  // Weekly-mode blend inputs: per-week merged splits so each column paints
  // its weighted conglomerate kernel. Providers preferred per day, models
  // as fallback — same rule as the daily cells. Only days actually on
  // screen (the sliced point range) contribute, so edge weeks never borrow
  // out-of-range usage. Model-sourced days aggregate under their STORED
  // provider (dailyModelProviders) so gradient stops resolve to real brand
  // hues instead of the generic accent.
  const weeklyBlend = React.useMemo(() => {
    if (mode !== "weekly") return new Map<string, Record<string, number>>();
    const byWeek = new Map<string, Record<string, number>>();
    for (const day of visibleDays) {
      const providers = dailyProviderTokens?.[day];
      const hasProviders =
        providers != null && Object.values(providers).some((n) => n > 0);
      const effective = splitForDay(day, dailyProviderTokens, dailyModelTokens, visibleProviders);
      if (!effective) continue;
      const ws = weekStart(day);
      const acc = byWeek.get(ws) ?? {};
      for (const [key, tokens] of Object.entries(effective)) {
        if (tokens <= 0) continue;
        // Model-sourced days re-key under the stored provider: weeks stay
        // provider-grained (coarse surface, daily keeps model detail).
        const aggregateKey =
          hasProviders
            ? key
            : (dailyModelProviders?.[day]?.[key] ?? key);
        acc[aggregateKey] = (acc[aggregateKey] ?? 0) + tokens;
      }
      byWeek.set(ws, acc);
    }
    return byWeek;
  }, [mode, dailyProviderTokens, dailyModelTokens, dailyModelProviders, visibleDays, visibleProviders]);

  // Paint-server ids per week column (stable across renders for a grid).
  const gradientIdForWeek = (ws: string): string =>
    `profile-week-${ws.replace(/-/g, "")}`;

  // Dominant-share display name for a day's <title> ("Anthropic leads").
  const dominantLabel = (day: string): string => {
    const split = splitForDayHere(day);
    const best = dominantShareKey(split);
    if (!best) return "mix";
    return dailyProviderTokens?.[day]?.[best] != null &&
      Object.values(dailyProviderTokens[day]).some((n) => n > 0)
      ? providerDisplayName(best)
      : modelDisplayName(best);
  };

  // Weekly leader from the WEEKLY aggregate (every row in a column names the
  // same leader; quiet days never print "mix leads" for an active week).
  const weeklyLeaderLabel = (day: string): string | null => {
    const best = dominantShareKey(weeklyBlend.get(weekStart(day)));
    if (!best) return null;
    return /[\s()]/.test(best) || best.includes("/") || best.includes("-")
      ? modelDisplayName(best)
      : providerDisplayName(best);
  };

  return (
    <div className="min-w-0 overflow-x-auto">
      <div className="relative min-w-0" style={{ width }}>
        <svg
          viewBox={`0 0 ${width} ${height}`}
          width={width}
          height={height}
          role="img"
          aria-label="Daily token activity heatmap"
          style={{ display: "block", maxWidth: "100%" }}
          onMouseLeave={() => setHover(null)}
        >
          {/* Weekly paint servers: one <linearGradient> per week column with
              share data, hard stops per band. Inside the SVG so cells can
              reference them via fill="url(#…)". Opacity stays on the cell
              (fillOpacity) so magnitude still encodes through the bucket. */}
          <defs aria-hidden>
            {mode === "weekly" &&
              [...weeklyBlend.entries()].map(([ws, split]) => {
                const stops = blendShareStops(split, (key) => providerBarFill(key));
                if (!stops || stops.length < 2) return null;
                return (
                  <linearGradient
                    key={ws}
                    id={gradientIdForWeek(ws)}
                    x1="0"
                    y1="0"
                    x2="1"
                    y2="1"
                  >
                    {stops.flatMap((s, i) => [
                      <stop
                        key={`${i}-from`}
                        offset={`${(s.from * 100).toFixed(1)}%`}
                        stopColor={s.color}
                      />,
                      <stop
                        key={`${i}-to`}
                        offset={`${(s.to * 100).toFixed(1)}%`}
                        stopColor={s.color}
                      />,
                    ])}
                  </linearGradient>
                );
              })}
          </defs>
          {monthLabels.map((m) => (
            <text
              key={`${m.x}-${m.label}`}
              x={m.x}
              y={10}
              className="fill-[color:var(--color-text-dim)]"
              style={{ fontSize: 9, fontFamily: "var(--font-mono)" }}
            >
              {m.label}
            </text>
          ))}
          {["M", "W", "F"].map((d, i) => (
            <text
              key={d}
              x={0}
              y={TOP + (1 + i * 2) * STRIDE + CELL - 2}
              className="fill-[color:var(--color-text-dim)]"
              style={{ fontSize: 9, fontFamily: "var(--font-mono)" }}
            >
              {d}
            </text>
          ))}
          {columns.map(({ day, col, row }) => {
            const v =
              mode === "weekly" ? (valueOf.get(weekStart(day)) ?? 0) : (valueOf.get(day) ?? 0);
            const bucket = intensityBucket(v, max);
            const label =
              mode === "weekly"
                ? (labelOf.get(weekStart(day)) ??
                  `Week of ${formatDayLabel(weekStart(day))} — 0 tokens`)
                : (labelOf.get(day) ?? `${formatDayLabel(day)} — 0 tokens`);
            const hovered = hover?.day === day;
            // Focusability follows the DAILY series in every mode: the
            // drill-in lands on a real active day, never an aggregate.
            const focusable = onSelectDay != null && (dailyTokens.get(day) ?? 0) > 0;
            // Cell color: the dominant share's brand hue.
            // - daily: that day's winning provider (rollup split), else the
            //   winning model (event split, provider-attributed), else the
            //   accent at bucket steps.
            // - weekly: an SVG paint-server gradient kernel across the week's
            //   top shares (providers preferred, models as fallback).
            // - cumulative: the accent ramp (running totals have no split).
            // Weekly cells keep the BUCKET opacity (magnitude still encodes),
            // so the Less-to-More legend keeps describing weekly mode.
            let paint: string | undefined;
            let paintOpacity: number | undefined;
            if (bucket !== 0 && mode !== "cumulative") {
              if (mode === "weekly") {
                const ws = weekStart(day);
                const stops = blendShareStops(
                  weeklyBlend.get(ws),
                  (key) => providerBarFill(key),
                );
                if (stops && stops.length > 0) {
                  // Single-share weeks are a solid dominant fill; multi-share
                  // weeks get a real <linearGradient> paint server below.
                  if (stops.length === 1) {
                    paint = stops[0].color;
                  } else {
                    paint = `url(#${gradientIdForWeek(ws)})`;
                  }
                  paintOpacity = BUCKET_OPACITY[bucket];
                }
              } else {
                const split = splitForDayHere(day);
                const providerSplit = dailyProviderTokens?.[day];
                const hasProviders =
                  providerSplit != null &&
                  Object.values(providerSplit).some((n) => n > 0);
                const winner = dominantShareFill(
                  split,
                  max,
                  hasProviders
                    ? (key) => providerBarFill(key)
                    : modelColorFor(day),
                );
                if (winner) {
                  paint = winner.fill;
                  paintOpacity = winner.fillOpacity;
                }
              }
            }
            const accentFallback = paint == null;
            return (
              <rect
                key={day}
                x={GUTTER + col * STRIDE}
                y={TOP + row * STRIDE}
                width={CELL}
                height={CELL}
                rx={2.5}
                fill={
                  bucket === 0
                    ? "var(--color-mercury-wash)"
                    : (paint ?? "var(--accent)")
                }
                fillOpacity={
                  bucket === 0 ? 1 : (paintOpacity ?? BUCKET_OPACITY[bucket])
                }
                stroke={hovered ? "var(--accent-deep)" : "transparent"}
                strokeWidth={hovered ? 1.5 : 0}
                aria-label={label}
                role={focusable ? "button" : undefined}
                tabIndex={focusable ? 0 : undefined}
                onKeyDown={
                  focusable
                    ? (e) => {
                        if (e.key === "Enter" || e.key === " ") {
                          e.preventDefault();
                          onSelectDay?.(day);
                        }
                      }
                    : undefined
                }
                onMouseEnter={(e) => {
                  const rect = e.currentTarget.getBoundingClientRect();
                  setHover({
                    day,
                    anchor: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
                  });
                }}
              >
                <title>
                  {accentFallback || bucket === 0
                    ? label
                    : mode === "weekly"
                      ? `${label} — ${weeklyLeaderLabel(day) ?? "mix"} leads`
                      : `${label} — ${dominantLabel(day)} leads`}
                </title>
              </rect>
            );
          })}
        </svg>

        {/* Day card — portaled to the body so the scroll container can never
            clip it, with the per-provider split when the rollup carries it.
            Pointer-events-none so it never eats the next hover. */}
        {hover &&
          createPortal(
            <DayCard
              hover={hover}
              value={hoverValue}
              mode={mode}
              split={shownSplit}
              splitTotal={splitTotal}
              otherSplit={otherSplit}
              modelSplit={hoverModelSplit}
              modelOther={hoverModelOther}
              modelTotal={hoverModelTotal}
            />,
            document.body,
          )}
      </div>
      {/* Scale legend — same five swatches the grid uses, plus the dominant
          brand hues actually present in view. */}
      <div
        className="mt-token-2 flex items-center justify-end gap-1"
        role="img"
        aria-label="Heatmap scale from less to more tokens"
      >
        <span className="mr-1 text-[0.62rem] text-content-dim">Less</span>
        {[0, 1, 2, 3, 4].map((bucket) => (
          <span
            key={bucket}
            aria-hidden
            className="inline-block size-[11px] rounded-[2.5px]"
            style={{
              background:
                bucket === 0 ? "var(--color-mercury-wash)" : "var(--accent)",
              opacity: bucket === 0 ? 1 : BUCKET_OPACITY[bucket],
            }}
          />
        ))}
        <span className="ml-1 text-[0.62rem] text-content-dim">More</span>
      </div>
    </div>
  );
}
