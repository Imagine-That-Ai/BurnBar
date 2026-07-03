import type { DaemonHealth } from './daemonClient.js';

export type DaemonRouteFixture = {
  route: string;
  label: string;
  rows: { id: string; title: string; detail: string }[];
  source: 'fixture' | 'live';
};

export type DaemonRouteOracle = {
  route: string;
  label: string;
  source: 'daemon-health' | 'honest-degraded';
  rows: { id: string; title: string; detail: string }[];
  degradedReason?: string;
};

const FIXTURE_ROWS: Record<string, DaemonRouteFixture['rows']> = {
  overview: [
    { id: 'run-1', title: 'Last ingest', detail: 'OpenCode session parser checkpoint ok (fixture)' },
    { id: 'run-2', title: 'Active missions', detail: '1 controller summary pending approval (fixture)' }
  ],
  missions: [{ id: 'm-42', title: 'mission-001', detail: 'Linux port — W06 shell UX lane (fixture)' }],
  activity: [{ id: 'log-9', title: 'Parser tail', detail: 'No live socket — showing transcript-backed fixture rows.' }],
  chat: [{ id: 'thread-7', title: 'Hermes', detail: 'Thread list requires live daemon; fixture shows placeholder thread.' }],
  insights: [{ id: 'ins-1', title: 'Weekly tokens', detail: 'Fixture aggregate until W04 ingest is wired.' }],
  database: [{ id: 'db-1', title: 'SQLCipher', detail: 'Fixture: sealed local store path from linuxPaths.' }],
  providers: [{ id: 'p-1', title: 'Anthropic', detail: 'Fixture catalog row — connect live peer for credentials.' }],
  projects: [{ id: 'pr-1', title: 'BurnBar', detail: 'Fixture workspace scope.' }],
  memory: [{ id: 'mem-1', title: 'Recall boundary', detail: 'Fixture memory slice.' }]
};

export function fixtureDaemonHealth(socketPath: string): DaemonHealth {
  return {
    ok: true,
    protocolVersion: 1,
    daemonVersion: 'fixture-0.1.0',
    socketPath,
    gatewayEnabled: false,
    gatewayHost: '127.0.0.1',
    gatewayPort: 0
  };
}

export function isDaemonFixtureMode(): boolean {
  if (typeof window === 'undefined') return false;
  const params = new URLSearchParams(window.location.search);
  if (params.get('daemonFixture') === '1') return true;
  try {
    return localStorage.getItem('openburnbar.linux.daemonFixture') === '1';
  } catch {
    return false;
  }
}

export function setDaemonFixtureMode(enabled: boolean): void {
  localStorage.setItem('openburnbar.linux.daemonFixture', enabled ? '1' : '0');
}

export function routeFixture(route: string, label: string): DaemonRouteFixture {
  return {
    route,
    label,
    rows: FIXTURE_ROWS[route] ?? [
      {
        id: 'empty',
        title: 'No fixture rows',
        detail: 'Route registered; live daemon required for production data.'
      }
    ],
    source: 'fixture'
  };
}

export function buildDaemonRouteTranscript(routes: string[], health: DaemonHealth): DaemonRouteOracle[] {
  return routes.map((route) => {
    if (!health.ok) {
      return {
        route,
        label: route,
        source: 'honest-degraded',
        rows: [],
        degradedReason: health.error ?? 'Daemon unavailable; route shows an empty/degraded state instead of mock data.'
      };
    }

    return {
      route,
      label: route,
      source: 'daemon-health',
      rows: [
        {
          id: 'daemon-version',
          title: 'Daemon version',
          detail: `${health.daemonVersion ?? 'unknown'} / protocol ${health.protocolVersion ?? 'unknown'}`
        },
        {
          id: 'socket-path',
          title: 'AF_UNIX socket',
          detail: health.socketPath ?? 'Socket path unavailable'
        },
        {
          id: 'gateway-status',
          title: 'Gateway',
          detail: health.gatewayEnabled ? `${health.gatewayHost ?? '127.0.0.1'}:${health.gatewayPort ?? 0}` : 'disabled'
        }
      ]
    };
  });
}
