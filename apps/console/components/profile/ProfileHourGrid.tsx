"use client";

/**
 * Hour × weekday grid for the active range — when the explorer burns, by hour
 * of day (UTC) and weekday. Built from bounded event aggregates (Mac Charts
 * already does this locally); the rollup has no hour data.
 *
 * Intensity uses the same sqrt scale as the heatmap so one monster cell does
 * not flatten the rest. Cells are buttons: clicking a cell with activity pins
 * that weekday+hour as an event-path filter hint (reported as a day pin on
 * the most active day of that weekday — the honest client-side resolution
 * without a server hour field).
 */

import * as React from "react";

import { intensityBucket } from "@/lib/profile/activityStats";
import type { HourWeekdayGrid } from "@/lib/profile/profileAggregates";
import { cn } from "@/lib/utils";
import { formatCompact } from "@/components/dashboard/cards/primitives";

const ROWS: { weekday: number; label: string }[] = [
  { weekday: 1, label: "Mon" },
  { weekday: 2, label: "Tue" },
  { weekday: 3, label: "Wed" },
  { weekday: 4, label: "Thu" },
  { weekday: 5, label: "Fri" },
  { weekday: 6, label: "Sat" },
  { weekday: 0, label: "Sun" },
];

const BUCKET_OPACITY = [0, 0.28, 0.48, 0.72, 1] as const;

export function ProfileHourGrid({
  grid,
  loading,
  error,
  capped,
  eventCount,
  onPickCell,
}: {
  grid: HourWeekdayGrid | null;
  loading: boolean;
  error: string | null;
  capped: boolean;
  eventCount: number;
  onPickCell: (weekday: number, hour: number) => void;
}) {
  const hours = React.useMemo(() => Array.from({ length: 24 }, (_, h) => h), []);
  return (
    <section aria-label="Burn by hour">
      <div className="mb-token-1 flex items-baseline justify-between gap-token-4">
        <h2 className="eyebrow">Burn by hour</h2>
        <span className="text-xs text-content-dim">
          {loading
            ? "reading events…"
            : error
              ? "event read failed"
              : grid
                ? `${eventCount} events · UTC`
                : "needs a bounded range"}
        </span>
      </div>
      {error ? (
        <p className="rounded-lg border border-glass-line px-token-3 py-token-4 text-sm text-content-dim">
          Could not read usage events ({error}). The scoreboard above still stands.
        </p>
      ) : !grid ? (
        <p className="rounded-lg border border-glass-line px-token-3 py-token-4 text-sm text-content-dim">
          Pick a 7/30/90-day window (or a custom range) to light up the hour grid.
        </p>
      ) : (
        <>
          {/* Summary for assistive tech lives here, outside the interactive
              grid — wrapping buttons in role="img" would flatten their
              semantics to presentational. */}
          <p className="sr-only">
            {`Tokens by weekday and hour of day, UTC. Peak cell holds ${formatCompact(grid.maxTokens)} tokens.`}
          </p>
          <div
            className="grid gap-[3px]"
            style={{ gridTemplateColumns: "2rem repeat(24, minmax(0, 1fr))" }}
          >
            <span aria-hidden />
            {hours.map((h) => (
              <span
                key={h}
                aria-hidden
                className="text-center font-mono text-[0.55rem] text-content-dim"
              >
                {h % 6 === 0 ? `${h}h` : ""}
              </span>
            ))}
            {ROWS.map(({ weekday, label }) => (
              <React.Fragment key={weekday}>
                <span className="self-center font-mono text-[0.6rem] text-content-mute">
                  {label}
                </span>
                {hours.map((hour) => {
                  const cell = grid.cells[weekday * 24 + hour] ?? {
                    weekday,
                    hour,
                    events: 0,
                    tokens: 0,
                  };
                  const bucket = intensityBucket(cell.tokens, grid.maxTokens);
                  const active = cell.tokens > 0;
                  return (
                    <button
                      key={hour}
                      type="button"
                      disabled={!active}
                      onClick={() => onPickCell(weekday, hour)}
                      title={`${label} ${hour}:00 UTC — ${formatCompact(cell.tokens)} tokens · ${cell.events} runs`}
                      aria-label={`${label} ${hour}:00 UTC, ${formatCompact(cell.tokens)} tokens in ${cell.events} runs`}
                      className={cn(
                        "h-4 w-full rounded-[3px]",
                        active && "hover:ring-1 hover:ring-[color:var(--accent-deep)]",
                      )}
                      style={{
                        background:
                          bucket === 0 ? "var(--color-mercury-wash)" : "var(--accent)",
                        opacity: bucket === 0 ? 1 : BUCKET_OPACITY[bucket],
                        cursor: active ? "pointer" : "default",
                      }}
                    />
                  );
                })}
              </React.Fragment>
            ))}
          </div>
          {capped && (
            <p className="mt-token-2 text-xs text-content-dim">
              Capped at 2,000 events — narrow the range for the full picture.
            </p>
          )}
        </>
      )}
    </section>
  );
}
