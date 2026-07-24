import type { ReactNode } from 'react';
import { GlassCard } from './GlassCard.js';

/**
 * Primary route surface container. Contract pinned by the evidence harness:
 * `section.card[aria-labelledby="route-title"]` containing `h2#route-title`.
 * Exactly one SurfaceCard with `titleId="route-title"` renders per route.
 */
export function SurfaceCard({
  title,
  description,
  titleId = 'route-title',
  children
}: {
  title: string;
  description?: string;
  titleId?: string;
  children?: ReactNode;
}) {
  return (
    <GlassCard as="section" aria-labelledby={titleId}>
      <h2 id={titleId}>{title}</h2>
      {description ? <p className="muted card-description">{description}</p> : null}
      {children}
    </GlassCard>
  );
}
