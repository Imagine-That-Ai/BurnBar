import crypto from 'node:crypto';
import {
  SHA256_PATTERN,
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng
} from './installed-ui-proof.mjs';

export const P09_REQUIREMENT_ID = 'P-09';
export const P09_PROOF_ROLE = 'feature.navigation-shell-installed';
export const P09_PROOF_FILENAME = 'navigation-shell-installed.json';
export const P09_SESSION_FILENAME = 'p09-installed-navigation-shell-session.json';
export const P09_REQUIRED_ROUTES = Object.freeze([
  'overview', 'insights', 'database', 'providers', 'projects', 'missions',
  'activity', 'chat', 'memory', 'settings', 'account', 'updates', 'support',
  'onboarding', 'pet', 'text-expansion', 'computer-use', 'mercury', 'smarthub'
]);

const EXPECTED_NAMES = Object.freeze({
  overview: 'Overview', insights: 'Insights', database: 'Database', providers: 'Providers & models',
  projects: 'Projects', missions: 'Missions', activity: 'Activity & logs', chat: 'Chat / Hermes',
  memory: 'Memory', settings: 'Settings', account: 'Account & sync', updates: 'Updates',
  support: 'Support & diagnostics', onboarding: 'First-run setup', pet: 'Pet companion',
  'text-expansion': 'Text expansion', 'computer-use': 'Computer Use', mercury: 'Mercury',
  smarthub: 'SmartHub / IoT'
});

function artifact(repoRoot, environmentId, record, label, mediaType, minimumBytes) {
  return validateArtifact(repoRoot, record, P09_REQUIREMENT_ID, environmentId, label, { mediaType, minimumBytes });
}

function validCapturedIdentity(document, expected, captureStart, captureEnd) {
  const capturedAt = Date.parse(document.capturedAt);
  return document.appPid === expected.appPid
    && document.windowId === expected.windowId
    && (expected.capturedAt === undefined || document.capturedAt === expected.capturedAt)
    && document.desktop === expected.desktop
    && document.displayServer === expected.displayServer
    && document.manifestSha256 === expected.manifestSha256
    && Number.isFinite(capturedAt) && capturedAt >= captureStart && capturedAt <= captureEnd;
}

function validateAtspi(snapshot, route, expectedName, label, expected, captureStart, captureEnd) {
  const document = parseJson(snapshot.bytes, label);
  exactKeys(document, [
    'actionableNodeCount', 'appPid', 'capturedAt', 'desktop', 'displayServer',
    'expectedName', 'expectedNamePresent', 'manifestSha256', 'namedNodeCount',
    'namedSamples', 'nodeCount', 'producer', 'route', 'windowId'
  ], label);
  if (document.producer !== 'openburnbar-p09-native-route-probe-v1'
      || document.route !== route || document.expectedName !== expectedName
      || document.expectedNamePresent !== true || document.nodeCount < 10
      || document.namedNodeCount < 3 || document.actionableNodeCount < 1
      || !Array.isArray(document.namedSamples)
      || !validCapturedIdentity(document, expected, captureStart, captureEnd)) {
    throw new Error(`${label} does not expose the activated route through AT-SPI`);
  }
  return crypto.createHash('sha256').update(JSON.stringify({
    route: document.route, expectedName: document.expectedName,
    nodes: (document.namedSamples ?? []).map((row) => ({ role: row.role, name: row.name, states: row.states, actions: row.actions }))
  })).digest('hex');
}

