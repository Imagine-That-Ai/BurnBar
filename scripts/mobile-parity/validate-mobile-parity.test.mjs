import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { VAL_IDS } from './lib/mobile-parity-constants.mjs';
import { deriveCapabilityLedgerRows, validateMobileParity } from './lib/mobile-parity-validate.mjs';
import { resolveConfinedPath } from './lib/path-confine.mjs';

const HEAD = '3f127f7da28f590441c46e0674dac7f27a04b7aa';
const OWNER = { implementation: 'mobile-apps', validation: 'mobile-parity' };

function surface(iosFile = 'ios.swift', androidFile = 'android.kt') {
  return {
    iosSurface: { views: [iosFile], stores: [], services: [], tests: ['ios-test.swift'], ipad: [] },
    androidSurface: { views: [androidFile], stores: [], services: [], tests: ['android-test.kt'] }
  };
}

function capability(overrides = {}) {
  return {
    capabilityId: 'pulse.overview',
    title: 'Pulse',
    family: 'pulse',
    kind: 'capability',
    actor: 'signed-in user',
    sourceSurface: 'dashboard',
    sharedContract: 'usage-quota',
    states: ['loading', 'ready'],
    entitlement: 'none',
    securityBoundary: 'auth',
    evidenceFloor: ['unit'],
    status: 'implemented',
    owner: OWNER,
    routing: {
      class: 'primary',
      primary: true,
      secondary: false,
      gated: false,
      deepLinkable: true,
      platformSpecific: false
    },
    widgets: [],
    intents: [],
    pushRoutes: [],
    backgroundJobs: [],
    crossDeviceSideEffects: [],
    routeIds: ['route.shell.pulse'],
    ...surface(),
    ...overrides
  };
}

function requiredFamilies() {
  const families = [
    'auth', 'shell', 'pulse', 'burn', 'streams', 'hermes', 'insights-budget',
    'inbox', 'providers', 'devices', 'mercury', 'computer-use', 'store', 'os',
    'a11y', 'divergence', 'nongoal'
  ];
  return families.map((family, index) => {
    const isExtraKind = family === 'divergence' || family === 'nongoal';
    const id = family === 'pulse'
      ? 'pulse.overview'
      : family === 'nongoal'
        ? 'nongoal.pixel-identical-ui'
        : `${family}.row`;
    return capability({
      capabilityId: id,
      family,
      kind: isExtraKind ? (family === 'nongoal' ? 'non-goal' : 'accepted-divergence') : 'capability',
      status: isExtraKind ? 'accepted-divergence' : 'implemented',
      routing: family === 'pulse'
        ? capability().routing
        : {
            class: 'none',
            primary: false,
            secondary: false,
            gated: false,
            deepLinkable: false,
            platformSpecific: false
          },
      routeIds: family === 'pulse' ? ['route.shell.pulse'] : [],
      ...surface(`ios-${index}.swift`, `android-${index}.kt`)
    });
  });
}

function registry(capabilities = requiredFamilies()) {
  return {
    schemaVersion: 1,
    id: 'openburnbar-mobile-capability-registry-v1',
    programStatus: 'mobile parity remediation in progress',
    baselineSha: HEAD,
    routeMap: 'docs/mobile-parity/mobile-route-map.json',
    ownershipMap: 'docs/mobile-parity/mobile-ownership-map.json',
    evidenceSchema: 'docs/mobile-parity/mobile-evidence-schema.json',
    nonGoals: 'docs/mobile-parity/accepted-non-goals.json',
    ledger: 'docs/mobile-parity/mobile-parity-ledger.json',
    plan: 'docs/mobile-parity/FULL_MOBILE_PARITY_REMEDIATION_PLAN.md',
    schemaCanon: { mobileConsumedDomains: [{ id: 'usage-quota' }] },
    capabilities
  };
}

