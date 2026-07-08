import type { ReactNode } from 'react';
import './concept-stat-tile.css';

export function ConceptStatTile({
  label,
  value,
  caption,
  accent = 'var(--color-brass-bright)',
  prominence = 'compact',
  className
}: {
  label: string;
  value: ReactNode;
  caption?: ReactNode;
  accent?: string;
  prominence?: 'hero' | 'compact';
  className?: string;
}) {
  return (
    <article
      className={['concept-stat-tile', `concept-stat-tile--${prominence}`, className].filter(Boolean).join(' ')}
      style={{ ['--concept-stat-accent' as string]: accent }}
      aria-label={`${label}: ${typeof value === 'string' || typeof value === 'number' ? value : ''}`}
    >
      <p className="concept-stat-tile-label">{label}</p>
      <p className="concept-stat-tile-value tabular-nums">{value}</p>
      {caption ? <p className="concept-stat-tile-caption muted">{caption}</p> : null}
    </article>
  );
}

export function ConceptStatTileSkeleton({ className }: { className?: string }) {
  return (
    <article className={['concept-stat-tile concept-stat-tile--skeleton', className].filter(Boolean).join(' ')} aria-hidden>
      <div className="concept-stat-tile-skel-line" />
      <div className="concept-stat-tile-skel-value" />
    </article>
  );
}