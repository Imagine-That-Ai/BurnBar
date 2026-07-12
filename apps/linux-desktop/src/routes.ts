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
  { id: 'text-expansion', label: 'Text expansion', group: 'system', description: 'In-app snippet expansion (v1); system-wide Wayland deferred.', requiredCapability: 'text-expansion.in-app' }
];

export function routeFromHash(hash: string): ShellRoute {
  let source = hash;
  try {
    if (hash.includes('://')) source = new URL(hash).hash;
  } catch {
    source = hash;
  }
  const raw = source.replace(/^#\/?/, '').trim() || 'overview';
  const found = ROUTES.find((r) => r.id === raw);
  return found?.id ?? 'overview';
}
