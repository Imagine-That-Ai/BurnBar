import type { DaemonHealth } from './daemonClient.js';
import type {
  UsageSummary,
  ProviderCatalog,
  SessionListResult,
  UsageInsights,
  MissionListResult,
  ConfigSnapshot,
  DbStatus,
  ProjectEntry,
  MemoryBoundary,
  AccountStatus,
  MembershipStatus
} from './tauriBridge.js';
import { ENTITLEMENT_DOC_IDS } from '@openburnbar/entitlements';

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

// ─────────────────────────── P01: usage summary fixture ───────────────────────────

export function fixtureUsageSummary(): UsageSummary {
  const now = Date.now();
  const events = Array.from({ length: 8 }, (_, i) => {
    const at = new Date(now - i * 3_600_000 * (i + 1)).toISOString();
    const tokens = 12_000 + i * 3_500;
    const cost = +(tokens * 0.00003).toFixed(4);
    const providers = ['anthropic', 'openai', 'google'];
    const models = ['claude-4.5-sonnet', 'gpt-5', 'gemini-3-pro'];
    return {
      id: `fx-evt-${i}`,
      title: `${providers[i % 3]} / ${models[i % 3]}`,
      detail: `${tokens.toLocaleString('en-US')} tokens · $${cost.toFixed(2)}`,
      at
    };
  });
  return {
    todayTokens: 1_284_000,
    todayCostUsd: 2784.83,
    sevenDay: [8200, 12100, 9800, 15400, 11200, 13800, 7100],
    recentEvents: events
  };
}

// ─────────────────────────── P02: provider catalog fixture ────────────────────────

export function fixtureProviderCatalog(): ProviderCatalog {
  const ext = (row: ProviderCatalog[number] & Record<string, unknown>) => row;
  return [
    ext({
      id: 'anthropic',
      label: 'Anthropic',
      accountLabel: 'Team workspace',
      quotaSourceKind: 'officialAPI',
      quotaConfidence: 'high',
      planTierBadge: 'TEAM',
      quotaBuckets: [
        { id: 'anth-5m', label: '5h rolling', usedPct: 42, resetsAt: new Date(Date.now() + 3_600_000 * 2).toISOString(), state: 'ok' },
        { id: 'anth-daily', label: 'Daily', usedPct: 88, resetsAt: new Date(Date.now() + 3_600_000 * 8).toISOString(), state: 'cooling_down' },
        { id: 'anth-7d', label: '7-Day window', usedPct: 55, resetsAt: new Date(Date.now() + 86_400_000 * 4).toISOString(), state: 'ok' }
      ]
    }),
    ext({
      id: 'openai',
      label: 'OpenAI',
      accountLabel: 'Personal',
      quotaSourceKind: 'officialAPI',
      quotaConfidence: 'high',
      quotaBuckets: [
        { id: 'oai-monthly', label: 'Monthly', usedPct: 100, resetsAt: new Date(Date.now() + 86_400_000 * 3).toISOString(), state: 'exhausted' }
      ]
    }),
    ext({
      id: 'google',
      label: 'Google',
      accountLabel: 'Workspace',
      quotaSourceKind: 'localSession',
      quotaConfidence: 'medium',
      quotaBuckets: [
        { id: 'goog-req', label: 'Requests/min', usedPct: 0, state: 'missing_credential' }
      ]
    }),
    ext({
      id: 'cursor',
      label: 'Cursor',
      accountLabel: 'Pro',
      planTierBadge: 'PRO',
      quotaSourceKind: 'localSession',
      quotaConfidence: 'medium',
      accountStorage: 'local',
      quotaBuckets: [
        { id: 'cur-fast', label: 'Fast requests', usedPct: 65, resetsAt: new Date(Date.now() + 3_600_000 * 12).toISOString(), state: 'ok' },
        { id: 'cur-week', label: 'Weekly', usedPct: 41, resetsAt: new Date(Date.now() + 86_400_000 * 5).toISOString(), state: 'ok' }
      ]
    }),
    ext({
      id: 'codex',
      label: 'Codex',
      accountLabel: 'CLI session',
      quotaSourceKind: 'localCLI',
      quotaBuckets: [
        { id: 'cdx-5h', label: '5h', usedPct: 31, resetsAt: new Date(Date.now() + 3_600_000 * 4).toISOString(), state: 'ok' }
      ]
    }),
    ext({
      id: 'claude-code',
      label: 'Claude Code',
      accountLabel: 'Local',
      quotaSourceKind: 'localSession',
      quotaBuckets: [
        { id: 'cc-5h', label: '5h rolling', usedPct: 76, resetsAt: new Date(Date.now() + 3_600_000 * 1).toISOString(), state: 'cooling_down' },
        { id: 'cc-week', label: 'Weekly', usedPct: 22, resetsAt: new Date(Date.now() + 86_400_000 * 6).toISOString(), state: 'ok' }
      ]
    }),
    ext({
      id: 'factory',
      label: 'Factory',
      accountLabel: 'Max',
      planTierBadge: 'MAX',
      quotaBuckets: [
        { id: 'fac-day', label: 'Daily', usedPct: 12, resetsAt: new Date(Date.now() + 86_400_000).toISOString(), state: 'ok' }
      ]
    }),
    ext({
      id: 'gemini',
      label: 'Gemini',
      accountLabel: 'Cloud',
      quotaBuckets: [
        { id: 'gem-daily', label: 'Daily', usedPct: 48, resetsAt: new Date(Date.now() + 86_400_000 * 2).toISOString(), state: 'ok' }
      ]
    }),
    ext({
      id: 'deepseek',
      label: 'DeepSeek',
      accountLabel: 'API',
      quotaBuckets: [
        { id: 'ds-month', label: 'Monthly', usedPct: 19, resetsAt: new Date(Date.now() + 86_400_000 * 20).toISOString(), state: 'ok' }
      ]
    }),
    ext({
      id: 'grok',
      label: 'xAI',
      accountLabel: 'Pro',
      planTierBadge: 'PRO',
      quotaBuckets: [
        { id: 'grok-fast', label: 'Fast window', usedPct: 82, resetsAt: new Date(Date.now() + 3_600_000 * 6).toISOString(), state: 'cooling_down' }
      ]
    }),
    ext({
      id: 'opencode',
      label: 'OpenCode',
      accountLabel: 'Workspace',
      quotaBuckets: [
        { id: 'oc-week', label: '7-Day window', usedPct: 37, resetsAt: new Date(Date.now() + 86_400_000 * 3).toISOString(), state: 'ok' }
      ]
    })
  ] as ProviderCatalog;
}

