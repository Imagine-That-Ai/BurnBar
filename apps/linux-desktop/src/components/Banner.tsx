import type { ReactNode } from 'react';
import { GlassAlert } from './GlassAlert.js';

export type BannerTone = 'degraded' | 'ok';

/**
 * Inline alert banner. Preserves `.banner.degraded[role="alert"]` for smoke evidence;
 * renders Liquid Glass alert chrome underneath.
 */
export function Banner({
  tone = 'degraded',
  role = 'alert',
  children
}: {
  tone?: BannerTone;
  role?: 'alert' | 'status';
  children: ReactNode;
}) {
  return (
    <GlassAlert
      severity={tone === 'ok' ? 'info' : 'warning'}
      role={role}
      className={`banner glass-alert-legacy ${tone}`}
    >
      {children}
    </GlassAlert>
  );
}