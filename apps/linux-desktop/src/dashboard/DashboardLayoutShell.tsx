import type { ReactNode } from 'react';
import { DASHBOARD_LAYOUT_META, type DashboardLayout } from './dashboardLayout.js';
import { DashboardLayoutSwitcher } from './DashboardLayoutSwitcher.js';
import './dashboard-layout.css';

export type DashboardSurfaceState = 'empty' | 'loading' | 'populated' | 'offline' | 'error';

export type DashboardLayoutShellProps = {
  layout: DashboardLayout;
  state: DashboardSurfaceState;
  /** Primary content for populated state; optional for other states. */
  children?: ReactNode;
  errorMessage?: string;
  offlineSummary?: string;
  showSwitcher?: boolean;
};

function StateCopy({
  state,
  errorMessage,
  offlineSummary
}: {
  state: DashboardSurfaceState;
  errorMessage?: string;
  offlineSummary?: string;
}) {
  switch (state) {
    case 'loading':
      return <p className="dashboard-layout-state">Loading overview…</p>;
    case 'empty':
      return <p className="dashboard-layout-state">No usage yet — connect a provider or wait for ingest.</p>;
    case 'offline':
      return (
        <p className="dashboard-layout-state dashboard-layout-state--offline">
          {offlineSummary ?? 'Daemon offline — start the peer to populate this layout.'}
        </p>
      );
    case 'error':
      return (
        <p className="dashboard-layout-state dashboard-layout-state--error" role="alert">
          {errorMessage ?? 'Overview failed to load.'}
        </p>
      );
    default:
      return null;
  }
}

function Frame({ layout, children }: { layout: DashboardLayout; children: ReactNode }) {
  return (
    <div
      className={`dashboard-layout-frame dashboard-layout-frame--${layout}`}
      data-dashboard-layout={layout}
      data-kernel-forward={DASHBOARD_LAYOUT_META[layout].isKernelForward ? 'true' : 'false'}
    >
      {children}
    </div>
  );
}

function SkeletonPanel({
  label,
  variant = 'default',
  span = false
}: {
  label: string;
  variant?: 'default' | 'hero' | 'kernel';
  span?: boolean;
}) {
  const className = [
    'dashboard-layout-panel',
    'dashboard-layout-panel--skeleton',
    variant === 'hero' ? 'dashboard-layout-panel--hero' : '',
    variant === 'kernel' ? 'dashboard-layout-panel--kernel' : '',
    span ? 'dashboard-layout-panel--span' : ''
  ]
    .filter(Boolean)
    .join(' ');
  return (
    <div className={className} aria-hidden="true">
      <span className="dashboard-layout-panel__label">{label}</span>
      <span className="dashboard-layout-panel__shimmer" />
    </div>
  );
}

/** Six layout shells with shared empty/loading/populated/offline/error states. */
export function DashboardLayoutShell({
  layout,
  state,
  children,
  errorMessage,
  offlineSummary,
  showSwitcher = true
}: DashboardLayoutShellProps) {
  const meta = DASHBOARD_LAYOUT_META[layout];
  // Allow body for loading (aria-busy content) and populated; other states use skeleton frames.
  const showBody = !!children && (state === 'populated' || state === 'loading');

  return (
    <section
      className="dashboard-layout-shell"
      aria-label={`${meta.displayName} dashboard layout`}
      data-shell-state={state}
      aria-busy={state === 'loading' ? true : undefined}
    >
      <div className="dashboard-layout-shell__toolbar">
        <div>
          <h2 className="dashboard-layout-shell__title">{meta.displayName}</h2>
          <p className="dashboard-layout-shell__hint">{meta.description}</p>
        </div>
        {showSwitcher ? <DashboardLayoutSwitcher /> : null}
      </div>

      {state !== 'populated' ? (
        <StateCopy state={state} errorMessage={errorMessage} offlineSummary={offlineSummary} />
      ) : null}

      <Frame layout={layout}>
        {showBody ? (
          children
        ) : (
          <>
            {layout === 'classic' && (
              <>
                <SkeletonPanel label="Usage pulse" />
                <SkeletonPanel label="Cost curve" />
                <SkeletonPanel label="Providers" />
              </>
            )}
            {layout === 'aurora' && (
              <>
                <SkeletonPanel label="Provider rail" />
                <SkeletonPanel label="Open hero field" variant="hero" />
                <SkeletonPanel label="Data band" span />
              </>
            )}
            {layout === 'nebula' && (
              <>
                <SkeletonPanel label="Providers" />
                <SkeletonPanel label="Burn card" />
                <SkeletonPanel label="Stage" variant="hero" />
                <SkeletonPanel label="Data row" />
              </>
            )}
            {layout === 'constellation' && (
              <>
                <SkeletonPanel label="Command column" />
                <SkeletonPanel label="Swarm stage" variant="kernel" />
                <SkeletonPanel label="Provider chips" />
              </>
            )}
            {layout === 'cockpit' && (
              <>
                <SkeletonPanel label="Spend share" />
                <SkeletonPanel label="KPI tiles" />
                <SkeletonPanel label="Routing" />
                <SkeletonPanel label="Mission stage" variant="hero" span />
              </>
            )}
            {layout === 'atelier' && (
              <SkeletonPanel label="Kernel hero · floating glass stats" variant="kernel" />
            )}
          </>
        )}
      </Frame>
    </section>
  );
}