function routeMap(overrides = {}) {
  return {
    schemaVersion: 1,
    id: 'openburnbar-mobile-route-map-v1',
    scheme: 'burnbar',
    iosSource: 'ios-0.swift',
    ipadSource: 'ios-0.swift',
    androidSource: 'android-0.kt',
    destinationCatalog: {
      canonicalIds: ['pulse'],
      bindings: [{
        canonicalId: 'pulse',
        iosDestinationId: 'pulse',
        ipadDestinationId: 'pulse',
        androidDestinationId: 'pulse'
      }]
    },
    shells: {
      ios: { primary: ['pulse'], secondary: [] },
      ipados: { primary: ['pulse'], secondary: [] },
      android: { primary: ['pulse'], secondary: [] }
    },
    routes: [{
      routeId: 'route.shell.pulse',
      capabilityId: 'pulse.overview',
      canonicalDestinationId: 'pulse',
      authGate: 'signed-in',
      coldLaunch: true,
      warmLaunch: true
    }],
    acceptedRouteDivergences: [{ id: 'divergence.inbox-primary-android', summary: 'inbox' }],
    ...overrides
  };
}

function ownership(reg) {
  const families = [...new Set(reg.capabilities.filter((item) => item.kind === 'capability').map((item) => item.family))];
  return {
    schemaVersion: 1,
    id: 'openburnbar-mobile-ownership-map-v1',
    domains: [{ domainId: 'usage-quota', source: 'typespec', ios: 'ios', ipados: 'ios', android: 'android' }],
    families: families.map((family) => ({
      family,
      source: 'source',
      ios: 'ios',
      ipados: 'ipados',
      android: 'android'
    }))
  };
}

function evidenceSchema() {
  return {
    schemaVersion: 1,
    id: 'openburnbar-mobile-evidence-schema-v1',
    candidate: { required: ['commitSha'] },
    device: { required: ['platform'] },
    network: { required: ['kind'] },
    account: { required: ['uidHash'] },
    freshness: { enum: ['fresh'] },
    pointer: { required: ['path'] },
    rejectionRules: ['empty files', 'placeholder text']
  };
}

function nonGoals() {
  return {
    schemaVersion: 1,
    id: 'openburnbar-mobile-accepted-non-goals-v1',
    items: [
      { id: 'nongoal.pixel-identical-ui', reason: 'native UI', owner: 'mobile-apps' },
      { id: 'nongoal.desktop-only-daemon', reason: 'desktop', owner: 'mobile-apps' },
      { id: 'nongoal.linux-windows-ports', reason: 'other ports', owner: 'mobile-parity' },
      { id: 'nongoal.store-submission-m0', reason: 'm8', owner: 'mobile-parity' },
      { id: 'nongoal.schema-migration-m0', reason: 'm1', owner: 'mobile-parity' }
    ]
  };
}

function valRow(id) {
  return {
    id,
    kind: 'val-contract',
    status: 'blocked',
    evidenceFreshness: 'blocked',
    evidenceFloor: ['physical device'],
    owner: OWNER,
    promotionCriterion: `Prove ${id}`,
    notes: 'blocked',
    missingPrerequisite: 'named device / installed candidate'
  };
}

function ledger(reg, overrides = {}) {
  return {
    schemaVersion: 1,
    id: 'openburnbar-mobile-parity-ledger-v1',
    registry: 'docs/mobile-parity/mobile-capability-registry.json',
    routeMap: 'docs/mobile-parity/mobile-route-map.json',
    semantics: {
      kind: 'mobile-parity',
      productParityClaim: false,
      programStatus: 'mobile parity remediation in progress',
      baselineSha: HEAD
    },
    rows: [
      ...VAL_IDS.map(valRow),
      ...deriveCapabilityLedgerRows(reg)
    ],
    ...overrides
  };
}

function seedRepo(files = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-mobile-parity-'));
  fs.mkdirSync(path.join(root, 'docs/mobile-parity'), { recursive: true });
  const defaults = {
    'ios.swift': 'view\n',
    'android.kt': 'compose\n',
    'ios-0.swift': 'view\n',
    'android-0.kt': 'compose\n',
    'ios-test.swift': 'test\n',
    'android-test.kt': 'test\n'
  };
  for (let index = 0; index < 20; index += 1) {
    defaults[`ios-${index}.swift`] = 'view\n';
    defaults[`android-${index}.kt`] = 'compose\n';
  }
  for (const [rel, body] of Object.entries({ ...defaults, ...files })) {
    const dest = path.join(root, rel);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, body);
  }
  return root;
}

