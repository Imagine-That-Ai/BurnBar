import type { ShellRoute } from '../routes.js';
import { ROUTES } from '../routes.js';
import { PROVIDER_GLYPHS } from '../providerGlyphs.js';
import { formatCostUsd } from '../surfaces/activity/sessionFormat.js';
import type { CSSProperties } from 'react';
import './sidebar-extras.css';
import { ProviderLogoView } from './ProviderLogoView.js';

import { useShellStore } from '../state/shellStore.js';

const DASHBOARD_ROUTE_ORDER = ROUTES.filter((r) => r.group === 'dashboard').map((r) => r.id);

const ROUTE_PROVIDER: Partial<Record<ShellRoute, string>> = {
  insights: 'anthropic',
  database: 'hermes',
  providers: 'openai',
  projects: 'cursor',
  missions: 'opencode',
  activity: 'anthropic',
  chat: 'hermes',
  memory: 'google'
};

const ROUTE_SESSIONS: Partial<Record<ShellRoute, number>> = {
  overview: 12,
  insights: 8,
  database: 3,
  providers: 6,
  projects: 4,
  missions: 2,
  activity: 14,
  chat: 5,
  memory: 7
};

const ROUTE_COST_USD: Partial<Record<ShellRoute, number>> = {
  overview: 4.82,
  insights: 2.14,
  database: 0.42,
  providers: 1.06,
  projects: 0.88,
  missions: 0.35,
  activity: 3.21,
  chat: 1.47,
  memory: 0.59
};

const OVERVIEW_ACCENT =
  PROVIDER_GLYPHS.find((g) => g.id === 'factory')?.accent ?? 'var(--color-brass-core)';

type Props = {
  route: ShellRoute;
  label: string;
  displayName?: string;
};

/**
 * Metric-bearing dashboard nav row — macOS `SidebarItem` semantics.
 * Retains `nav-link` class for smoke/a11y geometry contract; layout via `.sidebar-item`.
 */
export function SidebarItem({ route, label, displayName }: Props) {
  const active = useShellStore((s) => s.route === route);
  const setRoute = useShellStore((s) => s.setRoute);

  const isOverview = route === 'overview';
  const providerId = ROUTE_PROVIDER[route];
  const glyph = providerId
    ? (PROVIDER_GLYPHS.find((g) => g.id === providerId) ?? PROVIDER_GLYPHS[0])
    : null;
  const sessionCount = ROUTE_SESSIONS[route] ?? 0;
  const costUsd = ROUTE_COST_USD[route] ?? 0;
  const name = displayName ?? label;
  const sessionsLabel = `${sessionCount} session${sessionCount === 1 ? '' : 's'}`;

  const staggerIndex = DASHBOARD_ROUTE_ORDER.indexOf(route);
  const entranceDelayMs = staggerIndex >= 0 ? staggerIndex * 60 : 0;

  const accentStyle = {
    '--sidebar-item-accent': isOverview ? OVERVIEW_ACCENT : (glyph?.accent ?? OVERVIEW_ACCENT),
    '--sidebar-item-entrance-delay': `${entranceDelayMs}ms`
  } as CSSProperties;

  return (
    <button
      type="button"
      className={`nav-link sidebar-item${active ? ' sidebar-item--selected' : ''}`}
      aria-current={active ? 'page' : 'false'}
      data-route={route}
      onClick={() => setRoute(route)}
      style={accentStyle}
    >
      <span className="sidebar-item-glyph" aria-hidden="true">
        <span className="sidebar-item-glyph-ring">
          {isOverview ? (
            <span className="sidebar-item-grid-icon" aria-hidden="true">
              <svg width="22" height="22" viewBox="0 0 22 22" fill="none" xmlns="http://www.w3.org/2000/svg">
                <rect x="3" y="3" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.4" />
                <rect x="12" y="3" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.4" />
                <rect x="3" y="12" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.4" />
                <rect x="12" y="12" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.4" />
              </svg>
            </span>
          ) : glyph ? (
            <ProviderLogoView
              id={glyph.id}
              size={22}
              useFallbackColor={false}
              accent={glyph.accent}
              className="sidebar-item-logo"
            />
          ) : null}
        </span>
      </span>
      <span className="sidebar-item-body">
        <span className="sidebar-item-title">{name}</span>
        <span className="sidebar-item-sessions">{sessionsLabel}</span>
      </span>
      <span className="sidebar-item-trail">
        <span className="sidebar-item-metric mono tabular-nums">{formatCostUsd(costUsd)}</span>
        <span className="sidebar-item-chevron" aria-hidden="true">
          ›
        </span>
      </span>
    </button>
  );
}