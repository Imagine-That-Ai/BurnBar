import crypto from 'node:crypto';
import fs from 'node:fs';
import { candidateCloseRefusal } from './candidate-fingerprint.mjs';
import { isObject, looksLikePlaceholder } from './check-support.mjs';
import {
  ACTORS,
  CAPABILITY_KINDS,
  CAPABILITY_STATES,
  CAPABILITY_STATUSES,
  CLOSING_CAPABILITY_STATUSES,
  CLOSING_LEDGER_STATES,
  ENTITLEMENTS,
  EVIDENCE_FLOORS,
  EVIDENCE_FRESHNESS,
  EVIDENCE_SCHEMA_ID,
  EVIDENCE_SCHEMA_PATH,
  LEDGER_ID,
  LEDGER_PATH,
  LEDGER_STATES,
  NON_GOALS_ID,
  NON_GOALS_PATH,
  OWNERSHIP_MAP_ID,
  OWNERSHIP_MAP_PATH,
  PLAN_PATH,
  PROMOTION_BLOCKING_STATUSES,
  REGISTRY_ID,
  REGISTRY_PATH,
  REQUIRED_CAPABILITY_FIELDS,
  REQUIRED_LEDGER_ROW_FIELDS,
  REQUIRED_OWNER_FIELDS,
  REQUIRED_ROUTING_FIELDS,
  REQUIRED_SURFACE_FIELDS,
  ROUTE_MAP_ID,
  ROUTE_MAP_PATH,
  ROUTING_CLASSES,
  SECURITY_BOUNDARIES,
  STALE_FRESHNESS,
  VAL_IDS
} from './mobile-parity-constants.mjs';
import { resolveConfinedPath } from './path-confine.mjs';

