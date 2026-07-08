import type { ShellRoute } from '../routes.js';

/** Seven Command Deck sections — mirrors `DashboardMainRoute.primarySections`. */
export const DECK_PRIMARY_ROUTES: ShellRoute[] = [
  'chat',
  'providers',
  'database',
  'projects',
  'missions',
  'activity',
  'memory'
];

export function deckPrimaryShortcutIndex(route: ShellRoute): number | null {
  const index = DECK_PRIMARY_ROUTES.indexOf(route);
  return index >= 0 ? index + 1 : null;
}

export type DeckTimeRange = 'today' | 'week' | 'month' | 'all';

export const DECK_TIME_RANGES: { id: DeckTimeRange; label: string }[] = [
  { id: 'today', label: 'Today' },
  { id: 'week', label: 'This week' },
  { id: 'month', label: 'This month' },
  { id: 'all', label: 'All time' }
];

export type DeckHeroUnit = 'cost' | 'tokens';

const HERO_UNIT_KEY = 'openburnbar.linux.deckHeroUnit.v1';
const TIME_RANGE_KEY = 'openburnbar.linux.deckTimeRange.v1';

export function readDeckHeroUnit(): DeckHeroUnit {
  try {
    const v = localStorage.getItem(HERO_UNIT_KEY);
    return v === 'tokens' ? 'tokens' : 'cost';
  } catch {
    return 'cost';
  }
}

export function persistDeckHeroUnit(unit: DeckHeroUnit): void {
  try {
    localStorage.setItem(HERO_UNIT_KEY, unit);
  } catch {
    // convenience only
  }
}

export function readDeckTimeRange(): DeckTimeRange {
  try {
    const v = localStorage.getItem(TIME_RANGE_KEY);
    if (v === 'week' || v === 'month' || v === 'all') return v;
    return 'today';
  } catch {
    return 'today';
  }
}

export function persistDeckTimeRange(range: DeckTimeRange): void {
  try {
    localStorage.setItem(TIME_RANGE_KEY, range);
  } catch {
    // convenience only
  }
}