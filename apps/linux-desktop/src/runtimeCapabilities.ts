export const RUNTIME_CAPABILITY_IDS = [
  'usage.read',
  'database.read',
  'providers.configure',
  'projects.read',
  'missions.manage',
  'sessions.read',
  'chat.gateway',
  'memory.review',
  'computer-use.browser',
  'computer-use.system',
  'media.mercury',
  'smarthub.control',
  'settings.read',
  'account.read',
  'cloud.app-check',
  'updates.check',
  'updates.install',
  'support.export',
  'onboarding.repair',
  'pet.overlay',
  'text-expansion.in-app',
  'text-expansion.system',
  'secrets.secret-service',
  'secrets.kwallet',
  'portal.desktop',
  'native.tray',
  'native.notifications',
  'native.external-billing'
] as const;

export type RuntimeCapabilityID = (typeof RUNTIME_CAPABILITY_IDS)[number];
export type RuntimeCapabilityDomain = 'product' | 'platform' | 'security' | 'delivery';
export type RuntimeCapabilityState = 'available' | 'degraded' | 'unavailable' | 'blocked';

export type RuntimeCapabilityEntry = {
  id: RuntimeCapabilityID;
  domain: RuntimeCapabilityDomain;
  state: RuntimeCapabilityState;
  reason: string;
  substitute: string | null;
  source: string;
};

export type RuntimeCapabilityManifest = {
  schemaVersion: 1;
  catalogVersion: string;
  shellVersion: string;
  daemonVersion: string | null;
  daemonProtocolVersion: number | null;
  sessionType: string | null;
  desktop: string | null;
  capabilities: RuntimeCapabilityEntry[];
};

const CAPABILITY_ID_SET = new Set<string>(RUNTIME_CAPABILITY_IDS);
const DOMAINS = new Set<RuntimeCapabilityDomain>(['product', 'platform', 'security', 'delivery']);
const STATES = new Set<RuntimeCapabilityState>(['available', 'degraded', 'unavailable', 'blocked']);

function objectValue(value: unknown, label: string): Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`runtime_capability_manifest_invalid:${label}`);
  }
  return value as Record<string, unknown>;
}

function requiredString(value: unknown, label: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new Error(`runtime_capability_manifest_invalid:${label}`);
  }
  return value;
}

function nullableString(value: unknown, label: string): string | null {
  if (value === null || value === undefined) return null;
  return requiredString(value, label);
}

function decodeEntry(value: unknown, index: number): RuntimeCapabilityEntry {
  const entry = objectValue(value, `capabilities[${index}]`);
  const id = requiredString(entry.id, `capabilities[${index}].id`);
  if (!CAPABILITY_ID_SET.has(id)) {
    throw new Error(`runtime_capability_manifest_unknown_id:${id}`);
  }
  const domain = requiredString(entry.domain, `capabilities[${index}].domain`);
  if (!DOMAINS.has(domain as RuntimeCapabilityDomain)) {
    throw new Error(`runtime_capability_manifest_invalid_domain:${domain}`);
  }
  const state = requiredString(entry.state, `capabilities[${index}].state`);
  if (!STATES.has(state as RuntimeCapabilityState)) {
    throw new Error(`runtime_capability_manifest_invalid_state:${state}`);
  }
  return {
    id: id as RuntimeCapabilityID,
    domain: domain as RuntimeCapabilityDomain,
    state: state as RuntimeCapabilityState,
    reason: requiredString(entry.reason, `capabilities[${index}].reason`),
    substitute: nullableString(entry.substitute, `capabilities[${index}].substitute`),
    source: requiredString(entry.source, `capabilities[${index}].source`)
  };
}

export function decodeRuntimeCapabilityManifest(value: unknown): RuntimeCapabilityManifest {
  const manifest = objectValue(value, 'root');
  if (manifest.schemaVersion !== 1) {
    throw new Error('runtime_capability_manifest_unsupported_schema');
  }
  if (!Array.isArray(manifest.capabilities)) {
    throw new Error('runtime_capability_manifest_invalid:capabilities');
  }
  const capabilities = manifest.capabilities.map(decodeEntry);
  const observed = new Set(capabilities.map((entry) => entry.id));
  if (observed.size !== capabilities.length) {
    throw new Error('runtime_capability_manifest_duplicate_id');
  }
  const missing = RUNTIME_CAPABILITY_IDS.filter((id) => !observed.has(id));
  if (missing.length > 0) {
    throw new Error(`runtime_capability_manifest_missing_ids:${missing.join(',')}`);
  }
  const daemonProtocolVersion = manifest.daemonProtocolVersion;
  if (
    daemonProtocolVersion !== null &&
    daemonProtocolVersion !== undefined &&
    (!Number.isInteger(daemonProtocolVersion) || Number(daemonProtocolVersion) < 1)
  ) {
    throw new Error('runtime_capability_manifest_invalid:daemonProtocolVersion');
  }
  return {
    schemaVersion: 1,
    catalogVersion: requiredString(manifest.catalogVersion, 'catalogVersion'),
    shellVersion: requiredString(manifest.shellVersion, 'shellVersion'),
    daemonVersion: nullableString(manifest.daemonVersion, 'daemonVersion'),
    daemonProtocolVersion:
      daemonProtocolVersion === null || daemonProtocolVersion === undefined
        ? null
        : Number(daemonProtocolVersion),
    sessionType: nullableString(manifest.sessionType, 'sessionType'),
    desktop: nullableString(manifest.desktop, 'desktop'),
    capabilities
  };
}

export function findRuntimeCapability(
  manifest: RuntimeCapabilityManifest,
  id: RuntimeCapabilityID
): RuntimeCapabilityEntry | null {
  return manifest.capabilities.find((entry) => entry.id === id) ?? null;
}

export function capabilityBlocksSurface(entry: RuntimeCapabilityEntry): boolean {
  return entry.state === 'unavailable' || entry.state === 'blocked';
}