const HEAD_PATTERN = /^[a-f0-9]{40,64}$/u;
const SHA256_PATTERN = /^[a-f0-9]{64}$/u;

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function sha256File(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function uniqueStrings(values) {
  return Array.isArray(values) && values.every((value) => typeof value === 'string')
    && new Set(values).size === values.length;
}

function surfacePaths(surface) {
  if (!isObject(surface)) return [];
  const keys = ['views', 'stores', 'services', 'tests', 'ipad'];
  return keys.flatMap((key) => (Array.isArray(surface[key]) ? surface[key] : []));
}

function isRoutable(capability) {
  const routing = capability?.routing;
  if (!isObject(routing)) return false;
  if (capability.kind !== 'capability') return false;
  return routing.primary === true
    || routing.secondary === true
    || routing.deepLinkable === true
    || (Array.isArray(capability.routeIds) && capability.routeIds.length > 0);
}

function evidenceAllowsValidated(evidence, fingerprint) {
  if (!isObject(evidence)) return false;
  const candidate = evidence.candidate ?? evidence;
  if (!HEAD_PATTERN.test(candidate.commitSha ?? '')) return false;
  if (candidate.dirty === true || (candidate.dirtyEntries?.length ?? 0) > 0) return false;
  const refusal = candidateCloseRefusal({
    commitSha: candidate.commitSha,
    dirty: false,
    dirtyEntries: []
  });
  if (refusal) return false;
  if (fingerprint) {
    const printRefusal = candidateCloseRefusal(fingerprint);
    if (printRefusal) return false;
  }
  return true;
}

function rowCloses(row) {
  return CLOSING_CAPABILITY_STATUSES.has(row.status)
    || CLOSING_LEDGER_STATES.has(row.status)
    || CLOSING_LEDGER_STATES.has(row.evidenceFreshness)
    || row.result === 'PASS'
    || row.result === 'pass';
}

function loadJsonDocument(repoRoot, relativePath, label, fail) {
  const resolved = resolveConfinedPath(repoRoot, relativePath);
  if (resolved.error) {
    fail(`cannot resolve ${label}: ${resolved.error}`);
    return null;
  }
  if (!resolved.exists) {
    fail(`missing ${label}: ${relativePath}`);
    return null;
  }
  try {
    return JSON.parse(fs.readFileSync(resolved.path, 'utf8'));
  } catch (error) {
    fail(`cannot parse ${label}: ${error.message}`);
    return null;
  }
}

function validateOwner(owner, fail, rowId) {
  if (!isObject(owner)) {
    fail('owner must be an object with implementation and validation', rowId);
    return;
  }
  for (const field of REQUIRED_OWNER_FIELDS) {
    if (!isNonEmptyString(owner[field])) {
      fail(`owner.${field} is required`, rowId);
    }
  }
}

function validateSurface(surface, label, fail, rowId) {
  if (!isObject(surface)) {
    fail(`${label} must be an object`, rowId);
    return;
  }
  for (const field of REQUIRED_SURFACE_FIELDS) {
    if (!Array.isArray(surface[field])) {
      fail(`${label}.${field} must be an array`, rowId);
    } else if (surface[field].some((value) => typeof value !== 'string')) {
      fail(`${label}.${field} must contain only strings`, rowId);
    }
  }
  if (surface.ipad !== undefined && !Array.isArray(surface.ipad)) {
    fail(`${label}.ipad must be an array when present`, rowId);
  }
}

function validateReferencedPaths(repoRoot, relativePaths, fail, rowId, { mustExist = false } = {}) {
  for (const relativePath of relativePaths) {
    if (!isNonEmptyString(relativePath)) {
      fail('referenced path must be a non-empty string', rowId);
      continue;
    }
    const resolved = resolveConfinedPath(repoRoot, relativePath);
    if (resolved.error) {
      fail(`referenced path ${resolved.error}: ${relativePath}`, rowId);
      continue;
    }
    if (mustExist && !resolved.exists) {
      fail(`referenced path does not exist: ${relativePath}`, rowId);
    }
  }
}

function validateEvidencePointers(repoRoot, pointers, fail, rowId, { requirePhysical, requireStore }) {
  if (pointers === undefined) return;
  if (!Array.isArray(pointers)) {
    fail('evidence pointers must be an array', rowId);
    return;
  }
  for (const pointer of pointers) {
    if (!isObject(pointer)) {
      fail('evidence pointer must be an object', rowId);
      continue;
    }
    if (!isNonEmptyString(pointer.path)) {
      fail('evidence pointer path is required', rowId);
      continue;
    }
    const resolved = resolveConfinedPath(repoRoot, pointer.path);
    if (resolved.error) {
      fail(`evidence path ${resolved.error}: ${pointer.path}`, rowId);
      continue;
    }
    if (!resolved.exists) {
      fail(`evidence file does not exist: ${pointer.path}`, rowId);
      continue;
    }
    const stat = fs.statSync(resolved.path);
    if (!stat.isFile()) {
      fail(`evidence path must be a regular file: ${pointer.path}`, rowId);
      continue;
    }
    if (stat.size === 0) {
      fail(`empty evidence file cannot prove a row: ${pointer.path}`, rowId);
      continue;
    }
    const text = fs.readFileSync(resolved.path, 'utf8');
    if (looksLikePlaceholder(text)) {
      fail(`placeholder evidence cannot prove a row: ${pointer.path}`, rowId);
      continue;
    }
    if (!isNonEmptyString(pointer.candidateSha) || !HEAD_PATTERN.test(pointer.candidateSha)) {
      fail(`unattributed evidence cannot prove a row: ${pointer.path}`, rowId);
    }
    if (pointer.sha256 !== undefined) {
      if (!SHA256_PATTERN.test(pointer.sha256)) {
        fail(`evidence pointer has invalid sha256: ${pointer.path}`, rowId);
      } else if (sha256File(resolved.path) !== pointer.sha256) {
        fail(`evidence pointer sha256 mismatch: ${pointer.path}`, rowId);
      }
    }
    if (requirePhysical && pointer.simulatorOnly === true) {
      fail(`simulator-only evidence cannot satisfy a physical-device floor: ${pointer.path}`, rowId);
    }
    if (requireStore && pointer.kind !== 'store-receipt' && pointer.kind !== 'provider-receipt') {
      fail(`store/provider floor requires a store or provider receipt: ${pointer.path}`, rowId);
    }
  }
}

function validateCandidateBinding(candidate, fail, rowId) {
  if (candidate === undefined) return;
  if (!isObject(candidate)) {
    fail('evidence candidate must be an object', rowId);
    return;
  }
  const refusal = candidateCloseRefusal({
    commitSha: candidate.commitSha,
    dirty: candidate.dirty === true || (candidate.dirtyEntries?.length ?? 0) > 0,
    dirtyEntries: candidate.dirtyEntries ?? []
  });
  if (refusal && (candidate.dirty === true || (candidate.dirtyEntries?.length ?? 0) > 0)) {
    fail(`${refusal}`, rowId);
  }
  if (candidate.commitSha !== undefined && !HEAD_PATTERN.test(candidate.commitSha)) {
    fail('evidence candidate commitSha is not a canonical git SHA', rowId);
  }
}

export function deriveCapabilityLedgerRows(registry) {
  const capabilities = Array.isArray(registry?.capabilities) ? registry.capabilities : [];
  return capabilities.map((capability) => ({
    id: `CAP-${capability.capabilityId}`,
    kind: 'capability',
    capabilityId: capability.capabilityId,
    family: capability.family,
    status: capability.status,
    evidenceFreshness: capability.status === 'accepted-divergence'
      ? 'accepted-divergence'
      : capability.status === 'rebind-required'
        ? 'rebind-required'
        : 'blocked',
    evidenceFloor: capability.evidenceFloor,
    owner: capability.owner,
    promotionCriterion: capability.kind === 'non-goal' || capability.kind === 'accepted-divergence'
      ? `Keep ${capability.capabilityId} as an explicit ${capability.kind}; do not treat absence as an implicit non-goal.`
      : `Prove ${capability.capabilityId} on iOS, iPadOS, and Android with candidate-bound evidence meeting ${Array.isArray(capability.evidenceFloor) ? capability.evidenceFloor.join(', ') : 'the declared floor'}.`,
    notes: capability.kind === 'capability'
      ? 'Code presence is not validation. Physical-device, store, and provider rows stay blocked until rebound.'
      : capability.notes ?? '',
    missingPrerequisite: capability.kind === 'capability'
      ? 'named iPhone, iPad, and Android devices plus an installed candidate artifact'
      : undefined
  }));
}

function validateRegistry(registry, repoRoot, fail) {
  if (!isObject(registry)) {
    fail('capability registry must be an object');
    return new Map();
  }
  if (registry.schemaVersion !== 1) fail('capability registry schemaVersion must be 1');
  if (registry.id !== REGISTRY_ID) fail(`capability registry id must be ${REGISTRY_ID}`);
  if (registry.programStatus !== 'mobile parity remediation in progress') {
    fail('registry programStatus must remain "mobile parity remediation in progress"');
  }
  if (!HEAD_PATTERN.test(registry.baselineSha ?? '')) {
    fail('registry baselineSha must be a canonical git SHA');
  }
  for (const field of ['routeMap', 'ownershipMap', 'evidenceSchema', 'nonGoals', 'ledger', 'plan']) {
    if (!isNonEmptyString(registry[field])) fail(`registry.${field} is required`);
  }
  if (registry.routeMap !== ROUTE_MAP_PATH) fail('registry.routeMap must point at the canonical route map');
  if (registry.ownershipMap !== OWNERSHIP_MAP_PATH) fail('registry.ownershipMap must point at the canonical ownership map');
  if (registry.evidenceSchema !== EVIDENCE_SCHEMA_PATH) fail('registry.evidenceSchema must point at the canonical evidence schema');
  if (registry.nonGoals !== NON_GOALS_PATH) fail('registry.nonGoals must point at the canonical non-goals file');
  if (registry.ledger !== LEDGER_PATH) fail('registry.ledger must point at the canonical ledger');
  if (registry.plan !== PLAN_PATH) fail('registry.plan must point at the copied remediation plan');

  if (!isObject(registry.schemaCanon) || !Array.isArray(registry.schemaCanon.mobileConsumedDomains)) {
    fail('registry.schemaCanon.mobileConsumedDomains is required');
  }

  const capabilities = Array.isArray(registry.capabilities) ? registry.capabilities : null;
  if (!capabilities || capabilities.length === 0) {
    fail('capability registry has no capabilities');
    return new Map();
  }

  const byId = new Map();
  const families = new Set();
  for (const capability of capabilities) {
    const id = capability?.capabilityId;
    if (!isNonEmptyString(id)) {
      fail('capability is missing capabilityId');
      continue;
    }
    if (byId.has(id)) {
      fail(`duplicate capabilityId: ${id}`, id);
      continue;
    }
    byId.set(id, capability);
    for (const field of REQUIRED_CAPABILITY_FIELDS) {
      if (capability[field] === undefined) fail(`missing required field ${field}`, id);
    }
    if (!isNonEmptyString(capability.title)) fail('title is required', id);
    if (!isNonEmptyString(capability.family)) fail('family is required', id);
    families.add(capability.family);
    if (!CAPABILITY_KINDS.includes(capability.kind)) fail(`unknown kind: ${capability.kind}`, id);
    if (!ACTORS.includes(capability.actor)) fail(`unknown actor: ${capability.actor}`, id);
    if (!isNonEmptyString(capability.sourceSurface)) fail('sourceSurface is required', id);
    if (capability.sharedContract !== 'none' && !isNonEmptyString(capability.sharedContract)) {
      fail('sharedContract must be a TypeSpec/generated/shared-model id or none', id);
    }
    if (!Array.isArray(capability.states) || capability.states.length === 0) {
      fail('states must be a non-empty array', id);
    } else if (capability.states.some((state) => !CAPABILITY_STATES.includes(state))) {
      fail(`unknown capability state in ${id}`, id);
    }
    if (!ENTITLEMENTS.includes(capability.entitlement)) fail(`unknown entitlement: ${capability.entitlement}`, id);
    if (!SECURITY_BOUNDARIES.includes(capability.securityBoundary)) {
      fail(`unknown securityBoundary: ${capability.securityBoundary}`, id);
    }
    if (!Array.isArray(capability.evidenceFloor) || capability.evidenceFloor.length === 0) {
      fail('evidenceFloor must be a non-empty array', id);
    } else if (capability.evidenceFloor.some((floor) => !EVIDENCE_FLOORS.includes(floor))) {
      fail(`unknown evidenceFloor value on ${id}`, id);
    }
    if (!CAPABILITY_STATUSES.includes(capability.status)) fail(`unknown status: ${capability.status}`, id);
    if (capability.status === 'validated' && !evidenceAllowsValidated(capability.evidence, null)) {
      fail('validated is forbidden until fresh candidate-bound evidence exists', id);
    }
    validateOwner(capability.owner, fail, id);
    validateSurface(capability.iosSurface, 'iosSurface', fail, id);
    validateSurface(capability.androidSurface, 'androidSurface', fail, id);
    if (!isObject(capability.routing)) {
      fail('routing is required', id);
    } else {
      for (const field of REQUIRED_ROUTING_FIELDS) {
        if (capability.routing[field] === undefined) fail(`routing.${field} is required`, id);
      }
      if (!ROUTING_CLASSES.includes(capability.routing.class)) {
        fail(`unknown routing.class: ${capability.routing.class}`, id);
      }
      for (const flag of ['primary', 'secondary', 'gated', 'deepLinkable', 'platformSpecific']) {
        if (typeof capability.routing[flag] !== 'boolean') fail(`routing.${flag} must be boolean`, id);
      }
    }
    for (const listField of ['widgets', 'intents', 'pushRoutes', 'backgroundJobs', 'crossDeviceSideEffects', 'routeIds']) {
      if (!Array.isArray(capability[listField])) fail(`${listField} must be an array`, id);
    }
    if (!uniqueStrings(capability.routeIds ?? [])) fail('routeIds must be unique strings', id);

    const iosPaths = surfacePaths(capability.iosSurface);
    const androidPaths = surfacePaths(capability.androidSurface);
    const allPaths = [...iosPaths, ...androidPaths];
    const requireExisting = capability.status === 'implemented' || capability.status === 'validated';
    validateReferencedPaths(repoRoot, allPaths, fail, id, { mustExist: requireExisting });

    if (capability.kind === 'capability' && capability.status === 'implemented') {
      if (iosPaths.length === 0 && androidPaths.length === 0) {
        fail('implemented capability must list at least one platform surface', id);
      }
      if (capability.routing?.platformSpecific !== true && (iosPaths.length === 0 || androidPaths.length === 0)) {
        fail('implemented cross-platform capability needs iOS and Android surfaces', id);
      }
      const floors = Array.isArray(capability.evidenceFloor) ? capability.evidenceFloor : [];
      if (floors.includes('unit')) {
        const tests = [
          ...(capability.iosSurface?.tests ?? []),
          ...(capability.androidSurface?.tests ?? [])
        ];
        if (tests.length === 0) {
          fail('implemented unit-floor capability must list at least one test path', id);
        }
      }
    }
    if (capability.kind === 'accepted-divergence' && capability.status !== 'accepted-divergence') {
      fail('accepted-divergence kind must use accepted-divergence status', id);
    }
    if (capability.kind === 'non-goal' && capability.status !== 'accepted-divergence') {
      fail('non-goal kind must use accepted-divergence status', id);
    }
  }

  const requiredFamilies = [
    'auth',
    'shell',
    'pulse',
    'burn',
    'streams',
    'hermes',
    'insights-budget',
    'inbox',
    'providers',
    'devices',
    'mercury',
    'computer-use',
    'store',
    'os',
    'a11y',
    'divergence',
    'nongoal'
  ];
  for (const family of requiredFamilies) {
    if (!families.has(family)) fail(`registry is missing required family ${family}`);
  }
  return byId;
}

function validateRouteMap(routeMap, capabilitiesById, repoRoot, fail) {
  if (!isObject(routeMap)) {
    fail('route map must be an object');
    return;
  }
  if (routeMap.schemaVersion !== 1) fail('route map schemaVersion must be 1');
  if (routeMap.id !== ROUTE_MAP_ID) fail(`route map id must be ${ROUTE_MAP_ID}`);
  if (!isNonEmptyString(routeMap.scheme)) fail('route map scheme is required');
  if (!isObject(routeMap.destinationCatalog)) fail('route map destinationCatalog is required');

  const catalog = routeMap.destinationCatalog;
  if (!Array.isArray(catalog.canonicalIds) || catalog.canonicalIds.length === 0) {
    fail('destinationCatalog.canonicalIds is required');
  }
  if (!Array.isArray(catalog.bindings)) {
    fail('destinationCatalog.bindings is required');
    return;
  }

  const bindingsByCanonical = new Map();
  for (const binding of catalog.bindings) {
    if (!isObject(binding) || !isNonEmptyString(binding.canonicalId)) {
      fail('destination binding is missing canonicalId');
      continue;
    }
    if (bindingsByCanonical.has(binding.canonicalId)) {
      fail(`duplicate destination binding: ${binding.canonicalId}`);
      continue;
    }
    bindingsByCanonical.set(binding.canonicalId, binding);
    const iosId = binding.iosDestinationId ?? null;
    const androidId = binding.androidDestinationId ?? null;
    const ipadId = binding.ipadDestinationId ?? null;
    const ids = [iosId, androidId, ipadId].filter((value) => value !== null);
    const distinct = new Set(ids);
    if (distinct.size > 1 && !isNonEmptyString(binding.acceptedMappingId) && !isNonEmptyString(binding.acceptedDivergenceId)) {
      fail(`destination ids silently drift for ${binding.canonicalId}`, binding.canonicalId);
    }
    if ((iosId === null || androidId === null) && !isNonEmptyString(binding.acceptedDivergenceId) && !isNonEmptyString(binding.acceptedMappingId)) {
      fail(`missing platform destination for ${binding.canonicalId} is not recorded as a mapping or divergence`, binding.canonicalId);
    }
  }

  if (!isObject(routeMap.shells)) fail('route map shells is required');
  for (const platform of ['ios', 'ipados', 'android']) {
    const shell = routeMap.shells?.[platform];
    if (!isObject(shell) || !Array.isArray(shell.primary) || !Array.isArray(shell.secondary)) {
      fail(`route map shells.${platform} must declare primary and secondary arrays`);
    }
  }

  const routes = Array.isArray(routeMap.routes) ? routeMap.routes : null;
  if (!routes || routes.length === 0) {
    fail('route map has no routes');
    return;
  }
  const routesById = new Map();
  const routesByCapability = new Map();
  for (const route of routes) {
    if (!isNonEmptyString(route?.routeId)) {
      fail('route is missing routeId');
      continue;
    }
    if (routesById.has(route.routeId)) {
      fail(`duplicate routeId: ${route.routeId}`, route.routeId);
      continue;
    }
    routesById.set(route.routeId, route);
    if (!isNonEmptyString(route.capabilityId)) {
      fail('route is missing capabilityId', route.routeId);
      continue;
    }
    if (!capabilitiesById.has(route.capabilityId)) {
      fail(`route points at unknown capabilityId: ${route.capabilityId}`, route.routeId);
    }
    const existing = routesByCapability.get(route.capabilityId) ?? [];
    existing.push(route.routeId);
    routesByCapability.set(route.capabilityId, existing);
    if (!isNonEmptyString(route.canonicalDestinationId)) {
      fail('route is missing canonicalDestinationId', route.routeId);
    } else if (!bindingsByCanonical.has(route.canonicalDestinationId)) {
      fail(`route canonicalDestinationId is not in the catalog: ${route.canonicalDestinationId}`, route.routeId);
    }
    if (!isNonEmptyString(route.authGate)) fail('route.authGate is required', route.routeId);
    if (typeof route.coldLaunch !== 'boolean' || typeof route.warmLaunch !== 'boolean') {
      fail('route coldLaunch and warmLaunch must be boolean', route.routeId);
    }
  }

  for (const [capabilityId, capability] of capabilitiesById) {
    if (!isRoutable(capability)) continue;
    const mapped = routesByCapability.get(capabilityId) ?? [];
    const declared = capability.routeIds ?? [];
    const declaredExist = declared.filter((routeId) => routesById.has(routeId));
    if (mapped.length === 0 && declaredExist.length === 0) {
      fail(`routable capability is missing from the route map: ${capabilityId}`, capabilityId);
    }
    for (const routeId of mapped) {
      if (!declared.includes(routeId)) {
        fail(`route ${routeId} is not listed on capability ${capabilityId}`, capabilityId);
      }
    }
    for (const routeId of declared) {
      if (!routesById.has(routeId)) {
        fail(`capability lists unknown routeId: ${routeId}`, capabilityId);
      }
    }
  }

  if (!Array.isArray(routeMap.acceptedRouteDivergences) || routeMap.acceptedRouteDivergences.length === 0) {
    fail('acceptedRouteDivergences must record Inbox-primary, Store-labelled You, and related shell differences');
  }

  validateReferencedPaths(repoRoot, [
    routeMap.iosSource,
    routeMap.ipadSource,
    routeMap.androidSource
  ].filter(Boolean), fail, 'route-map', { mustExist: true });
}

function validateOwnershipMap(ownership, capabilitiesById, fail) {
  if (!isObject(ownership)) {
    fail('ownership map must be an object');
    return;
  }
  if (ownership.schemaVersion !== 1) fail('ownership map schemaVersion must be 1');
  if (ownership.id !== OWNERSHIP_MAP_ID) fail(`ownership map id must be ${OWNERSHIP_MAP_ID}`);
  if (!Array.isArray(ownership.domains) || ownership.domains.length === 0) {
    fail('ownership map domains are required');
  }
  if (!Array.isArray(ownership.families) || ownership.families.length === 0) {
    fail('ownership map families are required');
  }
  const capabilityIds = new Set(capabilitiesById.keys());
  for (const family of ownership.families ?? []) {
    if (!isNonEmptyString(family?.family)) fail('ownership family is missing family id');
    if (!isNonEmptyString(family?.source)) fail(`ownership family ${family?.family} is missing source`);
    if (!isNonEmptyString(family?.ios) || !isNonEmptyString(family?.ipados) || !isNonEmptyString(family?.android)) {
      fail(`ownership family ${family?.family} must name iOS, iPadOS, and Android owners`);
    }
  }
  for (const id of capabilityIds) {
    const capability = capabilitiesById.get(id);
    if (capability.kind !== 'capability') continue;
    const covered = (ownership.families ?? []).some((family) => family.family === capability.family);
    if (!covered) fail(`ownership map does not cover capability family ${capability.family}`, id);
  }
}

function validateNonGoals(nonGoals, capabilitiesById, fail) {
  if (!isObject(nonGoals)) {
    fail('accepted non-goals document must be an object');
    return;
  }
  if (nonGoals.schemaVersion !== 1) fail('accepted non-goals schemaVersion must be 1');
  if (nonGoals.id !== NON_GOALS_ID) fail(`accepted non-goals id must be ${NON_GOALS_ID}`);
  if (!Array.isArray(nonGoals.items) || nonGoals.items.length === 0) {
    fail('accepted non-goals items are required');
    return;
  }
  const requiredIds = new Set([
    'nongoal.pixel-identical-ui',
    'nongoal.desktop-only-daemon',
    'nongoal.linux-windows-ports',
    'nongoal.store-submission-m0',
    'nongoal.schema-migration-m0'
  ]);
  const seen = new Set();
  for (const item of nonGoals.items) {
    if (!isNonEmptyString(item?.id)) {
      fail('non-goal item is missing id');
      continue;
    }
    seen.add(item.id);
    if (!isNonEmptyString(item.reason) || !isNonEmptyString(item.owner)) {
      fail(`non-goal ${item.id} must include reason and owner`, item.id);
    }
    if (!capabilitiesById.has(item.id)) {
      fail(`non-goal ${item.id} is not signed in the capability registry`, item.id);
    }
  }
  for (const id of requiredIds) {
    if (!seen.has(id)) fail(`accepted non-goals is missing required item ${id}`);
  }
}

function validateEvidenceSchema(schema, fail) {
  if (!isObject(schema)) {
    fail('evidence schema must be an object');
    return;
  }
  if (schema.schemaVersion !== 1) fail('evidence schema schemaVersion must be 1');
  if (schema.id !== EVIDENCE_SCHEMA_ID) fail(`evidence schema id must be ${EVIDENCE_SCHEMA_ID}`);
  for (const field of ['candidate', 'device', 'network', 'account', 'freshness', 'pointer']) {
    if (!isObject(schema[field])) fail(`evidence schema missing ${field} contract`);
  }
  if (!Array.isArray(schema.rejectionRules) || schema.rejectionRules.length === 0) {
    fail('evidence schema rejectionRules are required');
  }
}

function validateLedger(ledger, registry, capabilitiesById, repoRoot, fingerprint, fail, promote) {
  if (!isObject(ledger)) {
    fail('parity ledger must be an object');
    return;
  }
  if (ledger.schemaVersion !== 1) fail('parity ledger schemaVersion must be 1');
  if (ledger.id !== LEDGER_ID) fail(`parity ledger id must be ${LEDGER_ID}`);
  if (ledger.registry !== REGISTRY_PATH) fail('ledger.registry must point at the capability registry');
  if (ledger.routeMap !== ROUTE_MAP_PATH) fail('ledger.routeMap must point at the route map');
  if (!isObject(ledger.semantics)) {
    fail('ledger.semantics is required');
    return;
  }
  const semantics = ledger.semantics;
  if (semantics.kind !== 'mobile-parity') fail('ledger.semantics.kind must be mobile-parity');
  if (typeof semantics.productParityClaim !== 'boolean') fail('ledger.semantics.productParityClaim must be boolean');
  if (semantics.programStatus !== 'mobile parity remediation in progress') {
    fail('ledger programStatus must remain "mobile parity remediation in progress"');
  }
  if (!HEAD_PATTERN.test(semantics.baselineSha ?? '')) fail('ledger baselineSha must be a canonical git SHA');
  if (semantics.baselineSha !== registry.baselineSha) fail('ledger baselineSha must match the registry baseline');

  const rows = Array.isArray(ledger.rows) ? ledger.rows : null;
  if (!rows || rows.length === 0) {
    fail('parity ledger has no rows');
    return;
  }

  const byId = new Map();
  const valIds = new Set();
  const capabilityRowIds = new Set();
  for (const row of rows) {
    const id = row?.id;
    if (!isNonEmptyString(id)) {
      fail('ledger row is missing id');
      continue;
    }
    if (byId.has(id)) {
      fail(`duplicate ledger row id: ${id}`, id);
      continue;
    }
    byId.set(id, row);
    for (const field of REQUIRED_LEDGER_ROW_FIELDS) {
      if (row[field] === undefined) fail(`ledger row missing ${field}`, id);
    }
    if (!['val-contract', 'capability'].includes(row.kind)) fail(`unknown ledger row kind: ${row.kind}`, id);
    if (![...CAPABILITY_STATUSES, ...LEDGER_STATES].includes(row.status)) {
      fail(`unknown ledger row status: ${row.status}`, id);
    }
    if (!EVIDENCE_FRESHNESS.includes(row.evidenceFreshness) && row.evidenceFreshness !== 'accepted-divergence') {
      fail(`unknown evidenceFreshness: ${row.evidenceFreshness}`, id);
    }
    validateOwner(row.owner, fail, id);
    if (!isNonEmptyString(row.promotionCriterion)) fail('promotionCriterion is required', id);

    if (row.kind === 'val-contract') valIds.add(id);
    if (row.kind === 'capability') {
      if (!isNonEmptyString(row.capabilityId)) fail('capability ledger row missing capabilityId', id);
      else capabilityRowIds.add(row.capabilityId);
    }

    if (row.status === 'validated' || row.result === 'PASS' || row.result === 'pass') {
      if (!evidenceAllowsValidated(row, fingerprint)) {
        fail('validated/PASS requires closable candidate-bound evidence', id);
      }
    }
    if (rowCloses(row) && STALE_FRESHNESS.has(row.evidenceFreshness)) {
      fail('historical/stale evidence cannot satisfy a validated/fresh/PASS close', id);
    }
    if (rowCloses(row)) {
      const refusal = candidateCloseRefusal(fingerprint);
      if (refusal) fail(refusal, id);
      validateCandidateBinding(row.candidate, fail, id);
    }

    const floors = Array.isArray(row.evidenceFloor) ? row.evidenceFloor : [];
    const requirePhysical = floors.includes('physical device');
    const requireStore = floors.includes('store/provider');
    validateEvidencePointers(repoRoot, row.evidencePointers, fail, id, { requirePhysical, requireStore });
    if (rowCloses(row) && requirePhysical && (!Array.isArray(row.evidencePointers) || row.evidencePointers.length === 0)) {
      fail('physical-device floor cannot close without evidence pointers', id);
    }
    if ((row.status === 'blocked' || row.evidenceFreshness === 'blocked') && !isNonEmptyString(row.missingPrerequisite)) {
      fail('blocked row must name the missing prerequisite', id);
    }
  }

  for (const valId of VAL_IDS) {
    if (!valIds.has(valId)) fail(`ledger is missing required VAL contract ${valId}`);
  }

  const derived = deriveCapabilityLedgerRows(registry);
  const derivedByCapability = new Map(derived.map((row) => [row.capabilityId, row]));
  for (const capabilityId of capabilitiesById.keys()) {
    if (!capabilityRowIds.has(capabilityId)) {
      fail(`ledger is missing capability row for ${capabilityId}`, capabilityId);
    }
  }
  for (const capabilityId of capabilityRowIds) {
    if (!capabilitiesById.has(capabilityId)) {
      fail(`ledger capability row has no registry entry: ${capabilityId}`, capabilityId);
    }
    const row = [...byId.values()].find((candidate) => candidate.capabilityId === capabilityId);
    const expected = derivedByCapability.get(capabilityId);
    if (row && expected && row.status !== expected.status) {
      fail(`ledger status for ${capabilityId} does not match the registry`, capabilityId);
    }
  }

  if (semantics.productParityClaim === true) {
    const blockers = rows.filter((row) => {
      if (row.kind === 'capability') {
        const capability = capabilitiesById.get(row.capabilityId);
        if (capability && (capability.kind === 'non-goal' || capability.kind === 'accepted-divergence')) {
          return false;
        }
      }
      return PROMOTION_BLOCKING_STATUSES.has(row.status)
        || PROMOTION_BLOCKING_STATUSES.has(row.evidenceFreshness)
        || row.status === 'implemented'
        || STALE_FRESHNESS.has(row.evidenceFreshness);
    });
    if (blockers.length > 0) {
      fail('productParityClaim=true contradicts blocked, rebind-required, unmapped, implemented, or stale rows');
    }
  } else {
    promote('product parity claim is false.');
  }

  const requiredOpen = rows.filter((row) => {
    if (row.kind === 'capability') {
      const capability = capabilitiesById.get(row.capabilityId);
      if (capability && (capability.kind === 'non-goal' || capability.kind === 'accepted-divergence')) {
        return false;
      }
    }
    return PROMOTION_BLOCKING_STATUSES.has(row.status) || row.status === 'implemented';
  });
  if (requiredOpen.length > 0) {
    promote(`${requiredOpen.length} required rows remain blocked, unmapped, rebind-required, or merely implemented.`);
  }
}

export function validateMobileParity(documents, options = {}) {
  const structuralFailures = [];
  const promotionFailures = [];
  const warnings = [];
  const fail = (message, row = null) => {
    structuralFailures.push({ message, row });
  };
  const promote = (message, row = null) => {
    promotionFailures.push({ message, row });
  };

  const repoRoot = options.repoRoot;
  if (!isNonEmptyString(repoRoot)) fail('repoRoot is required');
  if (options.currentHead && !HEAD_PATTERN.test(options.currentHead)) {
    fail('current HEAD must be a canonical 40-64 character lowercase git SHA');
  }

  const registry = documents.registry;
  const capabilitiesById = validateRegistry(registry, repoRoot, fail);
  validateRouteMap(documents.routeMap, capabilitiesById, repoRoot, fail);
  validateOwnershipMap(documents.ownership, capabilitiesById, fail);
  validateNonGoals(documents.nonGoals, capabilitiesById, fail);
  validateEvidenceSchema(documents.evidenceSchema, fail);
  validateLedger(
    documents.ledger,
    registry ?? {},
    capabilitiesById,
    repoRoot,
    options.fingerprint,
    fail,
    promote
  );

  if (options.fingerprint) {
    const refusal = candidateCloseRefusal(options.fingerprint);
    const ledgerRows = Array.isArray(documents.ledger?.rows) ? documents.ledger.rows : [];
    if (refusal && ledgerRows.some((row) => rowCloses(row))) {
      fail(refusal);
    }
  }

  const productParityClaim = documents.ledger?.semantics?.productParityClaim === true;
  const structuralPassed = structuralFailures.length === 0;
  const promotionPassed = structuralPassed && promotionFailures.length === 0 && productParityClaim;
  if (productParityClaim && !promotionPassed) {
    fail('productParityClaim=true contradicts the incomplete or invalid evidence graph.');
  }

  return {
    structuralPassed,
    promotionPassed,
    passed: options.allowBlocked === true ? structuralPassed : promotionPassed,
    productParityClaim,
    structuralFailures,
    promotionFailures,
    warnings,
    failures: options.allowBlocked === true
      ? structuralFailures
      : [...structuralFailures, ...promotionFailures]
  };
}

export function loadMobileParityDocuments(repoRoot, fail = () => {}) {
  return {
    registry: loadJsonDocument(repoRoot, REGISTRY_PATH, 'capability registry', fail),
    routeMap: loadJsonDocument(repoRoot, ROUTE_MAP_PATH, 'route map', fail),
    ownership: loadJsonDocument(repoRoot, OWNERSHIP_MAP_PATH, 'ownership map', fail),
    evidenceSchema: loadJsonDocument(repoRoot, EVIDENCE_SCHEMA_PATH, 'evidence schema', fail),
    nonGoals: loadJsonDocument(repoRoot, NON_GOALS_PATH, 'accepted non-goals', fail),
    ledger: loadJsonDocument(repoRoot, LEDGER_PATH, 'parity ledger', fail)
  };
}

export function validateMobileParityAtRepo(repoRoot, options = {}) {
  const structuralFailures = [];
  const fail = (message, row = null) => structuralFailures.push({ message, row });
  const documents = loadMobileParityDocuments(repoRoot, fail);
  const result = validateMobileParity(documents, {
    ...options,
    repoRoot
  });
  result.structuralFailures = [...structuralFailures, ...result.structuralFailures];
  result.structuralPassed = result.structuralFailures.length === 0;
  result.passed = options.allowBlocked === true ? result.structuralPassed : result.promotionPassed;
  result.failures = options.allowBlocked === true
    ? result.structuralFailures
    : [...result.structuralFailures, ...result.promotionFailures];
  return result;
}

export function cell(value) {
  return String(value ?? '').replaceAll('|', '\\|').replaceAll('\n', ' ');
}

export function renderMobileParityLedger(ledger, registry) {
  const capabilities = new Map((registry.capabilities ?? []).map((item) => [item.capabilityId, item]));
  const rows = Array.isArray(ledger.rows) ? ledger.rows : [];
  const valRows = rows.filter((row) => row.kind === 'val-contract');
  const capabilityRows = rows.filter((row) => row.kind === 'capability');
  const claim = ledger.semantics?.productParityClaim === true;
  const counts = capabilityRows.reduce((acc, row) => {
    acc[row.status] = (acc[row.status] ?? 0) + 1;
    return acc;
  }, {});

  const lines = [
    '# OpenBurnBar mobile parity ledger',
    '',
    '> Generated from `mobile-parity-ledger.json` and `mobile-capability-registry.json`.',
    '> Run `node scripts/mobile-parity/render-mobile-parity-ledger.mjs`; do not edit this file manually.',
    '',
    '## Status',
    '',
    `- Program status: **${ledger.semantics?.programStatus ?? 'unknown'}**`,
    `- Product parity claim: **${claim ? 'true' : 'false'}**`,
    `- Baseline: \`${ledger.semantics?.baselineSha ?? ''}\``,
    `- VAL contracts: **${valRows.length}**`,
    `- Capability rows: **${capabilityRows.length}**`,
    `- Status counts: ${Object.entries(counts).map(([status, count]) => `${status}=${count}`).join(', ') || 'none'}`,
    '',
    'A green structural check means the inventory, route map, and evidence schema are internally valid.',
    'It does not mean iOS, iPadOS, and Android are promotable. Structural validity is not promotion.',
    'Historical or stale evidence cannot close a row. Physical-device navigation transcripts are not fabricated.',
    '',
    '## VAL contracts',
    '',
    '| ID | Status | Freshness | Owner | Missing prerequisite | Promotion criterion |',
    '|---|---|---|---|---|---|'
  ];

  for (const row of valRows) {
    lines.push(
      `| ${cell(row.id)} | ${cell(row.status)} | ${cell(row.evidenceFreshness)} | ${cell(row.owner?.validation ?? row.owner?.implementation)} | ${cell(row.missingPrerequisite ?? '')} | ${cell(row.promotionCriterion)} |`
    );
  }

  lines.push(
    '',
    '## Capabilities',
    '',
    '| ID | Family | Kind | Status | Entitlement | Floor | Routes |',
    '|---|---|---|---|---|---|---|'
  );

  for (const row of capabilityRows) {
    const capability = capabilities.get(row.capabilityId) ?? {};
    lines.push(
      `| ${cell(row.capabilityId)} | ${cell(capability.family ?? row.family)} | ${cell(capability.kind ?? '')} | ${cell(row.status)} | ${cell(capability.entitlement ?? '')} | ${cell((capability.evidenceFloor ?? []).join(', '))} | ${cell((capability.routeIds ?? []).join(', '))} |`
    );
  }

  lines.push(
    '',
    '## Validation',
    '',
    '```bash',
    '# Inventory/schema/path integrity. Blocked work remains visible but does not fail this mode.',
    'node scripts/mobile-parity/validate-mobile-parity.mjs --allow-blocked',
    '',
    '# Promotion gate. This must remain nonzero until every required row is proven.',
    'node scripts/mobile-parity/validate-mobile-parity.mjs',
    '',
    '# Generated documentation drift check.',
    'node scripts/mobile-parity/render-mobile-parity-ledger.mjs --check',
    '```',
    ''
  );
  return lines.join('\n');
}
