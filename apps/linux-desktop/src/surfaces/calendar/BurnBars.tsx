import { normalizeValues } from '../insights/insightsChartMath.js';
import { formatCostUsd, type DailyBurnBucket } from './calendarMath.js';

/**
 * Per-day cost bars across the selection span (ChartKitBars parity). Gap-
 * filled buckets render as zero-height bars so silent days stay visible.
 */
const WIDTH = 480;
const HEIGHT = 150;
const PAD_BOTTOM = 20;
const PAD_TOP = 8;
const PLOT_H = HEIGHT - PAD_TOP - PAD_BOTTOM;

export function BurnBars({ buckets, accent }: { buckets: DailyBurnBucket[]; accent: string }) {
  const values = buckets.map((b) => b.costUsd);
  const norm = normalizeValues(values);
  const max = Math.max(...values, 0);
  const barWidth = buckets.length > 0 ? WIDTH / buckets.length : WIDTH;
  const total = values.reduce((s, v) => s + v, 0);
  const ariaLabel =
    buckets.length === 0
      ? 'No days selected.'
      : `Per-day cost over ${buckets.length} days, totalling ${formatCostUsd(total)}, peak day ${formatCostUsd(max)}.`;

  return (
    <figure className="calendar-burn">
      <svg
        className="calendar-burn-svg"
        width="100%"
        height={HEIGHT}
        viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
        role="img"
        aria-label={ariaLabel}
        preserveAspectRatio="none"
      >
        {buckets.map((bucket, i) => {
          const t = norm[i] ?? 0;
          const h = bucket.costUsd > 0 ? Math.max(2, t * PLOT_H) : 0;
          return (
            <rect
              key={bucket.day}
              x={(i * barWidth + 1).toFixed(1)}
              y={(PAD_TOP + PLOT_H - h).toFixed(1)}
              width={Math.max(1, barWidth - 2).toFixed(1)}
              height={h.toFixed(1)}
              rx={1.5}
              fill={accent}
              opacity={bucket.costUsd > 0 ? 0.45 + 0.55 * t : 0}
            />
          );
        })}
        <line
          x1={0}
          y1={PAD_TOP + PLOT_H + 0.5}
          x2={WIDTH}
          y2={PAD_TOP + PLOT_H + 0.5}
          className="calendar-burn-baseline"
        />
        {buckets.length > 1 ? (
          <>
            <text x={0} y={HEIGHT - 4} textAnchor="start" className="calendar-burn-axis">
              {buckets[0]!.label}
            </text>
            <text x={WIDTH} y={HEIGHT - 4} textAnchor="end" className="calendar-burn-axis">
              {buckets[buckets.length - 1]!.label}
            </text>
          </>
        ) : null}
      </svg>
      <table className="visually-hidden">
        <caption>Per-day cost across the selection</caption>
        <thead>
          <tr>
            <th scope="col">Day</th>
            <th scope="col">Cost (USD)</th>
          </tr>
        </thead>
        <tbody>
          {buckets.map((bucket) => (
            <tr key={bucket.day}>
              <td>{bucket.label}</td>
              <td>{bucket.costUsd.toFixed(4)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </figure>
  );
}
