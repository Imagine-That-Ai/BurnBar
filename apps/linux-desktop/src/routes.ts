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
  | 'text-expansion';

export type RouteMeta = {
  id: ShellRoute;
  label: string;
  group: 'dashboard' | 'system';
  description: string;
};

export const ROUTES: RouteMeta[] = [
  { id: 'overview', label: 'Overview', group: 'dashboard', description: 'Local peer health and recent activity.' },
  { id: 'insights', label: 'Insights', group: 'dashboard', description: 'Usage and investigation surfaces backed by the daemon when available.' },
  { id: 'database', label: 'Database', group: 'dashboard', description: 'Encrypted local store status and migration health.' },
  { id: 'providers', label: 'Providers & models', group: 'dashboard', description: 'Provider credentials, routing, and model catalog.' },
  { id: 'projects', label: 'Projects', group: 'dashboard', description: 'Workspace projects and code memory scope.' },
  { id: 'missions', label: 'Missions', group: 'dashboard', description: 'Mission control approvals and controller summary.' },
  { id: 'activity', label: 'Activity & logs', group: 'dashboard', description: 'Session logs and parser ingest checkpoints.' },
  { id: 'chat', label: 'Chat / Hermes', group: 'dashboard', description: 'Hermes chat threads and tool approvals.' },
  { id: 'memory', label: 'Memory', group: 'dashboard', description: 'Project memory review and recall boundaries.' },
  { id: 'settings', label: 'Settings', group: 'system', description: 'Linux paths, Secret Service, telemetry, and privacy.' },
  { id: 'account', label: 'Account & sync', group: 'system', description: 'Lower-trust cloud identity and encrypted sync posture.' },
  { id: 'updates', label: 'Updates', group: 'system', description: 'Package channel and restart guidance.' },
  { id: 'support', label: 'Support & diagnostics', group: 'system', description: 'Redacted diagnostics export and reconnect tools.' },
  { id: 'onboarding', label: 'First-run setup', group: 'system', description: 'Linux onboarding wizard (daemon, secrets, DE limits).' },
  { id: 'pet', label: 'Pet companion', group: 'system', description: 'Overlay tier matrix and degraded draggable mode.' },
  { id: 'text-expansion', label: 'Text expansion', group: 'system', description: 'In-app snippet expansion (v1); system-wide Wayland deferred.' }
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
