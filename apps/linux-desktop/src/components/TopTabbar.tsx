import { DECK_PRIMARY_ROUTES } from './deckPrimaryRoutes.js';
import { DeckRouteIcon } from './deckRouteVisuals.js';
import { topTabMetaFor } from '../topTabMeta.js';
import { useShellStore } from '../state/shellStore.js';
import './TopChrome.css';

/**
 * Seven-section tab strip below the toolbar (`DashboardMainRoute.primarySections`).
 */
export function TopTabbar() {
  const route = useShellStore((s) => s.route);
  const setRoute = useShellStore((s) => s.setRoute);

  return (
    <nav className="top-tabbar glass-pill" role="tablist" aria-label="Primary">
      {DECK_PRIMARY_ROUTES.map((section) => {
        const meta = topTabMetaFor(section);
        const selected = route === section;
        const label = meta?.tabLabel ?? section;
        const subtitle = meta?.subtitle ?? '';
        return (
          <button
            key={section}
            type="button"
            role="tab"
            className="top-tab nav-link glass-focus"
            aria-selected={selected}
            aria-current={selected ? 'page' : undefined}
            onClick={() => setRoute(section)}
          >
            <span className="top-tab-icon" aria-hidden="true">
              <DeckRouteIcon route={section} />
            </span>
            <span className="top-tab-copy">
              <span className="top-tab-label sidebar-item-title">{label}</span>
              <span className="top-tab-subtitle">{subtitle}</span>
            </span>
          </button>
        );
      })}
    </nav>
  );
}