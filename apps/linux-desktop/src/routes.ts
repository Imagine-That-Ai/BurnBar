import type { RuntimeCapabilityID } from './runtimeCapabilities.js';

export type ShellRoute =
  | 'overview'
  | 'insights'
  | 'inbox'
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
  { id: 'inbox', label: 'Inbox', group: 'dashboard', description: 'Prioritized findings, Founder Lens replies, and accepted plans.', requiredCapability: 'sessions.read' },
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

export type InboxRouteSelection = {
  itemID: string;
};

export type ProjectRouteSelection =
  | { kind: 'project'; projectID: string }
  | { kind: 'workspace'; workspacePath: string };

export type ActivityRouteSelection =
  | { kind: 'conversation'; conversationID: string }
  | { kind: 'session'; sessionID: string };

export type ChatRouteSelection = {
  threadID: string;
};

export type ShellDestination = {
  route: ShellRoute;
  hash: string;
};

const ROUTE_DETAIL_MAX_LENGTH = 256;
const SESSION_ROUTE_DETAIL_MAX_LENGTH = 512;
const WORKSPACE_ROUTE_DETAIL_MAX_LENGTH = 4096;

function utf8Length(value: string): number {
  return new TextEncoder().encode(value).length;
}

function hasInvalidRouteCharacter(value: string): boolean {
  return Array.from(value).some((character) => {
    const codePoint = character.codePointAt(0) ?? 0;
    return codePoint <= 0x1f
      || (codePoint >= 0x7f && codePoint <= 0x9f)
      || codePoint === 0xfffd;
  });
}

function validOpaqueRouteDetail(value: string | null, maxBytes = ROUTE_DETAIL_MAX_LENGTH): value is string {
  return Boolean(
    value
      && value === value.trim()
      && !hasInvalidRouteCharacter(value)
      && utf8Length(value) <= maxBytes
  );
}

function exactRouteParams(
  hash: string,
  route: ShellRoute,
  allowedKeys: readonly string[]
): URLSearchParams | null {
  const decoded = decodedHashPath(hash);
  const queryIndex = decoded.indexOf('?');
  if (queryIndex < 0 || decoded.slice(0, queryIndex) !== route) return null;
  const params = new URLSearchParams(decoded.slice(queryIndex + 1));
  const keys = Array.from(params.keys());
  if (keys.length === 0 || keys.some((key) => !allowedKeys.includes(key))) return null;
  if (allowedKeys.some((key) => params.getAll(key).length > 1)) return null;
  return params;
}

function requireOpaqueRouteDetail(value: string, label: string, maxBytes = ROUTE_DETAIL_MAX_LENGTH): string {
  if (!validOpaqueRouteDetail(value, maxBytes)) {
    throw new Error(`${label} is invalid or too long.`);
  }
  return value;
}

function validWorkspacePath(value: string | null): value is string {
  if (!validOpaqueRouteDetail(value, WORKSPACE_ROUTE_DETAIL_MAX_LENGTH) || !value.startsWith('/')) {
    return false;
  }
  return !value.split('/').some((segment) => segment === '.' || segment === '..');
}

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
  const candidate = value;
  if (!candidate || candidate !== candidate.trim() || candidate.includes('#')) return null;
  const hash = `#/${candidate}`;
  const routeName = decodedHashPath(hash).split('?', 1)[0];
  const route = ROUTES.find((entry) => entry.id === routeName)?.id;
  if (!route) return null;
  if (!candidate.includes('?')) return { route, hash };
  if (route === 'providers' && providerSelectionFromHash(hash) !== null) return { route, hash };
  if (route === 'inbox' && inboxSelectionFromHash(hash) !== null) return { route, hash };
  if (route === 'projects' && projectSelectionFromHash(hash) !== null) return { route, hash };
  if (route === 'activity' && activitySelectionFromHash(hash) !== null) return { route, hash };
  if (route === 'chat' && chatSelectionFromHash(hash) !== null) return { route, hash };
  return null;
}

/** Read the bounded provider/model detail encoded in a reload-safe shell hash. */
export function providerSelectionFromHash(hash: string): ProviderRouteSelection | null {
  const params = exactRouteParams(hash, 'providers', ['provider', 'model']);
  if (!params || params.getAll('provider').length !== 1) return null;
  const providerID = params.get('provider');
  const rawModelID = params.get('model');
  if (!validOpaqueRouteDetail(providerID)) return null;
  if (rawModelID !== null && !validOpaqueRouteDetail(rawModelID)) return null;
  const modelID = rawModelID ?? null;
  return { providerID, modelID };
}

