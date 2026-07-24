import { useEffect, useId, useRef, useState, type KeyboardEvent as ReactKeyboardEvent } from 'react';
import { ROUTES } from '../routes.js';
import type { ShellRoute } from '../routes.js';
import { useShellStore } from '../state/shellStore.js';
import { DECK_PRIMARY_ROUTES, deckPrimaryShortcutIndex } from './deckPrimaryRoutes.js';
import { DeckRouteIcon } from './deckRouteVisuals.js';

export function DeckSectionSwitcher() {
  const route = useShellStore((s) => s.route);
  const setRoute = useShellStore((s) => s.setRoute);
  const [open, setOpen] = useState(false);
  const [activeIndex, setActiveIndex] = useState(0);
  const rootRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const optionRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const listId = useId();
  const currentLabel = ROUTES.find((r) => r.id === route)?.label ?? route;
  const selectedIndex = DECK_PRIMARY_ROUTES.indexOf(route);

  useEffect(() => {
    if (!open) return;
    const initialIndex = selectedIndex >= 0 ? selectedIndex : 0;
    setActiveIndex(initialIndex);
    optionRefs.current[initialIndex]?.focus();
    const onDoc = (ev: MouseEvent) => {
      if (!rootRef.current?.contains(ev.target as Node)) setOpen(false);
    };
    document.addEventListener('mousedown', onDoc);
    return () => {
      document.removeEventListener('mousedown', onDoc);
    };
  }, [open, selectedIndex]);

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

  const closeMenu = (restoreFocus: boolean) => {
    setOpen(false);
    if (restoreFocus) triggerRef.current?.focus();
  };

  const navigate = (next: ShellRoute) => {
    setRoute(next);
    closeMenu(true);
  };

  const focusOption = (index: number) => {
    const normalized = (index + DECK_PRIMARY_ROUTES.length) % DECK_PRIMARY_ROUTES.length;
    setActiveIndex(normalized);
    optionRefs.current[normalized]?.focus();
  };

  const onOptionKeyDown = (event: ReactKeyboardEvent<HTMLButtonElement>, index: number) => {
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      focusOption(index + 1);
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      focusOption(index - 1);
    } else if (event.key === 'Home') {
      event.preventDefault();
      focusOption(0);
    } else if (event.key === 'End') {
      event.preventDefault();
      focusOption(DECK_PRIMARY_ROUTES.length - 1);
    } else if (event.key === 'Escape') {
      event.preventDefault();
      closeMenu(true);
    } else if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      navigate(DECK_PRIMARY_ROUTES[index]);
    }
  };

  return (
    <div className="deck-section-switcher" ref={rootRef}>
      <button
        type="button"
        className="deck-capsule-trigger"
        ref={triggerRef}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={listId}
        onClick={() => setOpen((v) => !v)}
        onKeyDown={(event) => {
          if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault();
            setOpen(true);
          }
        }}
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
                  id={`${listId}-${section}`}
                  tabIndex={index === activeIndex ? 0 : -1}
                  ref={(option) => {
                    optionRefs.current[index] = option;
                  }}
                  className="deck-section-menu-item"
                  onKeyDown={(event) => onOptionKeyDown(event, index)}
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
