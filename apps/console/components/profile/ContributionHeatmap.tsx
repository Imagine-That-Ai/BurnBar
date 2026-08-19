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

import type { DailyPoint } from "@/lib/usage";
import {
  MONTH_NAMES,
  addDays,
  formatDayLabel,
  intensityBucket,
  weekStart,
  weeklyTotals,
} from "@/lib/profile/activityStats";
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

/** Hovered cell anchor, in SVG pixel space (scrolls with the grid). */
interface Hover {
  day: string;
  x: number; // cell center
  y: number; // cell top
  row: number;
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

export function ContributionHeatmap({
  points,
  mode,
  today,
  dailyProviderTokens,
}: {
  points: readonly DailyPoint[];
  mode: HeatmapMode;
  /** Injected "YYYY-MM-DD" so prerender and client agree. */
  today: string;
  /** Sparse per-day provider split (all_time rollup, counter schema v3+).
   *  When present, the day-hover card breaks the day's tokens down by
   *  provider; absent → the card shows tokens only. Daily mode only. */
  dailyProviderTokens?: Record<string, Record<string, number>>;
}) {
  const [hover, setHover] = React.useState<Hover | null>(null);
  const { columns, monthLabels, valueOf, labelOf, max } = React.useMemo(() => {
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

    return { columns, monthLabels, valueOf, labelOf, max };
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
                onMouseEnter={() =>
                  setHover({ day, x: GUTTER + col * STRIDE + CELL / 2, y: TOP + row * STRIDE, row })
                }
              >
                <title>{label}</title>
              </rect>
            );
          })}
        </svg>

        {/* Day card — floats beside the hovered cell (above it, flipping below
            on the top rows), with the per-provider split when the rollup
            carries it. Pointer-events-none so it never eats the next hover. */}
        {hover && (
          <div
            aria-hidden
            className="glass-pane glass-pane--elevated pointer-events-none absolute z-10 w-44 px-3 py-2"
            style={{
              left: Math.min(Math.max(hover.x, 92), width - 92),
              top: hover.row >= 2 ? hover.y - 8 : hover.y + CELL + 8,
              transform:
                hover.row >= 2 ? "translate(-50%, -100%)" : "translate(-50%, 0)",
            }}
          >
            <p className="eyebrow">{hoverDateLabel(hover.day)}</p>
            <p className="mt-0.5 font-display text-base leading-tight text-content-bright tabular-nums">
              {hoverValue.toLocaleString("en-US")}
              <span className="ml-1 text-xs font-normal text-content-dim">
                {mode === "cumulative"
                  ? "total tokens so far"
                  : mode === "weekly"
                    ? "tokens that week"
                    : "tokens"}
              </span>
            </p>
            {shownSplit.length > 0 && (
              <ul className="mt-1.5 space-y-1 border-t border-glass-line pt-1.5">
                {shownSplit.map(([provider, tokens]) => (
                  <li key={provider} className="flex items-center gap-1.5 text-xs">
                    <BrandLogo id={provider} label={provider} size={14} />
                    <span className="truncate text-content-base">{provider}</span>
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