function docs(overrides = {}) {
  const capabilities = overrides.capabilities ?? requiredFamilies();
  const extraNonGoals = [
    capability({
      capabilityId: 'nongoal.desktop-only-daemon',
      family: 'nongoal',
      kind: 'non-goal',
      status: 'accepted-divergence',
      routing: { class: 'none', primary: false, secondary: false, gated: false, deepLinkable: false, platformSpecific: false },
      routeIds: [],
      ...surface('ios-16.swift', 'android-16.kt')
    }),
    capability({
      capabilityId: 'nongoal.linux-windows-ports',
      family: 'nongoal',
      kind: 'non-goal',
      status: 'accepted-divergence',
      routing: { class: 'none', primary: false, secondary: false, gated: false, deepLinkable: false, platformSpecific: false },
      routeIds: [],
      ...surface('ios-16.swift', 'android-16.kt')
    }),
    capability({
      capabilityId: 'nongoal.store-submission-m0',
      family: 'nongoal',
      kind: 'non-goal',
      status: 'accepted-divergence',
      routing: { class: 'none', primary: false, secondary: false, gated: false, deepLinkable: false, platformSpecific: false },
      routeIds: [],
      ...surface('ios-16.swift', 'android-16.kt')
    }),
    capability({
      capabilityId: 'nongoal.schema-migration-m0',
      family: 'nongoal',
      kind: 'non-goal',
      status: 'accepted-divergence',
      routing: { class: 'none', primary: false, secondary: false, gated: false, deepLinkable: false, platformSpecific: false },
      routeIds: [],
      ...surface('ios-16.swift', 'android-16.kt')
    })
  ];
  const caps = overrides.capabilities ?? [...requiredFamilies(), ...extraNonGoals];
  const reg = registry(caps);
  return {
    registry: overrides.registry ?? reg,
    routeMap: overrides.routeMap ?? routeMap(),
    ownership: overrides.ownership ?? ownership(reg),
    evidenceSchema: overrides.evidenceSchema ?? evidenceSchema(),
    nonGoals: overrides.nonGoals ?? nonGoals(),
    ledger: overrides.ledger ?? ledger(reg)
  };
}

function validate(documents, options = {}) {
  return validateMobileParity(documents, {
    repoRoot: options.repoRoot ?? seedRepo(),
    currentHead: HEAD,
    fingerprint: options.fingerprint ?? { commitSha: HEAD, dirty: false, dirtyEntries: [] },
    allowBlocked: options.allowBlocked ?? true
  });
}

function messages(result) {
  return result.structuralFailures.map((item) => item.message).join('\n');
}

test('happy-path inventory is structurally valid and not promotable', () => {
  const result = validate(docs(), { allowBlocked: true });
  assert.equal(result.structuralPassed, true, messages(result));
  assert.equal(result.promotionPassed, false);
  assert.equal(result.passed, true);
  assert.equal(result.productParityClaim, false);
});

test('strict mode fails while required rows remain blocked or implemented', () => {
  const result = validate(docs(), { allowBlocked: false });
  assert.equal(result.structuralPassed, true, messages(result));
  assert.equal(result.passed, false);
  assert.ok(result.promotionFailures.some((item) => /product parity claim is false/i.test(item.message)));
});

test('missing required capability field fails', () => {
  const documents = docs();
  delete documents.registry.capabilities.find((item) => item.capabilityId === 'pulse.overview').actor;
  const result = validate(documents);
  assert.equal(result.structuralPassed, false);
  assert.match(messages(result), /missing required field actor|unknown actor/);
});

test('unknown status fails', () => {
  const documents = docs();
  documents.registry.capabilities.find((item) => item.capabilityId === 'pulse.overview').status = 'shipped';
  const result = validate(documents);
  assert.match(messages(result), /unknown status: shipped/);
});

