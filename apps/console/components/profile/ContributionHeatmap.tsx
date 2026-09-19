"use client";

/**
 * GitHub-style contribution heatmap of daily token activity.
 *
 * Hand-rolled SVG in the same idiom as the dashboard Sparkline — no chart
 * library. Columns are Sunday-start weeks, rows are Sun→Sat. Colors come from
 * theme tokens only: empty cells are `--color-mercury-wash`, active cells are
 * `--accent` at four sqrt-scaled opacity steps (see intensityBucket).
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
import { placeTooltip, type TooltipAnchor } from "@/lib/profile/tooltipPlacement";
import { providerDisplayName } from "@/lib/providerBrand";
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
}: {
  hover: Hover;
  value: number;
  mode: HeatmapMode;
  split: [string, number][];
  splitTotal: number;
  otherSplit: number;
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
      {split.length > 0 && (
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
      )}
    </div>
  );
}

export function ContributionHeatmap({
  points,
  mode,
  today,
  dailyProviderTokens,
  onSelectDay,
}: {
  points: readonly DailyPoint[];
  mode: HeatmapMode;
  /** Injected "YYYY-MM-DD" so prerender and client agree. */
  today: string;
  /** Sparse per-day provider split (all_time rollup, counter schema v3+).
   *  When present, the day-hover card breaks the day's tokens down by
   *  provider; absent → the card shows tokens only. Daily mode only. */
  dailyProviderTokens?: Record<string, Record<string, number>>;
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

  return (
    <div className="overflow-x-auto">
      <div className="relative" style={{ width }}>
        <svg
          viewBox={`0 0 ${width} ${height}`}
          width={width}
          height={height}
          role="img"
          aria-label="Daily token activity heatmap"
          style={{ display: "block", maxWidth: "none" }}
          onMouseLeave={() => setHover(null)}
        >
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
            return (
              <rect
                key={day}
                x={GUTTER + col * STRIDE}
                y={TOP + row * STRIDE}
                width={CELL}
                height={CELL}
                rx={2.5}
                fill={bucket === 0 ? "var(--color-mercury-wash)" : "var(--accent)"}
                fillOpacity={bucket === 0 ? 1 : BUCKET_OPACITY[bucket]}
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
                <title>{label}</title>
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
            />,
            document.body,
          )}
      </div>
      {/* Scale legend — same five swatches the grid uses. */}
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
