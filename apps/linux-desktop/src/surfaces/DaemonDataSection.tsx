import { routeFixture } from '../daemonFixture.js';
import { displayLinuxSocketPath } from '../shellPaths.js';
import { useDaemonStatusCopy, useShellStore } from '../state/shellStore.js';
import { DataTable } from '../components/DataTable.js';
import { OfflineNotice } from '../components/OfflineNotice.js';
import type { ShellRoute } from '../routes.js';

/**
 * Shared daemon-backed data section. Honesty rules:
 * - live daemon → live health rows labelled as live;
 * - fixture mode → fixture rows labelled as fixture transcript;
 * - offline → OfflineNotice, never mock data.
 */
export function DaemonDataSection({ route, label }: { route: ShellRoute; label: string }) {
  const health = useShellStore((s) => s.health);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const status = useDaemonStatusCopy();

  const useFixture = fixtureMode;
  if (!useFixture && !health?.ok) {
    const summary =
      route === 'overview'
        ? 'Start or reconnect the local daemon to populate health, activity, and provider data.'
        : `${label} needs the local daemon before live rows can load.`;
    return <OfflineNotice status={status} summary={summary} fixtureMode={fixtureMode} />;
  }

  if (!useFixture) {
    const rows = [
      {
        id: 'daemon.version',
        title: health?.daemonVersion ?? 'unknown',
        detail: `Protocol ${health?.protocolVersion ?? 'unknown'}`
      },
      {
        id: 'daemon.socket',
        title: health?.socketPath ?? displayLinuxSocketPath(),
        detail: 'AF_UNIX health probe succeeded through the packaged Tauri bridge.'
      },
      {
        id: 'daemon.gateway',
        title: health?.gatewayEnabled ? 'Gateway enabled' : 'Gateway disabled',
        detail: health?.gatewayEnabled
          ? `${health.gatewayHost ?? '127.0.0.1'}:${health.gatewayPort ?? 0}`
          : 'No route-specific rows returned by the daemon; showing connected health context only.'
      }
    ];
    return <DataTable rows={rows} sourceLabel={`live daemon health for ${label}`} />;
  }

  const fx = routeFixture(route, label);
  return <DataTable rows={fx.rows} sourceLabel="fixture transcript" />;
}
