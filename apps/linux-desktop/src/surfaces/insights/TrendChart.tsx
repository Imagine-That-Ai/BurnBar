import type { WeeklyPoint } from '../../tauriBridge.js';
import { normalizeValues, trendAriaSummary } from './insightsChartMath.js';

const WIDTH = 480;
const HEIGHT = 200;
const PAD_X = 36;
const PAD_TOP = 12;
const PAD_BOTTOM = 28;
const PLOT_H = HEIGHT - PAD_TOP - PAD_BOTTOM;
const PLOT_W = WIDTH - PAD_X * 2;

export function TrendChart({ weekly }: { weekly: WeeklyPoint[] }) {
  const values = weekly.map((w) => w.tokens);
  const norm = normalizeValues(values);
  const ariaLabel = trendAriaSummary(weekly);

  const linePoints =
    norm.length === 0
      ? ''
      : norm.length === 1
        ? `${PAD_X},${PAD_TOP + PLOT_H / 2}`
        : norm
            .map((t, i) => {
              const x = PAD_X + (i / (norm.length - 1)) * PLOT_W;
              const y = PAD_TOP + (1 - t) * PLOT_H;
              return `${x.toFixed(1)},${y.toFixed(1)}`;
            })
            .join(' ');

  const areaPoints =
    norm.length === 0
      ? ''
      : norm.length === 1
        ? `${PAD_X},${PAD_TOP + PLOT_H} ${PAD_X},${PAD_TOP + PLOT_H / 2} ${PAD_X + PLOT_W},${PAD_TOP + PLOT_H / 2} ${PAD_X + PLOT_W},${PAD_TOP + PLOT_H}`
        : [
            `${PAD_X},${PAD_TOP + PLOT_H}`,
            ...norm.map((t, i) => {
              const x = PAD_X + (i / (norm.length - 1)) * PLOT_W;
              const y = PAD_TOP + (1 - t) * PLOT_H;
              return `${x.toFixed(1)},${y.toFixed(1)}`;
            }),
            `${PAD_X + PLOT_W},${PAD_TOP + PLOT_H}`
          ].join(' ');

  const gradientId = 'insights-trend-fill';

  let endDot: { cx: number; cy: number } | null = null;
  if (norm.length > 1) {
    const lastT = norm[norm.length - 1]!;
    endDot = {
      cx: PAD_X + PLOT_W,
      cy: PAD_TOP + (1 - lastT) * PLOT_H
    };
  }

  return (
    <figure className="insights-trend">
      <figcaption className="insights-trend-title">Weekly tokens</figcaption>
      <svg
        className="insights-trend-svg"
        width="100%"
        height={HEIGHT}
        viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
        role="img"
        aria-label={ariaLabel}
        preserveAspectRatio="xMidYMid meet"
      >
        <defs>
          <linearGradient id={gradientId} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="var(--color-brass-core)" stopOpacity="0.35" />
            <stop offset="100%" stopColor="var(--color-brass-core)" stopOpacity="0" />
          </linearGradient>
        </defs>
        {areaPoints ? <polygon points={areaPoints} fill={`url(#${gradientId})`} /> : null}
        {linePoints && norm.length > 1 ? (
          <polyline
            points={linePoints}
            fill="none"
            stroke="var(--color-brass-core)"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        ) : null}
        {endDot ? (
          <circle
            className="insights-trend-end-dot"
            cx={endDot.cx}
            cy={endDot.cy}
            r="3.5"
            fill="var(--color-brass-core)"
          />
        ) : null}
        {norm.length === 1 ? (
          <circle
            cx={PAD_X}
            cy={PAD_TOP + PLOT_H / 2}
            r="4"
            fill="var(--color-brass-core)"
          />
        ) : null}
        {weekly.map((w, i) => {
          const x =
            weekly.length === 1
              ? PAD_X
              : PAD_X + (i / (weekly.length - 1)) * PLOT_W;
          return (
            <text
              key={w.label}
              x={x}
              y={HEIGHT - 8}
              textAnchor="middle"
              className="insights-axis-label"
            >
              {w.label}
            </text>
          );
        })}
      </svg>
      <table className="visually-hidden">
        <caption>Weekly token usage</caption>
        <thead>
          <tr>
            <th scope="col">Week</th>
            <th scope="col">Tokens</th>
            <th scope="col">Cost (USD)</th>
          </tr>
        </thead>
        <tbody>
          {weekly.map((w) => (
            <tr key={w.label}>
              <td>{w.label}</td>
              <td>{w.tokens}</td>
              <td>{w.costUsd}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </figure>
  );
}