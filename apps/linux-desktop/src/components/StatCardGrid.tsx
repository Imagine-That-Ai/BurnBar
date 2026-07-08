import type { ReactNode } from 'react';
import './chrome.css';

export type StatCardItem = {
  id: string;
  label: string;
  value?: ReactNode;
  valueGradient?: boolean;
  tint?: string;
  sparkline?: ReactNode;
  pills?: ReactNode;
  footer?: ReactNode;
};

export function StatCardGrid({
  items,
  className,
  'aria-label': ariaLabel,
  'aria-busy': ariaBusy
}: {
  items: StatCardItem[];
  className?: string;
  'aria-label'?: string;
  'aria-busy'?: boolean;
}) {
  return (
    <ul
      className={['stat-card-grid', className].filter(Boolean).join(' ')}
      aria-label={ariaLabel}
      aria-busy={ariaBusy}
    >
      {items.map((item) => (
        <li
          key={item.id}
          className="stat-card"
          style={item.tint ? { ['--stat-card-tint' as string]: item.tint } : undefined}
        >
          <p className="stat-card-label">{item.label}</p>
          <div className="stat-card-body">
            {item.value != null ? (
              <p
                className={[
                  'stat-card-value',
                  'tabular-nums',
                  item.valueGradient ? 'stat-card-value--gradient' : ''
                ]
                  .filter(Boolean)
                  .join(' ')}
              >
                {item.value}
              </p>
            ) : null}
            {item.sparkline ? <div className="stat-card-sparkline">{item.sparkline}</div> : null}
            {item.footer ? <div className="stat-card-footer">{item.footer}</div> : null}
            {item.pills ? <div className="stat-card-pills">{item.pills}</div> : null}
          </div>
        </li>
      ))}
    </ul>
  );
}

export function StatCardGridSkeleton({
  count = 4,
  className,
  ariaLabel = 'Loading'
}: {
  count?: number;
  className?: string;
  ariaLabel?: string;
}) {
  return (
    <ul className={['stat-card-grid', className].filter(Boolean).join(' ')} aria-busy="true" aria-label={ariaLabel}>
      {Array.from({ length: count }, (_, i) => (
        <li key={`sk-${i}`} className="stat-card stat-card--skeleton">
          <div className="stat-card-skeleton-line" />
          <div className="stat-card-skeleton-block" />
        </li>
      ))}
    </ul>
  );
}