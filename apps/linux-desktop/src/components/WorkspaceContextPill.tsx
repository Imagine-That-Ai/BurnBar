import type { ShellRoute } from '../routes.js';
import { ROUTES } from '../routes.js';
import { topTabMetaFor } from '../topTabMeta.js';
import type { UsageSummary } from '../tauriBridge.js';
import { useDaemonStatusCopy, useShellStore } from '../state/shellStore.js';
import { useOverviewStore } from '../state/overviewStore.js';
import './TopChrome.css';

function contextHeadline(route: ShellRoute): string {
  const tab = topTabMetaFor(route);
  if (tab) return tab.tabLabel.toUpperCase();
  const meta = ROUTES.find((r) => r.id === route);
  return (meta?.label ?? route).toUpperCase();
}

function overviewSessionCount(summary: UsageSummary | null): number | null {
  if (!summary) return null;
  return new Set(summary.recentEvents.map((e) => e.id)).size;
}

function overviewProviderCount(summary: UsageSummary | null, fixtureMode: boolean): number | null {
  if (fixtureMode) return 5;
  if (!summary) return null;
  const ids = new Set<string>();
  for (const e of summary.recentEvents) {
    const provider = e.title.split('/')[0]?.trim();
    if (provider) ids.add(provider);
  }
  return ids.size || null;
}

function contextCaption(
  route: ShellRoute,
  providerCount: number | null,
  sessionCount: number | null
): string {
  if (route === 'overview') {
    const providers = providerCount ?? '—';
    const sessions = sessionCount != null ? sessionCount.toLocaleString() : '—';
    return `${providers} providers · ${sessions} sessions in window`;
  }
  const tab = topTabMetaFor(route);
  if (tab) return tab.subtitle;
  const meta = ROUTES.find((r) => r.id === route);
  return meta?.description ?? '';
}

export function WorkspaceContextPill() {
  const route = useShellStore((s) => s.route);
  const status = useDaemonStatusCopy();
  const summary = useOverviewStore((s) => s.summary);
  const fixtureMode = useShellStore((s) => s.fixtureMode);

  const providerCount = overviewProviderCount(summary, fixtureMode);
  const sessionCount = overviewSessionCount(summary);

  return (
    <div className="workspace-context-pill" aria-live="polite">
      <span className="workspace-context-kicker">{contextHeadline(route)}</span>
      <span className="workspace-context-caption">
        {route === 'overview' && !fixtureMode && !summary
          ? status.detail
          : contextCaption(route, providerCount, sessionCount)}
      </span>
    </div>
  );
}