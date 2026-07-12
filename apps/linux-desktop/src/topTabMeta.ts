import type { ShellRoute } from './routes.js';
import { DECK_PRIMARY_ROUTES } from './components/deckPrimaryRoutes.js';

/** Command-deck tab presentation — mirrors `DashboardMainRoute` title/subtitle. */
export type TopTabMeta = {
  route: ShellRoute;
  tabLabel: string;
  subtitle: string;
};

export const TOP_TAB_META: TopTabMeta[] = [
  { route: 'chat', tabLabel: 'Chat', subtitle: 'Full-canvas chat' },
  { route: 'providers', tabLabel: 'Quota', subtitle: 'Subscriptions & limits' },
  { route: 'database', tabLabel: 'Database', subtitle: 'Browse tracked sessions' },
  { route: 'projects', tabLabel: 'Projects', subtitle: 'Group by project' },
  { route: 'missions', tabLabel: 'Missions', subtitle: 'Active runs & tasks' },
  { route: 'activity', tabLabel: 'Session Logs', subtitle: 'Indexed conversations' },
  { route: 'memory', tabLabel: 'Memory', subtitle: 'Review what OpenBurnBar learned' }
];

export function topTabMetaFor(route: ShellRoute): TopTabMeta | undefined {
  return TOP_TAB_META.find((t) => t.route === route);
}

export function isPrimaryTopTab(route: ShellRoute): boolean {
  return DECK_PRIMARY_ROUTES.includes(route);
}