function validateNavigation(repoRoot, environmentId, navigation, captureStart, captureEnd, identity) {
  exactKeys(navigation, ['method', 'perfSamples', 'routes'], 'P-09 navigation');
  if (navigation.method !== 'atspi-command-palette-actions' || !Array.isArray(navigation.routes)
      || navigation.routes.length !== P09_REQUIRED_ROUTES.length) {
    throw new Error('P-09 navigation must activate every route through installed AT-SPI actions');
  }
  const perf = artifact(repoRoot, environmentId, navigation.perfSamples, 'P-09 route performance samples', undefined, 20);
  const perfSources = new Set();
  for (const [index, line] of perf.bytes.toString('utf8').split(/\n/u).filter(Boolean).entries()) {
    let row;
    try { row = JSON.parse(line); } catch { throw new Error(`P-09 route performance row ${index} is not JSON`); }
    const at = Date.parse(row.at);
    if (row.name === 'route.navigation' && Number.isFinite(at) && at >= captureStart && at <= captureEnd
        && typeof row.source === 'string'
        && row.source.startsWith('packaged-ui-route-after-paint:')) {
      perfSources.add(row.source.slice('packaged-ui-route-after-paint:'.length));
    }
  }
  const seen = new Set();
  const artifacts = [navigation.perfSamples];
  const screenshotHashes = new Set();
  const atspiHashes = new Set();
  for (const [index, row] of navigation.routes.entries()) {
    exactKeys(row, [
      'activated', 'appPid', 'atspi', 'capturedAt', 'expectedName', 'index',
      'navMethod', 'route', 'screenshot', 'window', 'windowId'
    ], `P-09 route ${index}`);
    const expectedRoute = P09_REQUIRED_ROUTES[index];
    if (row.index !== index || row.route !== expectedRoute || row.expectedName !== EXPECTED_NAMES[expectedRoute]
        || row.activated !== true || row.navMethod !== 'atspi-command-palette-actions'
        || !Number.isSafeInteger(row.appPid) || row.appPid < 1
        || typeof row.windowId !== 'string' || row.windowId.length === 0
        || !Number.isFinite(Date.parse(row.capturedAt))
        || seen.has(row.route) || !perfSources.has(row.route)) {
      throw new Error(`P-09 route ${expectedRoute} is missing exact installed activation or post-paint evidence`);
    }
    seen.add(row.route);
    const atspi = artifact(repoRoot, environmentId, row.atspi, `P-09 ${row.route} AT-SPI`, 'json', 100);
    const routeIdentity = { ...identity, appPid: row.appPid, windowId: row.windowId, capturedAt: row.capturedAt };
    const semanticHash = validateAtspi(
      atspi, row.route, row.expectedName, `P-09 ${row.route} AT-SPI`,
      routeIdentity, captureStart, captureEnd
    );
    const screenshot = artifact(repoRoot, environmentId, row.screenshot, `P-09 ${row.route} screenshot`, 'png', 100);
    const decoded = validatePng(screenshot.bytes, `P-09 ${row.route} screenshot`);
    const window = artifact(repoRoot, environmentId, row.window, `P-09 ${row.route} window record`, 'json', 100);
    const pixelHash = crypto.createHash('sha256').update(decoded.pixels).digest('hex');
    if (decoded.nonBlankPixelRatio < 0.2 || screenshotHashes.has(pixelHash) || atspiHashes.has(semanticHash)) {
      throw new Error(`P-09 ${row.route} reuses another route's visual or AT-SPI bytes`);
    }
    screenshotHashes.add(pixelHash);
    atspiHashes.add(semanticHash);
    const windowDocument = parseJson(window.bytes, `P-09 ${row.route} window record`);
    exactKeys(windowDocument, [
      'appPid', 'capturedAt', 'desktop', 'displayServer', 'focused', 'geometry',
      'manifestSha256', 'producer', 'route', 'visible', 'windowId'
    ], `P-09 ${row.route} window record`);
    exactKeys(windowDocument.geometry, ['height', 'width', 'x', 'y'], `P-09 ${row.route} window geometry`);
    if (windowDocument.producer !== 'openburnbar-p09-native-route-window-probe-v1'
        || windowDocument.route !== row.route || windowDocument.capturedAt !== row.capturedAt
        || !validCapturedIdentity(windowDocument, routeIdentity, captureStart, captureEnd)
        || windowDocument.visible !== true || windowDocument.focused !== true
        || windowDocument.geometry.width < 320 || windowDocument.geometry.height < 200
        || !Number.isFinite(windowDocument.geometry.x) || !Number.isFinite(windowDocument.geometry.y)) {
      throw new Error(`P-09 ${row.route} window record has no usable geometry`);
    }
    artifacts.push(row.atspi, row.screenshot, row.window);
  }
  return artifacts;
}

