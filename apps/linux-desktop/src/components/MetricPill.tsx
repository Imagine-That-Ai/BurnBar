import type { ReactNode } from 'react';
import './chrome.css';

export type MetricPillProps = {
  label: string;
  value: string | number;
  tint?: string;
  icon?: ReactNode;
};

/**
 * Capsule metric chip (macOS CastleMetricPill): icon + mono value + tiny label,
 * tint at 10% background. Icon may be a text glyph (◎, $) or SVG. Accessible name: "label, value".
 */
export function MetricPill({ label, value, tint = 'var(--color-brass-core)', icon }: MetricPillProps) {
  const ariaLabel = `${label}, ${value}`;
  return (
    <span
      className="metric-pill"
      style={{ ['--metric-pill-tint' as string]: tint }}
      role="status"
      aria-label={ariaLabel}
    >
      {icon ? (
        <span className="metric-pill-icon" aria-hidden="true">
          {icon}
        </span>
      ) : null}
      <span className="metric-pill-value tabular-nums">{value}</span>
      <span className="metric-pill-label">{label}</span>
    </span>
  );
}