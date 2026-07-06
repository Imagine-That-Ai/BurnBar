/**
 * Dependency-free SVG sparkline for perf/usage rows. Accepts raw values,
 * normalizes internally, and stays legible at 12–24px heights.
 * Area fill + end cap mirror macOS BurnRailSparkline.
 */
import { useId } from 'react';

export function Sparkline({
  values,
  width = 120,
  height = 28,
  label
}: {
  values: number[];
  width?: number;
  height?: number;
  label?: string;
}) {
  const gradientId = useId().replace(/:/g, '');
  if (values.length < 2) return null;
  const min = Math.min(...values);
  const max = Math.max(...values);
  const span = Math.max(max - min, 1e-9);
  const pad = 2;
  const coords = values.map((v, i) => {
    const x = pad + (i / (values.length - 1)) * (width - pad * 2);
    const y = height - pad - ((v - min) / span) * (height - pad * 2);
    return { x, y };
  });
  const linePoints = coords.map((p) => `${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(' ');
  const areaPath = [
    `M ${coords[0]!.x.toFixed(1)} ${coords[0]!.y.toFixed(1)}`,
    ...coords.slice(1).map((p) => `L ${p.x.toFixed(1)} ${p.y.toFixed(1)}`),
    `L ${(width - pad).toFixed(1)} ${(height - pad).toFixed(1)}`,
    `L ${pad.toFixed(1)} ${(height - pad).toFixed(1)}`,
    'Z'
  ].join(' ');
  const last = coords[coords.length - 1]!;

  return (
    <svg
      className="sparkline"
      width={width}
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      role={label ? 'img' : 'presentation'}
      aria-label={label}
    >
      <defs>
        <linearGradient id={gradientId} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="var(--color-brass-core)" stopOpacity="0.35" />
          <stop offset="100%" stopColor="var(--color-brass-core)" stopOpacity="0" />
        </linearGradient>
      </defs>
      <path className="sparkline-fill" d={areaPath} fill={`url(#${gradientId})`} />
      <polyline
        className="sparkline-line"
        points={linePoints}
        fill="none"
        stroke="var(--color-brass-core)"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <circle
        className="sparkline-end-dot"
        cx={last.x}
        cy={last.y}
        r={1.5}
        fill="var(--color-brass-core)"
      />
    </svg>
  );
}