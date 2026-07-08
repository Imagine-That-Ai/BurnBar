import { useEffect } from 'react';
import type { ShellRoute } from '../routes.js';
import { DECK_PRIMARY_ROUTES } from './deckPrimaryRoutes.js';

export function usePrimarySectionShortcuts(setRoute: (route: ShellRoute) => void): void {
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
}