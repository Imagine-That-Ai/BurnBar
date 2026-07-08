import { useEffect, useId, useRef, useState } from 'react';
import { ROUTES } from '../routes.js';
import type { ShellRoute } from '../routes.js';
import { useShellStore } from '../state/shellStore.js';
import { DECK_PRIMARY_ROUTES, deckPrimaryShortcutIndex } from './deckPrimaryRoutes.js';
import { DeckRouteIcon } from './deckRouteVisuals.js';

export function DeckSectionSwitcher() {
  const route = useShellStore((s) => s.route);
  const setRoute = useShellStore((s) => s.setRoute);
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);
  const listId = useId();
  const currentLabel = ROUTES.find((r) => r.id === route)?.label ?? route;

  useEffect(() => {
    if (!open) return;
    const onDoc = (ev: MouseEvent) => {
      if (!rootRef.current?.contains(ev.target as Node)) setOpen(false);
    };
    const onKey = (ev: KeyboardEvent) => {
      if (ev.key === 'Escape') setOpen(false);
    };
    document.addEventListener('mousedown', onDoc);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDoc);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);

  useEffect(() => {
    const onKey = (ev: KeyboardEvent) => {
      if (!(ev.metaKey || ev.ctrlKey) || ev.altKey || ev.shiftKey) return;
      const digit = Number(ev.key);
      if (digit < 1 || digit > 7) return;
      const target = DECK_PRIMARY_ROUTES[digit - 1];
      if (!target) return;
      ev.preventDefault();
      setRoute(target);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [setRoute]);

  const navigate = (next: ShellRoute) => {
    setRoute(next);
    setOpen(false);
  };

  return (
    <div className="deck-section-switcher" ref={rootRef}>
      <button
        type="button"
        className="deck-capsule-trigger"
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={listId}
        onClick={() => setOpen((v) => !v)}
      >
        <span className="deck-capsule-trigger-icon">
          <DeckRouteIcon route={route} />
        </span>
        <span className="deck-capsule-trigger-title">{currentLabel}</span>
        <span className="deck-capsule-trigger-chevron" aria-hidden="true">
          ▾
        </span>
      </button>
      {open ? (
        <ul className="deck-section-menu" id={listId} role="listbox" aria-label="Switch section">
          {DECK_PRIMARY_ROUTES.map((section, index) => {
            const selected = section === route;
            const shortcut = index + 1;
            const label = ROUTES.find((r) => r.id === section)?.label ?? section;
            return (
              <li key={section} role="presentation">
                <button
                  type="button"
                  role="option"
                  aria-selected={selected}
                  className="deck-section-menu-item"
                  onClick={() => navigate(section)}
                >
                  <span className="deck-section-menu-check" aria-hidden="true">
                    {selected ? '✓' : ''}
                  </span>
                  <span className="deck-section-menu-icon">
                    <DeckRouteIcon route={section} />
                  </span>
                  <span className="deck-section-menu-label">{label}</span>
                  <span className="deck-section-menu-shortcut mono" aria-hidden="true">
                    ⌘{shortcut}
                  </span>
                </button>
              </li>
            );
          })}
        </ul>
      ) : null}
      <span className="sr-only">
        {deckPrimaryShortcutIndex(route) != null
          ? `Section shortcut ⌘${deckPrimaryShortcutIndex(route)}`
          : 'Section not in primary shortcuts'}
      </span>
    </div>
  );
}