test('missing owner fails', () => {
  const documents = docs();
  documents.registry.capabilities.find((item) => item.capabilityId === 'pulse.overview').owner = { implementation: 'mobile-apps' };
  const result = validate(documents);
  assert.match(messages(result), /owner.validation is required/);
});

test('unknown actor fails', () => {
  const documents = docs();
  documents.registry.capabilities.find((item) => item.capabilityId === 'pulse.overview').actor = 'guest';
  const result = validate(documents);
  assert.match(messages(result), /unknown actor: guest/);
});

test('route without capability fails', () => {
  const documents = docs();
  documents.routeMap.routes.push({
    routeId: 'route.orphan',
    capabilityId: 'not.a.capability',
    canonicalDestinationId: 'pulse',
    authGate: 'signed-in',
    coldLaunch: true,
    warmLaunch: true
  });
  const result = validate(documents);
  assert.match(messages(result), /unknown capabilityId: not.a.capability/);
});

test('routable capability without route map entry fails', () => {
  const documents = docs();
  documents.registry.capabilities.find((item) => item.capabilityId === 'pulse.overview').routeIds = [];
  documents.routeMap.routes = [{
    routeId: 'route.other',
    capabilityId: 'auth.row',
    canonicalDestinationId: 'pulse',
    authGate: 'signed-in',
    coldLaunch: true,
    warmLaunch: true
  }];
  const result = validate(documents);
  assert.match(messages(result), /missing from the route map: pulse.overview/);
});

test('implemented capability without surfaces fails', () => {
  const documents = docs();
  const pulse = documents.registry.capabilities.find((item) => item.capabilityId === 'pulse.overview');
  pulse.iosSurface = { views: [], stores: [], services: [], tests: [] };
  pulse.androidSurface = { views: [], stores: [], services: [], tests: [] };
  const result = validate(documents);
  assert.match(messages(result), /must list at least one platform surface/);
});

test('dirty candidate cannot close a row', () => {
  const documents = docs();
  const row = documents.ledger.rows.find((item) => item.id === 'VAL-MOB-001');
  row.status = 'validated';
  row.evidenceFreshness = 'fresh';
  row.result = 'PASS';
  const result = validate(documents, {
    fingerprint: { commitSha: HEAD, dirty: true, dirtyEntries: [' M dirty.txt'] }
  });
  assert.match(messages(result), /dirty tree cannot be a closable candidate|silent PASS/);
});

test('unattributed evidence fails', () => {
  const root = seedRepo({ 'docs/mobile-parity/evidence/shot.png': 'png-bytes\n' });
  const documents = docs();
  const row = documents.ledger.rows.find((item) => item.id === 'VAL-MOB-002');
  row.evidencePointers = [{ path: 'docs/mobile-parity/evidence/shot.png' }];
  const result = validate(documents, { repoRoot: root });
  assert.match(messages(result), /unattributed evidence/);
});

test('path escape fails', () => {
  const documents = docs();
  documents.registry.capabilities.find((item) => item.capabilityId === 'pulse.overview')
    .iosSurface.views = ['../secret.swift'];
  const result = validate(documents);
  assert.match(messages(result), /not a canonical repository-relative POSIX path|escapes the repository/);
});

test('absolute path outside the repo fails', () => {
  const documents = docs();
  documents.registry.capabilities.find((item) => item.capabilityId === 'pulse.overview')
    .iosSurface.views = ['/etc/passwd'];
  const result = validate(documents);
  assert.match(messages(result), /absolute paths are forbidden/);
});

test('empty evidence file fails', () => {
  const root = seedRepo({ 'docs/mobile-parity/evidence/empty.txt': '' });
  const documents = docs();
  const row = documents.ledger.rows.find((item) => item.id === 'VAL-MOB-002');
  row.evidencePointers = [{ path: 'docs/mobile-parity/evidence/empty.txt', candidateSha: HEAD }];
  const result = validate(documents, { repoRoot: root });
  assert.match(messages(result), /empty evidence file/);
});