function validateDeepLinks(repoRoot, environmentId, rows, captureStart, captureEnd, identity) {
  if (!Array.isArray(rows) || rows.length !== 2) throw new Error('P-09 requires provider and model deep-link proof');
  const kinds = new Set();
  const artifacts = [];
  for (const row of rows) {
    exactKeys(row, [
      'atspi', 'eventLog', 'kind', 'screenshot', 'selectedModelId', 'selectedProviderId', 'uri'
    ], 'P-09 deep link');
    if (!['provider', 'model'].includes(row.kind) || kinds.has(row.kind)
        || typeof row.uri !== 'string' || !row.uri.startsWith('openburnbar://providers?provider=')
        || typeof row.selectedProviderId !== 'string' || row.selectedProviderId.length === 0
        || (row.kind === 'provider' ? row.selectedModelId !== null : typeof row.selectedModelId !== 'string')) {
      throw new Error(`P-09 ${row.kind ?? 'unknown'} deep link did not prove relaunch, history, and focus`);
    }
    const url = new URL(row.uri);
    if (url.searchParams.get('provider') !== row.selectedProviderId
        || (row.kind === 'model' && url.searchParams.get('model') !== row.selectedModelId)
        || [...url.searchParams.keys()].some((key) => !['provider', 'model'].includes(key))) {
      throw new Error(`P-09 ${row.kind} deep link has an invalid or mismatched destination`);
    }
    kinds.add(row.kind);
    const eventLog = artifact(repoRoot, environmentId, row.eventLog, `P-09 ${row.kind} deep-link event log`, 'json', 200);
    const events = parseJson(eventLog.bytes, `P-09 ${row.kind} deep-link event log`);
    exactKeys(events, ['events', 'producer'], `P-09 ${row.kind} deep-link event log`);
    const required = ['native-link-accepted', 'single-instance-forwarded', 'history-reload-restored', 'back-forward-restored', 'focus-restored'];
    if (events.producer !== 'openburnbar-p09-native-deep-link-probe-v1'
        || !Array.isArray(events.events) || events.events.length !== required.length) {
      throw new Error(`P-09 ${row.kind} deep-link event log is incomplete`);
    }
    let previousAt = -Infinity;
    for (const [index, event] of events.events.entries()) {
      exactKeys(event, ['appPid', 'at', 'desktop', 'displayServer', 'kind', 'manifestSha256', 'passed', 'uri', 'windowId'], `P-09 ${row.kind} deep-link event ${index}`);
      const at = Date.parse(event.at);
      if (event.kind !== required[index] || event.passed !== true || event.uri !== row.uri
          || !Number.isSafeInteger(event.appPid) || event.appPid < 1 || typeof event.windowId !== 'string'
          || event.desktop !== identity.desktop || event.displayServer !== identity.displayServer
          || event.manifestSha256 !== identity.manifestSha256
          || !Number.isFinite(at) || at <= previousAt || at < captureStart || at > captureEnd) {
        throw new Error(`P-09 ${row.kind} deep-link event sequence is not capture-bound`);
      }
      previousAt = at;
    }
    const atspi = artifact(repoRoot, environmentId, row.atspi, `P-09 ${row.kind} deep-link AT-SPI`, 'json', 100);
    const tree = parseJson(atspi.bytes, `P-09 ${row.kind} deep-link AT-SPI`);
    exactKeys(tree, [
      'actionableNodeCount', 'appPid', 'capturedAt', 'desktop', 'displayServer',
      'expectedName', 'expectedNamePresent', 'manifestSha256', 'namedNodeCount',
      'namedSamples', 'nodeCount', 'producer', 'windowId'
    ], `P-09 ${row.kind} deep-link AT-SPI`);
    const finalEvent = events.events.at(-1);
    if (tree.producer !== 'openburnbar-p09-native-deep-link-probe-v1'
        || tree.expectedNamePresent !== true || tree.nodeCount < 10 || tree.actionableNodeCount < 1
        || !Array.isArray(tree.namedSamples)
        || !validCapturedIdentity(tree, { ...identity, appPid: finalEvent.appPid, windowId: finalEvent.windowId }, captureStart, captureEnd)) {
      throw new Error(`P-09 ${row.kind} deep link has no live accessible destination`);
    }
    artifact(repoRoot, environmentId, row.screenshot, `P-09 ${row.kind} deep-link screenshot`, 'png', 100);
    artifacts.push(row.eventLog, row.atspi, row.screenshot);
  }
  return artifacts;
}

function validateWindows(repoRoot, environmentId, record, captureStart, captureEnd, identity) {
  const snapshot = artifact(repoRoot, environmentId, record, 'P-09 native window event log', 'json', 300);
  const document = parseJson(snapshot.bytes, 'P-09 native window event log');
  exactKeys(document, ['events', 'producer'], 'P-09 native window event log');
  const required = ['secondary-window-opened', 'secondary-window-closed-focus-restored', 'relaunch-state-restored', 'multi-monitor-geometry-restored', 'geometry-bounds-verified'];
  if (document.producer !== 'openburnbar-p09-native-window-probe-v1'
      || !Array.isArray(document.events) || document.events.length !== required.length) {
    throw new Error('P-09 native window event log is incomplete');
  }
  let previousAt = -Infinity;
  let initialPid = null;
  let relaunchedPid = null;
  for (const [index, event] of document.events.entries()) {
    exactKeys(event, ['appPid', 'at', 'desktop', 'displayServer', 'geometry', 'kind', 'manifestSha256', 'passed', 'windowId'], `P-09 window event ${index}`);
    const at = Date.parse(event.at);
    exactKeys(event.geometry, ['height', 'width', 'x', 'y'], `P-09 window event ${index} geometry`);
    if (event.kind !== required[index] || event.passed !== true || !Number.isFinite(at)
        || at <= previousAt || at < captureStart || at > captureEnd || typeof event.windowId !== 'string'
        || !Number.isSafeInteger(event.appPid) || event.appPid < 1
        || event.desktop !== identity.desktop || event.displayServer !== identity.displayServer
        || event.manifestSha256 !== identity.manifestSha256
        || event.geometry.width < 320 || event.geometry.height < 200
        || !Number.isFinite(event.geometry.x) || !Number.isFinite(event.geometry.y)) {
      throw new Error('P-09 secondary-window and restore behavior is incomplete');
    }
    previousAt = at;
    if (index === 0) initialPid = event.appPid;
    if (event.kind === 'relaunch-state-restored') relaunchedPid = event.appPid;
    if (index > 2 && relaunchedPid !== null && event.appPid !== relaunchedPid) throw new Error('P-09 post-relaunch window identity changed unexpectedly');
  }
  if (initialPid === relaunchedPid) throw new Error('P-09 relaunch did not transition to a new installed app PID');
  return record;
}

