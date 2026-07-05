/**
 * Dependency-free SVG sparkline for perf/usage rows. Accepts raw values,
 * normalizes internally, and stays legible at 12–24px heights.
 */
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
  if (values.length < 2) return null;
  const min = Math.min(...values);
  const max = Math.max(...values);
  const span = Math.max(max - min, 1e-9);
  const pad = 2;
  const points = values
    .map((v, i) => {
      const x = pad + (i / (values.length - 1)) * (width - pad * 2);
      const y = height - pad - ((v - min) / span) * (height - pad * 2);
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    })
    .join(' ');
  return (
    <svg
      className="sparkline"
      width={width}
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      role={label ? 'img' : 'presentation'}
      aria-label={label}
    >
      <polyline points={points} fill="none" stroke="var(--color-brass-core)" strokeWidth="1.5" />
    </svg>
  );
}
