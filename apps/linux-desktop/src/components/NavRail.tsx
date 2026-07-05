import { ROUTES, type ShellRoute } from '../routes.js';
import { useDaemonStatusCopy, useShellStore } from '../state/shellStore.js';
import { StatusPill } from './StatusPill.js';

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
      onClick={() => setRoute(route)}
    >
      {label}
    </button>
  );
}

export function NavRail() {
  const status = useDaemonStatusCopy();
  const skin = useShellStore((s) => s.skin);
  const toggleSkin = useShellStore((s) => s.toggleSkin);
  return (
    <nav className="shell-nav" aria-label="Primary">
      <div className="brand">
        Open<span>BurnBar</span> Linux
      </div>
      <StatusPill status={status} />
      <div className="nav-group-title">Dashboard</div>
      {ROUTES.filter((r) => r.group === 'dashboard').map((r) => (
        <NavButton key={r.id} route={r.id} label={r.label} />
      ))}
      <div className="nav-group-title">System</div>
      {ROUTES.filter((r) => r.group === 'system').map((r) => (
        <NavButton key={r.id} route={r.id} label={r.label} />
      ))}
      <button type="button" className="ghost skin-toggle" onClick={toggleSkin}>
        {`Skin: ${skin}`}
      </button>
    </nav>
  );
}
