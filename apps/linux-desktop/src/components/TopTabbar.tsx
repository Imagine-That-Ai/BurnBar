import { useRef, type KeyboardEvent } from 'react';
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
  const tabRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const selectedIndex = DECK_PRIMARY_ROUTES.indexOf(route);

  function moveTabFocus(index: number, nextIndex: number, event: KeyboardEvent<HTMLButtonElement>): void {
    event.preventDefault();
    if (nextIndex === index) return;
    const nextTab = tabRefs.current[nextIndex];
    if (!nextTab) return;
    nextTab.focus();
    setRoute(DECK_PRIMARY_ROUTES[nextIndex]);
  }

  return (
    <nav className="top-tabbar glass-pill" role="tablist" aria-label="Primary" aria-orientation="horizontal">
      {DECK_PRIMARY_ROUTES.map((section, index) => {
        const meta = topTabMetaFor(section);
        const selected = route === section;
        const label = meta?.tabLabel ?? section;
        const subtitle = meta?.subtitle ?? '';
        const tabIndex = selected || (selectedIndex < 0 && index === 0) ? 0 : -1;
        return (
          <button
            key={section}
            type="button"
            role="tab"
            className="top-tab nav-link glass-focus"
            aria-selected={selected}
            aria-current={selected ? 'page' : undefined}
            tabIndex={tabIndex}
            ref={(tab) => {
              tabRefs.current[index] = tab;
            }}
            onKeyDown={(event) => {
              const lastIndex = DECK_PRIMARY_ROUTES.length - 1;
              if (event.key === 'ArrowRight' || event.key === 'ArrowDown') {
                moveTabFocus(index, (index + 1) % DECK_PRIMARY_ROUTES.length, event);
              } else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') {
                moveTabFocus(index, (index - 1 + DECK_PRIMARY_ROUTES.length) % DECK_PRIMARY_ROUTES.length, event);
              } else if (event.key === 'Home') {
                moveTabFocus(index, 0, event);
              } else if (event.key === 'End') {
                moveTabFocus(index, lastIndex, event);
              }
            }}
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