test('placeholder evidence file fails', () => {
  const root = seedRepo({ 'docs/mobile-parity/evidence/note.txt': 'TODO insert screenshot\n' });
  const documents = docs();
  const row = documents.ledger.rows.find((item) => item.id === 'VAL-MOB-002');
  row.evidencePointers = [{ path: 'docs/mobile-parity/evidence/note.txt', candidateSha: HEAD }];
  const result = validate(documents, { repoRoot: root });
  assert.match(messages(result), /placeholder evidence/);
});

test('historical evidence cannot satisfy a fresh/PASS close', () => {
  const documents = docs();
  const row = documents.ledger.rows.find((item) => item.id === 'VAL-MOB-002');
  row.status = 'validated';
  row.evidenceFreshness = 'historical';
  const result = validate(documents);
  assert.match(messages(result), /historical\/stale evidence cannot satisfy|silent PASS/);
});

test('productParityClaim true while blocked rows remain is a structural failure', () => {
  const documents = docs();
  documents.ledger.semantics.productParityClaim = true;
  const result = validate(documents);
  assert.equal(result.structuralPassed, false);
  assert.match(messages(result), /productParityClaim=true contradicts/);
});

test('missing VAL contract fails', () => {
  const documents = docs();
  documents.ledger.rows = documents.ledger.rows.filter((row) => row.id !== 'VAL-MOB-007');
  const result = validate(documents);
  assert.match(messages(result), /missing required VAL contract VAL-MOB-007/);
});

test('capability ledger row missing from ledger fails', () => {
  const documents = docs();
  documents.ledger.rows = documents.ledger.rows.filter((row) => row.capabilityId !== 'pulse.overview');
  const result = validate(documents);
  assert.match(messages(result), /missing capability row for pulse.overview/);
});

test('iOS and Android destination ids cannot silently drift', () => {
  const documents = docs();
  documents.routeMap.destinationCatalog.bindings = [{
    canonicalId: 'pulse',
    iosDestinationId: 'pulse',
    ipadDestinationId: 'pulse',
    androidDestinationId: 'home'
  }];
  const result = validate(documents);
  assert.match(messages(result), /silently drift for pulse/);
});

test('simulator-only evidence cannot satisfy a physical-device floor', () => {
  const root = seedRepo({ 'docs/mobile-parity/evidence/sim.txt': 'booted simulator\n' });
  const documents = docs();
  const row = documents.ledger.rows.find((item) => item.id === 'VAL-MOB-002');
  row.evidenceFloor = ['physical device'];
  row.evidencePointers = [{
    path: 'docs/mobile-parity/evidence/sim.txt',
    candidateSha: HEAD,
    simulatorOnly: true
  }];
  const result = validate(documents, { repoRoot: root });
  assert.match(messages(result), /simulator-only evidence cannot satisfy a physical-device floor/);
});

test('validated status is forbidden without fresh evidence', () => {
  const documents = docs();
  documents.registry.capabilities.find((item) => item.capabilityId === 'pulse.overview').status = 'validated';
  const result = validate(documents);
  assert.match(messages(result), /validated is forbidden/);
});

test('resolveConfinedPath rejects parent traversal and accepts in-repo files', () => {
  const root = seedRepo({ 'docs/ok.txt': 'ok\n' });
  assert.equal(resolveConfinedPath(root, '../etc/passwd').error.includes('canonical')
    || resolveConfinedPath(root, '../etc/passwd').error.includes('escapes'), true);
  const ok = resolveConfinedPath(root, 'docs/ok.txt');
  assert.equal(ok.exists, true);
  assert.equal(resolveConfinedPath(root, '/tmp/x').error, 'absolute paths are forbidden');
});

test('blocked row without missing prerequisite fails', () => {
  const documents = docs();
  const row = documents.ledger.rows.find((item) => item.id === 'VAL-MOB-002');
  delete row.missingPrerequisite;
  const result = validate(documents);
  assert.match(messages(result), /blocked row must name the missing prerequisite/);
});