/** Serialize provider/model detail without allowing it to escape the hash route. */
export function providerRouteHash(providerID: string, modelID?: string | null): string {
  const params = new URLSearchParams({
    provider: requireOpaqueRouteDetail(providerID, 'Provider id')
  });
  if (modelID !== undefined && modelID !== null) {
    params.set('model', requireOpaqueRouteDetail(modelID, 'Model id'));
  }
  return `#/providers?${params.toString()}`;
}

/** Read the bounded AI Inbox item detail encoded in a reload-safe shell hash. */
export function inboxSelectionFromHash(hash: string): InboxRouteSelection | null {
  const params = exactRouteParams(hash, 'inbox', ['item']);
  if (!params || params.getAll('item').length !== 1) return null;
  const itemID = params.get('item');
  if (!validOpaqueRouteDetail(itemID)) return null;
  return { itemID };
}

/** Serialize an AI Inbox detail destination without allowing it to escape the hash route. */
export function inboxRouteHash(itemID?: string | null): string {
  if (itemID === undefined || itemID === null) return '#/inbox';
  const item = requireOpaqueRouteDetail(itemID, 'Inbox item id');
  return `#/inbox?${new URLSearchParams({ item }).toString()}`;
}

/** Read an exact controller project or daemon workspace target. */
export function projectSelectionFromHash(hash: string): ProjectRouteSelection | null {
  const params = exactRouteParams(hash, 'projects', ['project', 'workspace']);
  if (!params) return null;
  const projectValues = params.getAll('project');
  const workspaceValues = params.getAll('workspace');
  if (projectValues.length + workspaceValues.length !== 1) return null;
  if (projectValues.length === 1) {
    const projectID = projectValues[0] ?? null;
    return validOpaqueRouteDetail(projectID) ? { kind: 'project', projectID } : null;
  }
  const workspacePath = workspaceValues[0] ?? null;
  return validWorkspacePath(workspacePath) ? { kind: 'workspace', workspacePath } : null;
}

export function projectRouteHash(projectID: string): string {
  const project = requireOpaqueRouteDetail(projectID, 'Project id');
  return `#/projects?${new URLSearchParams({ project }).toString()}`;
}

export function projectWorkspaceRouteHash(workspacePath: string): string {
  if (!validWorkspacePath(workspacePath)) {
    throw new Error('Workspace path must be an absolute, normalized Linux path within the route size limit.');
  }
  return `#/projects?${new URLSearchParams({ workspace: workspacePath }).toString()}`;
}

/** Read an exact canonical conversation or session target. */
export function activitySelectionFromHash(hash: string): ActivityRouteSelection | null {
  const params = exactRouteParams(hash, 'activity', ['conversation', 'session']);
  if (!params) return null;
  const conversationValues = params.getAll('conversation');
  const sessionValues = params.getAll('session');
  if (conversationValues.length + sessionValues.length !== 1) return null;
  if (conversationValues.length === 1) {
    const conversationID = conversationValues[0] ?? null;
    return validOpaqueRouteDetail(conversationID, SESSION_ROUTE_DETAIL_MAX_LENGTH)
      ? { kind: 'conversation', conversationID }
      : null;
  }
  const sessionID = sessionValues[0] ?? null;
  return validOpaqueRouteDetail(sessionID, SESSION_ROUTE_DETAIL_MAX_LENGTH)
    ? { kind: 'session', sessionID }
    : null;
}

export function activityConversationRouteHash(conversationID: string): string {
  const conversation = requireOpaqueRouteDetail(
    conversationID,
    'Conversation id',
    SESSION_ROUTE_DETAIL_MAX_LENGTH
  );
  return `#/activity?${new URLSearchParams({ conversation }).toString()}`;
}

export function activitySessionRouteHash(sessionID: string): string {
  const session = requireOpaqueRouteDetail(sessionID, 'Session id', SESSION_ROUTE_DETAIL_MAX_LENGTH);
  return `#/activity?${new URLSearchParams({ session }).toString()}`;
}

/** Read an exact durable chat-thread target. */
export function chatSelectionFromHash(hash: string): ChatRouteSelection | null {
  const params = exactRouteParams(hash, 'chat', ['thread']);
  if (!params || params.getAll('thread').length !== 1) return null;
  const threadID = params.get('thread');
  return validOpaqueRouteDetail(threadID) ? { threadID } : null;
}

export function chatRouteHash(threadID: string): string {
  const thread = requireOpaqueRouteDetail(threadID, 'Chat thread id');
  return `#/chat?${new URLSearchParams({ thread }).toString()}`;
}
