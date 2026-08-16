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

export type HeatmapMode = "daily" | "weekly" | "cumulative";

const CELL = 11;
const GAP = 3;
const STRIDE = CELL + GAP;
const GUTTER = 26;
const TOP = 18;

/** Accent opacity per intensity bucket (1–4). */
const BUCKET_OPACITY = [0, 0.28, 0.48, 0.72, 1] as const;

export function ContributionHeatmap({
  points,
  mode,
  today,
}: {
  points: readonly DailyPoint[];
  mode: HeatmapMode;
  /** Injected "YYYY-MM-DD" so prerender and client agree. */
  today: string;
}) {
  const { columns, monthLabels, valueOf, labelOf, max } = React.useMemo(() => {
    // Daily lookup first — every mode derives from it.
    const daily = new Map<string, number>();
    for (const p of points) daily.set(p.day, p.tokens);

    // Grid range: the first active day's week through today's week. With no
    // activity, show the trailing year of empty cells (honest zero state).
    const firstDay = points.length > 0 ? points[0].day : addDays(today, -364);

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
    let max = 0;

    for (let w = 0; w < weekCount; w++) {
      const ws = addDays(startWeek, w * 7);
      const month = ws.slice(5, 7);
      // Label a month at the first column that starts inside it.
      if (month !== prevMonth && (w === 0 || ws.slice(0, 7) !== addDays(ws, -7).slice(0, 7))) {
        monthLabels.push({ x: GUTTER + w * STRIDE, label: MONTH_NAMES[Number(month) - 1] ?? "" });
        prevMonth = month;
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

  return (
    <div className="overflow-x-auto">
      <svg
        viewBox={`0 0 ${width} ${height}`}
        width={width}
        height={height}
        role="img"
        aria-label="Daily token activity heatmap"
        style={{ display: "block", maxWidth: "none" }}
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
              aria-label={label}
            >
              <title>{label}</title>
            </rect>
          );
        })}
      </svg>
    </div>
  );
}
