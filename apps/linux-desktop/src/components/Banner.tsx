import type { ReactNode } from 'react';

export type BannerTone = 'degraded' | 'ok';

/**
 * Inline alert banner. `.banner.degraded[role="alert"]` is the failure-state
 * contract used by settings/account/support routes and the smoke evidence.
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
    <div className={`banner ${tone}`} role={role}>
      {children}
    </div>
  );
}