// ─────────────────────────── P03: session list fixture ────────────────────────────

export function fixtureSessionList(): SessionListResult {
  const providers = ['anthropic', 'openai', 'google', 'cursor'];
  const models = ['claude-4.5-sonnet', 'gpt-5', 'gemini-3-pro', 'cursor-small'];
  const sessions = Array.from({ length: 14 }, (_, i) => ({
    id: `fx-session-${i}`,
    provider: providers[i % providers.length],
    model: models[i % models.length],
    startedAt: new Date(Date.now() - i * 7_200_000).toISOString(),
    tokens: 5_000 + i * 2_300,
    costUsd: +(0.15 + i * 0.07).toFixed(2),
    title: `Session ${i + 1} — ${['Bug fix', 'Feature', 'Refactor', 'Review', 'Docs'][i % 5]}`
  }));
  return { sessions, nextCursor: null };
}

// ─────────────────────────── P05: usage insights fixture ──────────────────────────

export function fixtureUsageInsights(): UsageInsights {
  const weekly = [
    { label: 'May 31', tokens: 420_000, costUsd: 2800 },
    { label: 'Jun 7', tokens: 510_000, costUsd: 5200 },
    { label: 'Jun 14', tokens: 480_000, costUsd: 7800 },
    { label: 'Jun 21', tokens: 520_000, costUsd: 10200 },
    { label: 'Jun 28', tokens: 540_000, costUsd: 12800 }
  ];
  return {
    weekly,
    providerMix: [
      { id: 'claude-code', label: 'Claude Code', pct: 28 },
      { id: 'codex', label: 'Codex', pct: 22 },
      { id: 'cursor', label: 'Cursor', pct: 18 },
      { id: 'anthropic', label: 'Anthropic', pct: 14 },
      { id: 'openai', label: 'OpenAI', pct: 10 },
      { id: 'google', label: 'Google', pct: 8 }
    ],
    modelMix: [
      { id: 'claude-4.5-sonnet', label: 'Claude 4.5 Sonnet', pct: 38 },
      { id: 'gpt-5', label: 'GPT-5', pct: 24 },
      { id: 'gemini-3-pro', label: 'Gemini 3 Pro', pct: 20 },
      { id: 'cursor-small', label: 'Cursor Small', pct: 18 }
    ],
    cacheHitRatePct: 34
  };
}

// ─────────────────────────── P06: mission list fixture ────────────────────────────