export function validateP09InstalledSession(document, binding, { repoRoot }) {
  exactKeys(document, [
    'candidate', 'capture', 'deepLinks', 'desktop', 'environmentId', 'id',
    'navigation', 'package', 'requirementId', 'schemaVersion', 'targetHead', 'windows'
  ], 'P-09 installed session');
  if (document.schemaVersion !== 1 || document.id !== 'openburnbar-linux-p09-installed-session-v1') {
    throw new Error('P-09 installed session schema is unsupported');
  }
  const envelope = validateInstalledSessionEnvelope(document, { ...binding, repoRoot }, P09_REQUIREMENT_ID, 'P-09 installed session');
  const identity = { desktop: document.desktop.desktop, displayServer: document.desktop.displayServer, manifestSha256: document.package.manifest.sha256 };
  const evidence = [
    ...envelope.attestation,
    ...validateNavigation(repoRoot, binding.environmentId, document.navigation, envelope.startedAt, envelope.endedAt, identity),
    ...validateDeepLinks(repoRoot, binding.environmentId, document.deepLinks, envelope.startedAt, envelope.endedAt, identity),
    validateWindows(repoRoot, binding.environmentId, document.windows, envelope.startedAt, envelope.endedAt, identity)
  ];
  const unique = new Set();
  for (const record of evidence) {
    if (unique.has(record.path)) throw new Error(`P-09 repeats evidence artifact ${record.path}`);
    unique.add(record.path);
  }
  return { document, evidence, endedAt: envelope.endedAt };
}

export function buildP09Proof({ session, sessionRecord, collectedAt }) {
  return {
    schemaVersion: 1,
    id: 'openburnbar-linux-p09-navigation-shell-proof-v1',
    requirementId: P09_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    collectedAt,
    source: {
      method: 'live-installed-navigation-shell-session',
      ...sessionRecord
    },
    claim: {
      passed: true,
      routeCount: session.navigation.routes.length,
      deepLinkKinds: session.deepLinks.map((row) => row.kind).sort(),
      secondaryWindowPassed: true
    }
  };
}

export function validateP09Proof({ repoRoot, snapshot, ...binding }) {
  const proof = parseJson(snapshot.bytes, 'P-09 navigation-shell proof');
  exactKeys(proof, [
    'candidate', 'claim', 'collectedAt', 'environmentId', 'id', 'requirementId',
    'schemaVersion', 'source', 'targetHead'
  ], 'P-09 navigation-shell proof');
  if (proof.schemaVersion !== 1 || proof.id !== 'openburnbar-linux-p09-navigation-shell-proof-v1'
      || proof.requirementId !== P09_REQUIREMENT_ID || proof.environmentId !== binding.environmentId
      || proof.targetHead !== binding.targetHead) {
    throw new Error('P-09 navigation-shell proof is not invocation-bound');
  }
  exactKeys(proof.source, ['method', 'path', 'sha256', 'size'], 'P-09 proof source');
  if (proof.source.method !== 'live-installed-navigation-shell-session'
      || !SHA256_PATTERN.test(proof.source.sha256 ?? '')) {
    throw new Error('P-09 proof does not reference a live installed session');
  }
  const sessionSnapshot = artifact(repoRoot, binding.environmentId, {
    path: proof.source.path, sha256: proof.source.sha256, size: proof.source.size
  }, 'P-09 proof source session', 'json', 500);
  const validated = validateP09InstalledSession(parseJson(sessionSnapshot.bytes, 'P-09 proof source session'), binding, { repoRoot });
  validateCollectedAt(proof.collectedAt, validated.endedAt);
  exactKeys(proof.claim, ['deepLinkKinds', 'passed', 'routeCount', 'secondaryWindowPassed'], 'P-09 claim');
  if (proof.claim.passed !== true || proof.claim.routeCount !== P09_REQUIRED_ROUTES.length
      || proof.claim.secondaryWindowPassed !== true
      || JSON.stringify(proof.claim.deepLinkKinds) !== JSON.stringify(['model', 'provider'])) {
    throw new Error('P-09 proof claim does not match the validated installed session');
  }
  return { proof, source: sessionSnapshot, evidence: validated.evidence };
}
