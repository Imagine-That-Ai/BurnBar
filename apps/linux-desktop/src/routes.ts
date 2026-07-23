import type { RuntimeCapabilityID } from './runtimeCapabilities.js';

export type ShellRoute =
  | 'overview'
  | 'insights'
  | 'database'
  | 'providers'
  | 'projects'
  | 'missions'
  | 'activity'
  | 'chat'
  | 'memory'
  | 'settings'
  | 'account'
  | 'updates'
  | 'support'
  | 'onboarding'
  | 'pet'
  | 'text-expansion'
  | 'computer-use'
  | 'mercury'
  | 'smarthub';

export type RouteMeta = {
  id: ShellRoute;
  label: string;
  group: 'dashboard' | 'system';
  description: string;
  requiredCapability: RuntimeCapabilityID;
};

export const ROUTES: RouteMeta[] = [
  { id: 'overview', label: 'Overview', group: 'dashboard', description: 'Local peer health and recent activity.', requiredCapability: 'usage.read' },
  { id: 'insights', label: 'Insights', group: 'dashboard', description: 'Usage and investigation surfaces backed by the daemon when available.', requiredCapability: 'usage.read' },
  { id: 'database', label: 'Database', group: 'dashboard', description: 'Encrypted local store status and migration health.', requiredCapability: 'database.read' },
  { id: 'providers', label: 'Providers & models', group: 'dashboard', description: 'Provider credentials, routing, and model catalog.', requiredCapability: 'providers.configure' },
  { id: 'projects', label: 'Projects', group: 'dashboard', description: 'Workspace projects and code memory scope.', requiredCapability: 'projects.read' },
  { id: 'missions', label: 'Missions', group: 'dashboard', description: 'Mission control approvals and controller summary.', requiredCapability: 'missions.manage' },
  { id: 'activity', label: 'Activity & logs', group: 'dashboard', description: 'Session logs and parser ingest checkpoints.', requiredCapability: 'sessions.read' },
  { id: 'chat', label: 'Chat / Hermes', group: 'dashboard', description: 'Hermes chat threads and tool approvals.', requiredCapability: 'chat.gateway' },
  { id: 'memory', label: 'Memory', group: 'dashboard', description: 'Project memory review and recall boundaries.', requiredCapability: 'memory.review' },
  { id: 'computer-use', label: 'Computer Use', group: 'dashboard', description: 'Approval-gated browser/system automation, panic, and audit.', requiredCapability: 'computer-use.browser' },
  { id: 'mercury', label: 'Mercury', group: 'dashboard', description: 'Pair/call/mirror media via iroh when capability is present.', requiredCapability: 'media.mercury' },
  { id: 'smarthub', label: 'SmartHub / IoT', group: 'dashboard', description: 'Device control through openburnbar-cli devices iot.', requiredCapability: 'smarthub.control' },
  { id: 'settings', label: 'Settings', group: 'system', description: 'Linux paths, Secret Service, telemetry, and privacy.', requiredCapability: 'settings.read' },
  { id: 'account', label: 'Account & sync', group: 'system', description: 'Lower-trust cloud identity and encrypted sync posture.', requiredCapability: 'account.read' },
  { id: 'updates', label: 'Updates', group: 'system', description: 'Verified package channel and restart guidance.', requiredCapability: 'updates.check' },
  { id: 'support', label: 'Support & diagnostics', group: 'system', description: 'Redacted diagnostics export and reconnect tools.', requiredCapability: 'support.export' },
  { id: 'onboarding', label: 'First-run setup', group: 'system', description: 'Linux onboarding wizard (daemon, secrets, DE limits).', requiredCapability: 'onboarding.repair' },
  { id: 'pet', label: 'Pet companion', group: 'system', description: 'Overlay tier matrix and degraded draggable mode.', requiredCapability: 'pet.overlay' },
  { id: 'text-expansion', label: 'Text expansion', group: 'system', description: 'In-app snippets plus an optional signed IBus engine when the daemon reports it.', requiredCapability: 'text-expansion.in-app' }
];

export type ProviderRouteSelection = {
  providerID: string;
  modelID: string | null;
};

export type ShellDestination = {
  route: ShellRoute;
  hash: string;
};

const ROUTE_DETAIL_MAX_LENGTH = 256;

function decodedHashPath(hash: string): string {
  let source = hash;
  try {
    if (hash.includes('://')) source = new URL(hash).hash;
  } catch {
    source = hash;
  }
  return source.replace(/^#\/?/, '').trim();
}

export function routeFromHash(hash: string): ShellRoute {
  const raw = decodedHashPath(hash).split('?', 1)[0] || 'overview';
  const found = ROUTES.find((r) => r.id === raw);
  return found?.id ?? 'overview';
}

/** Validate a native route destination before allowing it to mutate renderer navigation. */
export function shellDestinationFromNative(value: string): ShellDestination | null {
  const candidate = value.trim();
  if (!candidate || candidate.includes('#')) return null;
  const hash = `#/${candidate}`;
  const routeName = decodedHashPath(hash).split('?', 1)[0];
  const route = ROUTES.find((entry) => entry.id === routeName)?.id;
  if (!route) return null;
  if (!candidate.includes('?')) return { route, hash };
  if (route !== 'providers' || providerSelectionFromHash(hash) === null) return null;
  return { route, hash };
}

/** Read the bounded provider/model detail encoded in a reload-safe shell hash. */
export function providerSelectionFromHash(hash: string): ProviderRouteSelection | null {
  const decoded = decodedHashPath(hash);
  const queryIndex = decoded.indexOf('?');
  if (queryIndex < 0 || decoded.slice(0, queryIndex) !== 'providers') return null;
  const params = new URLSearchParams(decoded.slice(queryIndex + 1));
  const providerID = params.get('provider')?.trim() ?? '';
  const modelID = params.get('model')?.trim() || null;
  if (!providerID || providerID.length > ROUTE_DETAIL_MAX_LENGTH) return null;
  if (modelID && modelID.length > ROUTE_DETAIL_MAX_LENGTH) return null;
  return { providerID, modelID };
}

/** Serialize provider/model detail without allowing it to escape the hash route. */
export function providerRouteHash(providerID: string, modelID?: string | null): string {
  const params = new URLSearchParams({ provider: providerID });
  if (modelID) params.set('model', modelID);
  return `#/providers?${params.toString()}`;
}