export function fixtureMissionList(): MissionListResult {
  const now = new Date().toISOString();
  return {
    missions: [
      { id: 'fx-mission-1', title: 'Port dashboard to Linux', state: 'active', updatedAt: now, laneCount: 3 },
      { id: 'fx-mission-2', title: 'Refactor provider routing', state: 'active', updatedAt: now, laneCount: 2 },
      { id: 'fx-mission-3', title: 'Onboarding wizard polish', state: 'blocked', updatedAt: now, laneCount: 1 },
      { id: 'fx-mission-4', title: 'Memory recall boundary audit', state: 'done', updatedAt: now, laneCount: 4 },
      { id: 'fx-mission-5', title: 'Insights observatory v1', state: 'pending', updatedAt: now, laneCount: 0 },
      { id: 'fx-mission-6', title: 'Quota pacing algorithm', state: 'cancelled', updatedAt: now, laneCount: 0 }
    ],
    pendingApprovals: [
      { id: 'fx-appr-1', missionId: 'fx-mission-1', summary: 'Deploy mission packet to production daemon', requestedAt: now, risk: 'high' },
      { id: 'fx-appr-2', missionId: 'fx-mission-2', summary: 'Switch primary provider routing to Anthropic', requestedAt: now, risk: 'standard' }
    ]
  };
}

// ─────────────────────────── P07: system fixtures ─────────────────────────────────

export function fixtureConfigSnapshot(): ConfigSnapshot {
  return {
    paths: {
      supportDir: '~/.local/share/openburnbar',
      socketPath: '~/.local/share/openburnbar/openburnbar-daemon.sock',
      configDir: '~/.config/openburnbar',
      providerLogPaths: ['~/.local/share/openburnbar/logs/anthropic', '~/.local/share/openburnbar/logs/openai']
    },
    secretServiceStatus: 'locked',
    telemetryEnabled: false,
    privacyOptIn: false
  };
}

export function fixtureDbStatus(): DbStatus {
  return { sqlcipherOk: true, migrationVersion: 7, sizeBytes: 48_234_112, walMode: true };
}

export function fixtureProjects(): ProjectEntry[] {
  return [
    { id: 'burnbar', name: 'BurnBar', path: '~/Developer/BurnBar', scope: 'workspace' },
    { id: 'openburnbar-daemon', name: 'OpenBurnBar Daemon', path: '~/Developer/BurnBar/OpenBurnBarDaemon', scope: 'workspace' },
    { id: 'linux-desktop', name: 'Linux Desktop Shell', path: '~/Developer/BurnBar/apps/linux-desktop', scope: 'subproject' }
  ];
}

export function fixtureMemoryBoundaries(): MemoryBoundary[] {
  return [
    { id: 'mem-ws', scope: 'workspace', label: 'Workspace memory', detail: 'Project-wide recall; scoped to the active repository.' },
    { id: 'mem-proj', scope: 'project:burnbar', label: 'BurnBar project', detail: 'Per-project recall boundary; no cross-project leakage.' },
    { id: 'mem-dmn', scope: 'domain:security', label: 'Security domain', detail: 'Recall restricted to security-tagged memory only.' }
  ];
}

// ─────────────────────────── P08: account status fixture ──────────────────────────

export function fixtureAccountStatus(): AccountStatus {
  return {
    signedIn: true,
    identityLabel: 'alberto@burnbar.dev',
    trustClass: 'linux-lower-trust',
    syncState: 'active',
    lastSyncAt: new Date(Date.now() - 1_800_000).toISOString()
  };
}

// ─────────────────────────── P10: membership fixtures ────────────────────────────

const MEMBERSHIP_CACHE_EVENT = 'membership.entitlement_cache.updated';
const MEMBERSHIP_CHECKOUT_URL = 'https://checkout.stripe.test/session/cs_test_openburnbar';

export type MembershipFixtureState = 'active' | 'cancelled' | 'paymentFailed' | 'offline';

export function fixtureMembershipStatus(state: MembershipFixtureState = 'active'): MembershipStatus {
  switch (state) {
    case 'active':
      return {
        tier: 'pro',
        entitlements: [ENTITLEMENT_DOC_IDS.pro, ENTITLEMENT_DOC_IDS.hostedQuotaSync],
        renewsAt: new Date(Date.now() + 86_400_000 * 21).toISOString(),
        restoreAvailable: true,
        state: 'active',
        cacheEvent: MEMBERSHIP_CACHE_EVENT
      };
    case 'cancelled':
      return {
        tier: 'free',
        entitlements: [],
        renewsAt: undefined,
        restoreAvailable: true,
        state: 'cancelled',
        cacheEvent: MEMBERSHIP_CACHE_EVENT
      };
    case 'paymentFailed':
      return {
        tier: 'free',
        entitlements: [],
        restoreAvailable: true,
        state: 'paymentFailed',
        cacheEvent: MEMBERSHIP_CACHE_EVENT
      };
    case 'offline':
      return {
        tier: 'free',
        entitlements: [],
        restoreAvailable: false,
        state: 'offline',
        cacheEvent: MEMBERSHIP_CACHE_EVENT
      };
  }
}

export function fixtureMembershipCheckoutUrl(): string {
  return MEMBERSHIP_CHECKOUT_URL;
}
