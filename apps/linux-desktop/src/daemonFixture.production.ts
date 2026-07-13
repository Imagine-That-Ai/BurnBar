import type { DaemonHealth } from './daemonClient.js';
import type {
  AccountStatus,
  ConfigSnapshot,
  DatabaseIndexActionResult,
  DatabaseCodeSearchRequest,
  DatabaseCodeSearchResult,
  DatabaseCodeContextPackRequest,
  DatabaseCodeContextPackResult,
  DatabaseWorkspaceStatus,
  DbStatus,
  IntegrationsStatus,
  MembershipStatus,
  MemoryBoundary,
  MemoryReviewInbox,
  MercuryMediaStatus,
  MissionListResult,
  NotificationConfig,
  NotificationHealth,
  ProjectEntry,
  ProviderCatalog,
  ProxyRouteLogEntry,
  SessionListResult,
  UsageInsights,
  UsageSummary
} from './tauriBridge.js';

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

export type MembershipFixtureState = 'active' | 'cancelled' | 'paymentFailed' | 'offline';

export const DAEMON_FIXTURE_AVAILABLE = false;

export function fixtureActivationAllowed(input: { development: boolean; explicitlyEnabled: boolean }): boolean {
  return input.development || input.explicitlyEnabled;
}

function unavailable(): never {
  throw new Error('Development data is unavailable in production.');
}

export function isDaemonFixtureMode(): boolean { return false; }
export function setDaemonFixtureMode(_enabled: boolean): void {}
export function fixtureDaemonHealth(_socketPath: string): DaemonHealth { return unavailable(); }
export function fixtureIntegrationsStatus(): IntegrationsStatus { return unavailable(); }
export function fixtureMercuryMediaStatus(_options?: { rich?: boolean }): MercuryMediaStatus { return unavailable(); }
export function routeFixture(_route: string, _label: string): DaemonRouteFixture { return unavailable(); }
export function buildDaemonRouteTranscript(_routes: string[], _health: DaemonHealth): DaemonRouteOracle[] { return unavailable(); }
export function fixtureUsageSummary(): UsageSummary { return unavailable(); }
export function fixtureProviderCatalog(): ProviderCatalog { return unavailable(); }
export function fixtureMemoryReviewInbox(): MemoryReviewInbox { return unavailable(); }
export function fixtureDatabaseWorkspaceStatus(): DatabaseWorkspaceStatus { return unavailable(); }
export function fixtureDatabaseIndexAction(_kind: 'index' | 'watch'): DatabaseIndexActionResult { return unavailable(); }
export function fixtureDatabaseCodeSearch(_request: DatabaseCodeSearchRequest): DatabaseCodeSearchResult { return unavailable(); }
export function fixtureDatabaseCodeContextPack(_request: DatabaseCodeContextPackRequest): DatabaseCodeContextPackResult { return unavailable(); }
export function fixtureSessionList(): SessionListResult { return unavailable(); }
export function fixtureUsageInsights(): UsageInsights { return unavailable(); }
export function fixtureMissionList(): MissionListResult { return unavailable(); }
export function fixtureConfigSnapshot(): ConfigSnapshot { return unavailable(); }
export function fixtureDbStatus(): DbStatus { return unavailable(); }
export function fixtureProjects(): ProjectEntry[] { return unavailable(); }
export function fixtureMemoryBoundaries(): MemoryBoundary[] { return unavailable(); }
export function fixtureAccountStatus(): AccountStatus { return unavailable(); }
export function fixtureProxyRouteLog(): ProxyRouteLogEntry[] { return unavailable(); }
export function fixtureNotificationConfig(): NotificationConfig { return unavailable(); }
export function fixtureNotificationHealth(): NotificationHealth { return unavailable(); }
export function fixtureMembershipStatus(_state: MembershipFixtureState = 'active'): MembershipStatus { return unavailable(); }
export function fixtureMembershipCheckoutUrl(): string { return unavailable(); }
