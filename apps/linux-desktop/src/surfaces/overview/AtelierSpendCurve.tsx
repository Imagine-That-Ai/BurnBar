import { useId } from 'react';
import { useElementSize } from '../../dashboard/useElementSize.js';
import type { SpendCurveModel } from './overviewAtelierData.js';
import { monotonePath } from './overviewAtelierData.js';

const PAD_L = 44;
const PAD_R = 12;
const PAD_T = 8;
const PAD_B = 28;
const BASE_W = 640;
const BASE_H = 176;

function formatAxisCost(v: number): string {
  if (v >= 1000) return `$${Math.round(v / 1000)}k`;
  return `$${Math.round(v)}`;
}

function formatAxisDate(d: Date, fixtureMode: boolean): string {
  if (fixtureMode) {
    return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' });
  }
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}

function bandAreaPath(points: { x: number; yBase: number; yTop: number }[]): string {
  if (!points.length) return '';
  const topLine = monotonePath(points.map((p) => ({ x: p.x, y: p.yTop })));
  const basePts = [...points].reverse().map((p) => ({ x: p.x, y: p.yBase }));
  const baseLine = monotonePath(basePts);
  const baseSegment = baseLine.replace(/^M [^C]+/, '').trim();
  return baseSegment ? `${topLine} ${baseSegment} Z` : `${topLine} Z`;
}

export function AtelierSpendCurve({
  model,
  fixtureMode,
  loading
}: {
  model: SpendCurveModel;
  fixtureMode: boolean;
  loading?: boolean;
}) {
  const { ref, width } = useElementSize<HTMLElement>();
  const reactId = useId().replace(/:/g, '');
  const W = width > 0 ? Math.max(280, width) : BASE_W;
  const H = Math.max(140, Math.round((W * BASE_H) / BASE_W));
  const plotW = W - PAD_L - PAD_R;
  const plotH = H - PAD_T - PAD_B;

  if (loading) {
    return (
      <div className="atelier-spend-curve atelier-spend-curve--skeleton" aria-busy="true" aria-label="Loading spend curve">
        <div className="atelier-spend-curve-skel-chart" />
      </div>
    );
  }

  const yTicks = fixtureMode
    ? [0, 5000, 10000, 15000]
    : [0, model.yMax * 0.33, model.yMax * 0.66, model.yMax].map((v) => Math.round(v * 100) / 100);

  const xTickDates =
    model.isEmpty || !model.bands[0]?.points.length
      ? []
      : (() => {
          const pts = model.bands[0].points;
          const n = pts.length;
          if (n <= 4) return pts.map((p) => p.date);
          return [0, Math.floor(n / 3), Math.floor((2 * n) / 3), n - 1].map((i) => pts[i]!.date);
        })();

  const toX = (t: number) => PAD_L + t * plotW;
  const toY = (v: number) => PAD_T + (1 - v / model.yMax) * plotH;
  const signature = model.bands.map((band) => band.points.map((p) => `${p.base}:${p.top}`).join(',')).join('|');

  return (
    <figure ref={ref} className="atelier-spend-curve">
      <figcaption className="atelier-spend-curve-head">
        <span className="atelier-spend-curve-title">Provider burn over time</span>
        {!model.isEmpty ? (
          <ul className="atelier-spend-curve-legend" aria-hidden>
            {model.legend.map((item) => (
              <li key={item.id}>
                <span className="atelier-spend-curve-legend-dot" style={{ background: item.color }} />
                <span>{item.label}</span>
              </li>
            ))}
          </ul>
        ) : null}
      </figcaption>
      {model.isEmpty ? (
        <div className="atelier-spend-curve-empty" role="img" aria-label="No spend in this range">
          <svg viewBox={`0 0 ${W} ${H}`} className="atelier-spend-curve-svg" preserveAspectRatio="none" aria-hidden>
            <line
              x1={PAD_L}
              y1={PAD_T + plotH / 2}
              x2={PAD_L + plotW}
              y2={PAD_T + plotH / 2}
              stroke="var(--color-glass-line)"
              strokeWidth={1}
              strokeDasharray="4 6"
            />
          </svg>
          <p className="muted">No spend in this range</p>
        </div>
      ) : (
        <svg
          viewBox={`0 0 ${W} ${H}`}
          width="100%"
          height={H}
          className="atelier-spend-curve-svg"
          preserveAspectRatio="none"
          role="img"
          aria-label="Stacked provider spend over time"
        >
          <defs>
            {model.bands.map((band) => (
              <linearGradient key={`g-${band.id}`} id={`atelier-fill-${reactId}-${band.id}`} x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor={band.color} stopOpacity={0.55} />
                <stop offset="55%" stopColor={band.color} stopOpacity={0.22} />
                <stop offset="100%" stopColor={band.color} stopOpacity={0.04} />
              </linearGradient>
            ))}
          </defs>
          {yTicks.slice(1).map((tick) => (
            <line
              key={tick}
              x1={PAD_L}
              y1={toY(tick)}
              x2={PAD_L + plotW}
              y2={toY(tick)}
              stroke="var(--color-glass-line)"
              strokeOpacity={0.35}
            />
          ))}
          <line
            x1={PAD_L}
            y1={toY(0)}
            x2={PAD_L + plotW}
            y2={toY(0)}
            stroke="var(--color-glass-line)"
            strokeOpacity={0.6}
          />
          {model.bands.map((band) => {
            const n = band.points.length;
            const pts = band.points.map((p, i) => {
              const t = n <= 1 ? 0.5 : i / (n - 1);
              return { x: toX(t), yBase: toY(p.base), yTop: toY(p.top) };
            });
            const area = bandAreaPath(pts);
            const stroke = monotonePath(pts.map((p) => ({ x: p.x, y: p.yTop })));
            return (
              <g key={`${band.id}-${signature}`}>
                <path className="atelier-spend-curve-area" d={area} fill={`url(#atelier-fill-${reactId}-${band.id})`} />
                <path
                  className="atelier-spend-curve-stroke"
                  d={stroke}
                  fill="none"
                  stroke={band.color}
                  strokeWidth={1.4}
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  opacity={0.95}
                />
              </g>
            );
          })}
          {yTicks.map((tick) => (
            <text
              key={`y-${tick}`}
              x={PAD_L - 6}
              y={toY(tick) + 3}
              textAnchor="end"
              className="atelier-spend-curve-axis"
            >
              {formatAxisCost(tick)}
            </text>
          ))}
          {xTickDates.map((d, i) => {
            const t = xTickDates.length <= 1 ? 0.5 : i / (xTickDates.length - 1);
            return (
              <text
                key={d.toISOString()}
                x={toX(t)}
                y={H - 6}
                textAnchor="middle"
                className="atelier-spend-curve-axis"
              >
                {formatAxisDate(d, fixtureMode)}
              </text>
            );
          })}
        </svg>
      )}
    </figure>
  );
}
