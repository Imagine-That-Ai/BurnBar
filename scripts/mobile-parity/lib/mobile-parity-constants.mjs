export const REGISTRY_ID = 'openburnbar-mobile-capability-registry-v1';
export const ROUTE_MAP_ID = 'openburnbar-mobile-route-map-v1';
export const OWNERSHIP_MAP_ID = 'openburnbar-mobile-ownership-map-v1';
export const EVIDENCE_SCHEMA_ID = 'openburnbar-mobile-evidence-schema-v1';
export const NON_GOALS_ID = 'openburnbar-mobile-accepted-non-goals-v1';
export const LEDGER_ID = 'openburnbar-mobile-parity-ledger-v1';

export const REGISTRY_PATH = 'docs/mobile-parity/mobile-capability-registry.json';
export const ROUTE_MAP_PATH = 'docs/mobile-parity/mobile-route-map.json';
export const OWNERSHIP_MAP_PATH = 'docs/mobile-parity/mobile-ownership-map.json';
export const EVIDENCE_SCHEMA_PATH = 'docs/mobile-parity/mobile-evidence-schema.json';
export const NON_GOALS_PATH = 'docs/mobile-parity/accepted-non-goals.json';
export const LEDGER_PATH = 'docs/mobile-parity/mobile-parity-ledger.json';
export const LEDGER_MARKDOWN_PATH = 'docs/mobile-parity/mobile-parity-ledger.md';
export const PLAN_PATH = 'docs/mobile-parity/FULL_MOBILE_PARITY_REMEDIATION_PLAN.md';

export const ACTORS = [
  'signed-out user',
  'signed-in user',
  'paired phone',
  'Mac operator',
  'system'
];

export const CAPABILITY_STATUSES = [
  'unmapped',
  'implemented',
  'validated',
  'rebind-required',
  'blocked',
  'accepted-divergence'
];

export const LEDGER_STATES = [
  'fresh',
  'historical',
  'rebind-required',
  'blocked',
  'accepted-divergence'
];

export const EVIDENCE_FRESHNESS = [
  'fresh',
  'historical',
  'stale',
  'rebind-required',
  'blocked'
];

export const ENTITLEMENTS = ['none', 'Free', 'Cloud', 'Pro', 'Ultra'];

export const SECURITY_BOUNDARIES = [
  'none',
  'auth',
  'App Check',
  'device trust',
  'encryption',
  'approval'
];

export const EVIDENCE_FLOORS = [
  'unit',
  'integration',
  'simulator',
  'physical device',
  'store/provider'
];

export const CAPABILITY_STATES = [
  'loading',
  'ready',
  'empty',
  'offline',
  'denied',
  'expired',
  'retry',
  'cancel',
  'recovery'
];

export const CAPABILITY_KINDS = ['capability', 'accepted-divergence', 'non-goal'];

export const ROUTING_CLASSES = [
  'primary',
  'secondary',
  'gated',
  'deep-linkable',
  'platform-specific',
  'none'
];

export const VAL_IDS = Array.from({ length: 15 }, (_, index) =>
  `VAL-MOB-${String(index + 1).padStart(3, '0')}`
);

export const REQUIRED_CAPABILITY_FIELDS = [
  'capabilityId',
  'title',
  'family',
  'kind',
  'actor',
  'sourceSurface',
  'iosSurface',
  'androidSurface',
  'sharedContract',
  'states',
  'entitlement',
  'securityBoundary',
  'evidenceFloor',
  'status',
  'owner',
  'routing',
  'widgets',
  'intents',
  'pushRoutes',
  'backgroundJobs',
  'crossDeviceSideEffects',
  'routeIds'
];

export const REQUIRED_SURFACE_FIELDS = ['views', 'stores', 'services', 'tests'];

export const REQUIRED_OWNER_FIELDS = ['implementation', 'validation'];

export const REQUIRED_ROUTING_FIELDS = [
  'class',
  'primary',
  'secondary',
  'gated',
  'deepLinkable',
  'platformSpecific'
];

export const REQUIRED_LEDGER_ROW_FIELDS = [
  'id',
  'kind',
  'status',
  'evidenceFreshness',
  'evidenceFloor',
  'owner',
  'promotionCriterion',
  'notes'
];

export const PLACEHOLDER_EVIDENCE = [
  /^\s*$/u,
  /\bTODO\b/iu,
  /\bTBD\b/iu,
  /\bPLACEHOLDER\b/iu,
  /\blorem ipsum\b/iu,
  /\bxxx+\b/iu,
  /\breplace me\b/iu,
  /\binsert (proof|evidence|screenshot)\b/iu
];

export const CLOSING_CAPABILITY_STATUSES = new Set(['validated']);
export const CLOSING_LEDGER_STATES = new Set(['fresh']);
export const PROMOTION_BLOCKING_STATUSES = new Set([
  'unmapped',
  'blocked',
  'rebind-required'
]);
export const STALE_FRESHNESS = new Set(['historical', 'stale', 'rebind-required']);
