import { useState } from 'react';
import { ROUTES, type ShellRoute } from '../routes.js';
import { useDaemonStatusCopy, useShellStore } from '../state/shellStore.js';
import { StatusPill } from './StatusPill.js';
import { SidebarItem } from './SidebarItem.js';
import {
  SIDEBAR_MODE_COPY,
  SidebarSegmentedPicker,
  type SidebarViewMode
} from './SidebarSegmentedPicker.js';
import { PROVIDER_GLYPHS } from '../providerGlyphs.js';
import './sidebar-extras.css';


/**
 * Primary navigation rail.
 *
 * GEOMETRY CONTRACT: the packaged desktop-session smoke clicks nav items at
 * fixed pixel coordinates (scripts/linux-port/linux-desktop-session.sh).
 * Brand, status pill, group titles, and nav links must keep their vertical
 * metrics — padding, gaps, and font sizes in app.css are load-bearing.
 * Visual changes go through color/gradient/hover only.
 *
 * A11y contract: `nav[aria-label="Primary"]`, one
 * `button.nav-link[aria-current="page"]` per active route.
 */
function NavButton({ route, label }: { route: ShellRoute; label: string }) {
  const active = useShellStore((s) => s.route === route);
  const setRoute = useShellStore((s) => s.setRoute);
  return (
    <button
      type="button"
      className="nav-link"
      aria-current={active ? 'page' : 'false'}
      data-route={route}
      onClick={() => setRoute(route)}
    >
      {label}
    </button>
  );
}

const SIDEBAR_WINDOW_FIXTURE = {
  timeRangeLabel: 'Last 7 days',
  activeProviderCount: 5
} as const;

const CURSOR_GLYPH = PROVIDER_GLYPHS.find((g) => g.id === 'cursor') ?? PROVIDER_GLYPHS[0];
const CURSOR_EXTENSION_ID = 'openburnbar.openburnbar';

function openBurnBarCursorExtension() {
  const candidates = [
    `cursor:extension/${CURSOR_EXTENSION_ID}`,
    `vscode:extension/${CURSOR_EXTENSION_ID}`
  ];
  for (const url of candidates) {
    const opened = window.open(url, '_blank');
    if (opened) return;
  }
}


export function NavRail() {
  const status = useDaemonStatusCopy();
  const skin = useShellStore((s) => s.skin);
  const toggleSkin = useShellStore((s) => s.toggleSkin);
  const health = useShellStore((s) => s.health);
  const [viewMode, setViewMode] = useState<SidebarViewMode>('agents');
  const modeCopy = SIDEBAR_MODE_COPY[viewMode];

  return (
    <nav className="shell-nav" aria-label="Primary">
      <div className="brand">
        Open<span>BurnBar</span> Linux
      </div>
      <StatusPill status={status} />

      <header className="sidebar-command-header">
        <span className="sidebar-command-kicker">Command</span>
        <span className="sidebar-command-title">{modeCopy.title}</span>
        <span className="sidebar-command-desc">{modeCopy.description}</span>
      </header>

      <SidebarSegmentedPicker mode={viewMode} onModeChange={setViewMode} />

      <div className="nav-group-title">Dashboard</div>
      {ROUTES.filter((r) => r.group === 'dashboard').map((r) => (
        <SidebarItem key={r.id} route={r.id} label={r.label} />
      ))}
      <div className="nav-group-title">System</div>
      {ROUTES.filter((r) => r.group === 'system').map((r) => (
        <NavButton key={r.id} route={r.id} label={r.label} />
      ))}
      <button type="button" className="ghost skin-toggle" onClick={toggleSkin}>
        {`Skin: ${skin}`}
      </button>
      <div className="sidebar-glass-card">
        <span className="sidebar-card-label">Daemon</span>
        <span className="sidebar-card-value mono">{health?.daemonVersion ?? 'offline'}</span>
        <span className="sidebar-card-detail">
          {health?.ok ? 'Connected over AF_UNIX' : 'Awaiting local socket'}
        </span>
      </div>

      <div className="sidebar-glass-card">
        <span className="sidebar-card-label">Window</span>
        <span className="sidebar-card-value">{SIDEBAR_WINDOW_FIXTURE.timeRangeLabel}</span>
        <span className="sidebar-card-detail">
          {`${SIDEBAR_WINDOW_FIXTURE.activeProviderCount} active providers`}
        </span>
      </div>

      <div className="sidebar-glass-card sidebar-glass-card--cursor">
        <span className="sidebar-card-label">Cursor</span>
        <button
          type="button"
          className="sidebar-cursor-cta"
          onClick={openBurnBarCursorExtension}
          title="Install OpenBurnBar in Cursor (openburnbar.openburnbar)"
        >
          <span className="sidebar-cursor-cta-glyph" aria-hidden="true">
            <span
              className="sidebar-cursor-cta-ring"
              style={{ borderColor: CURSOR_GLYPH.accent }}
            >
              <span className="sidebar-cursor-cta-dot" style={{ background: CURSOR_GLYPH.accent }} />
            </span>
          </span>
          <span className="sidebar-cursor-cta-copy">
            <span className="sidebar-cursor-cta-title">Add OpenBurnBar to Cursor</span>
            <span className="sidebar-cursor-cta-detail">Opens the extension install page</span>
          </span>
          <span className="sidebar-cursor-cta-arrow" aria-hidden="true">
            ↗
          </span>
        </button>
      </div>
    </nav>
  );
}