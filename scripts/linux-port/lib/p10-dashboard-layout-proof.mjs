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

export const P10_REQUIREMENT_ID = 'P-10';
export const P10_PROOF_ROLE = 'feature.dashboard-layouts-installed';
export const P10_PROOF_FILENAME = 'dashboard-layouts-installed.json';
export const P10_SESSION_FILENAME = 'p10-installed-dashboard-layout-session.json';
export const P10_LAYOUTS = Object.freeze(['classic', 'aurora', 'nebula', 'constellation', 'cockpit', 'atelier']);
export const P10_VIEWPORTS = Object.freeze(['desktop', 'compact']);
export const P10_STATES = Object.freeze(['error', 'loading', 'offline', 'populated']);

function artifact(repoRoot, environmentId, record, label, mediaType, minimumBytes) {
  return validateArtifact(repoRoot, record, P10_REQUIREMENT_ID, environmentId, label, { mediaType, minimumBytes });
}

function validateAtspi(snapshot, layout, viewport, label, expected, captureStart, captureEnd) {
  const document = parseJson(snapshot.bytes, label);
  exactKeys(document, [
    'actionableNodeCount', 'appPid', 'capturedAt', 'desktop', 'displayServer',
    'expectedName', 'expectedNamePresent', 'layout', 'manifestSha256',
    'namedNodeCount', 'namedSamples', 'nodeCount', 'producer', 'viewport', 'windowId'
  ], label);
  const capturedAt = Date.parse(document.capturedAt);
  if (document.producer !== 'openburnbar-p10-native-dashboard-probe-v1'
      || document.layout !== layout || document.viewport !== viewport
      || document.expectedName !== `${layout[0].toUpperCase()}${layout.slice(1)} dashboard layout`
      || document.expectedNamePresent !== true || document.nodeCount < 10
      || document.namedNodeCount < 3 || document.actionableNodeCount < 1
      || !Array.isArray(document.namedSamples)
      || document.appPid !== expected.appPid || document.windowId !== expected.windowId
      || document.desktop !== expected.desktop || document.displayServer !== expected.displayServer
      || document.manifestSha256 !== expected.manifestSha256 || document.capturedAt !== expected.capturedAt
      || !Number.isFinite(capturedAt) || capturedAt < captureStart || capturedAt > captureEnd) {
    throw new Error(`${label} does not expose the selected installed dashboard layout`);
  }
  return document;
}

function validatePixelAudit(snapshot, screenshot, geometry, viewport, label) {
  const audit = parseJson(snapshot.bytes, label);
  const image = validatePng(screenshot.bytes, `${label} screenshot`);
  exactKeys(audit, [
    'clippedElementCount', 'height', 'nonBlankPixelRatio', 'overlapFindingCount',
    'geometrySha256', 'producer', 'screenshotSha256', 'textOverflowCount',
    'unreadableTextCount', 'width'
  ], label);
  const minimumWidth = viewport === 'desktop' ? 1024 : 320;
  const maximumWidth = viewport === 'compact' ? 768 : Number.MAX_SAFE_INTEGER;
  if (audit.producer !== 'openburnbar-p10-materializer-v1' || audit.geometrySha256 !== geometry.sha256
      || audit.screenshotSha256 !== screenshot.sha256 || audit.width !== image.width || audit.height !== image.height
      || audit.width < minimumWidth || audit.width > maximumWidth || audit.height < 600
      || Math.abs(audit.nonBlankPixelRatio - image.nonBlankPixelRatio) > 0.000001
      || image.nonBlankPixelRatio < 0.2 || image.nonBlankPixelRatio > 1
      || audit.clippedElementCount !== 0 || audit.overlapFindingCount !== 0
      || audit.textOverflowCount !== 0 || audit.unreadableTextCount !== 0) {
    throw new Error(`${label} did not prove a nonblank, unclipped, readable layout`);
  }
  return image;
}

function validateCaptures(repoRoot, environmentId, captures, captureStart, captureEnd, identity) {
  const expectedCount = P10_LAYOUTS.length * P10_VIEWPORTS.length;
  if (!Array.isArray(captures) || captures.length !== expectedCount) {
    throw new Error('P-10 requires every dashboard layout at desktop and compact widths');
  }
  const seen = new Set();
  const screenshotHashes = new Set();
  const atspiHashes = new Map();
  const evidence = [];
  for (const row of captures) {
    exactKeys(row, [
      'atspi', 'daemon', 'events', 'geometry', 'layout', 'pixelAudit', 'renderBackend', 'screenshot', 'viewport'
    ], 'P-10 layout capture');
    const key = `${row.layout}:${row.viewport}`;
    if (!P10_LAYOUTS.includes(row.layout) || !P10_VIEWPORTS.includes(row.viewport) || seen.has(key)
        || typeof row.renderBackend !== 'string' || /(?:placeholder|fixture|mock|storybook)/iu.test(row.renderBackend)) {
      throw new Error(`P-10 layout capture ${key} is duplicated or not installed-product evidence`);
    }
    seen.add(key);
    const daemonSnapshot = artifact(repoRoot, environmentId, row.daemon, `P-10 ${key} daemon snapshot`, 'json', 120);
    const daemon = parseJson(daemonSnapshot.bytes, `P-10 ${key} daemon snapshot`);
    exactKeys(daemon, ['connected', 'fixtureMode', 'producer', 'providerCount', 'usagePointCount'], `P-10 ${key} daemon snapshot`);
    if (daemon.producer !== 'openburnbar-cli-live-dashboard-probe-v1' || daemon.connected !== true || daemon.fixtureMode !== false
        || !Number.isSafeInteger(daemon.providerCount) || daemon.providerCount < 1
        || !Number.isSafeInteger(daemon.usagePointCount) || daemon.usagePointCount < 1) {
      throw new Error(`P-10 layout capture ${key} did not render live daemon content`);
    }
    const eventSnapshot = artifact(repoRoot, environmentId, row.events, `P-10 ${key} event log`, 'json', 200);
    const eventLog = parseJson(eventSnapshot.bytes, `P-10 ${key} event log`);
    exactKeys(eventLog, ['events', 'producer'], `P-10 ${key} event log`);
    const required = ['layout-selected-atspi', 'app-relaunched', 'persisted-layout-readback'];
    if (eventLog.producer !== 'openburnbar-p10-native-layout-probe-v1'
        || !Array.isArray(eventLog.events) || eventLog.events.length !== required.length) {
      throw new Error(`P-10 ${key} event log is incomplete`);
    }
    let previousAt = -Infinity;
    let initialPid = null;
    let relaunchedPid = null;
    for (const [index, event] of eventLog.events.entries()) {
      exactKeys(event, ['appPid', 'at', 'desktop', 'displayServer', 'kind', 'layout', 'manifestSha256', 'passed', 'viewport', 'windowId'], `P-10 ${key} event ${index}`);
      const at = Date.parse(event.at);
      if (event.kind !== required[index] || event.layout !== row.layout || event.viewport !== row.viewport
          || event.passed !== true || !Number.isSafeInteger(event.appPid) || event.appPid < 1
          || typeof event.windowId !== 'string' || event.desktop !== identity.desktop
          || event.displayServer !== identity.displayServer || event.manifestSha256 !== identity.manifestSha256
          || !Number.isFinite(at) || at <= previousAt || at < captureStart || at > captureEnd) {
        throw new Error(`P-10 ${key} did not prove AT-SPI selection and relaunch persistence`);
      }
      previousAt = at;
      if (index === 0) initialPid = event.appPid;
      if (event.kind === 'app-relaunched') relaunchedPid = event.appPid;
    }
    if (initialPid === relaunchedPid || eventLog.events[2].appPid !== relaunchedPid) {
      throw new Error(`P-10 ${key} relaunch did not transition to a stable new app PID`);
    }
    const screenshot = artifact(repoRoot, environmentId, row.screenshot, `P-10 ${key} screenshot`, 'png', 1024);
    const atspi = artifact(repoRoot, environmentId, row.atspi, `P-10 ${key} AT-SPI`, 'json', 100);
    const readbackEvent = eventLog.events[2];
    const tree = validateAtspi(atspi, row.layout, row.viewport, `P-10 ${key} AT-SPI`, {
      ...identity, appPid: readbackEvent.appPid, windowId: readbackEvent.windowId,
      capturedAt: readbackEvent.at
    }, captureStart, captureEnd);
    const semanticHash = crypto.createHash('sha256').update(JSON.stringify({
      expectedName: tree.expectedName,
      nodes: (tree.namedSamples ?? []).map((item) => ({ role: item.role, name: item.name, states: item.states, actions: item.actions }))
    })).digest('hex');
    if (atspiHashes.has(semanticHash) && atspiHashes.get(semanticHash) !== row.layout) {
      throw new Error(`P-10 ${key} reuses another layout's semantic AT-SPI tree`);
    }
    atspiHashes.set(semanticHash, row.layout);
    const geometry = artifact(repoRoot, environmentId, row.geometry, `P-10 ${key} geometry`, 'json', 180);
    const geometryDocument = parseJson(geometry.bytes, `P-10 ${key} geometry`);
    exactKeys(geometryDocument, [
      'capturedAt', 'clippedElements', 'nodesInspected', 'overlaps', 'producer',
      'sourceAtspiSha256', 'textOverflow', 'unreadableText'
    ], `P-10 ${key} geometry`);
    const geometryAt = Date.parse(geometryDocument.capturedAt);
    if (geometryDocument.producer !== 'openburnbar-p10-live-geometry-probe-v1'
        || geometryDocument.sourceAtspiSha256 !== atspi.sha256
        || !Number.isSafeInteger(geometryDocument.nodesInspected) || geometryDocument.nodesInspected < 1
        || !Number.isFinite(geometryAt) || geometryAt < captureStart || geometryAt > captureEnd) {
      throw new Error(`P-10 ${key} geometry is not bound to the live AT-SPI capture`);
    }
    for (const field of ['clippedElements', 'overlaps', 'textOverflow', 'unreadableText']) {
      if (!Array.isArray(geometryDocument[field])) throw new Error(`P-10 ${key} geometry ${field} must be an array`);
    }
    const pixelAudit = artifact(repoRoot, environmentId, row.pixelAudit, `P-10 ${key} pixel audit`, 'json', 100);
    const image = validatePixelAudit(pixelAudit, screenshot, geometry, row.viewport, `P-10 ${key} pixel audit`);
    const pixelHash = crypto.createHash('sha256').update(image.pixels).digest('hex');
    if (screenshotHashes.has(pixelHash)) throw new Error(`P-10 ${key} reuses another layout capture's decoded pixels`);
    screenshotHashes.add(pixelHash);
    evidence.push(row.events, row.daemon, row.screenshot, row.atspi, row.geometry, row.pixelAudit);
  }
  for (const layout of P10_LAYOUTS) for (const viewport of P10_VIEWPORTS) {
    if (!seen.has(`${layout}:${viewport}`)) throw new Error(`P-10 is missing ${layout}:${viewport}`);
  }
  return evidence;
}

function validateStates(repoRoot, environmentId, states, captureStart, captureEnd, identity) {
  exactKeys(states, ['eventLog', 'snapshots'], 'P-10 state matrix');
  const eventSnapshot = artifact(repoRoot, environmentId, states.eventLog, 'P-10 state event log', 'json', 250);
  const eventLog = parseJson(eventSnapshot.bytes, 'P-10 state event log');
  exactKeys(eventLog, ['events', 'producer'], 'P-10 state event log');
  const order = ['loading', 'populated', 'offline', 'error'];
  if (eventLog.producer !== 'openburnbar-p10-native-state-probe-v1'
      || !Array.isArray(eventLog.events) || eventLog.events.length !== order.length
      || !Array.isArray(states.snapshots) || states.snapshots.length !== order.length) {
    throw new Error('P-10 state transition evidence is incomplete');
  }
  let previousAt = -Infinity;
  const evidence = [states.eventLog];
  for (const [index, event] of eventLog.events.entries()) {
    exactKeys(event, ['appPid', 'at', 'desktop', 'displayServer', 'manifestSha256', 'passed', 'state', 'windowId'], `P-10 state event ${index}`);
    const at = Date.parse(event.at);
    if (event.state !== order[index] || event.passed !== true || !Number.isSafeInteger(event.appPid)
        || event.appPid < 1 || typeof event.windowId !== 'string' || event.desktop !== identity.desktop
        || event.displayServer !== identity.displayServer || event.manifestSha256 !== identity.manifestSha256
        || !Number.isFinite(at) || at <= previousAt || at < captureStart || at > captureEnd) {
      throw new Error('P-10 state transition sequence is not capture-bound');
    }
    previousAt = at;
    const row = states.snapshots[index];
    exactKeys(row, ['atspi', 'state'], `P-10 state snapshot ${index}`);
    if (row.state !== event.state) throw new Error('P-10 state snapshot order does not match its event');
    const treeSnapshot = artifact(repoRoot, environmentId, row.atspi, `P-10 ${row.state} state AT-SPI`, 'json', 100);
    const tree = parseJson(treeSnapshot.bytes, `P-10 ${row.state} state AT-SPI`);
    exactKeys(tree, [
      'alertRolePresent', 'appPid', 'ariaBusy', 'capturedAt', 'desktop',
      'displayServer', 'expectedNamePresent', 'layoutNamePresent', 'manifestSha256',
      'producer', 'state', 'statusRolePresent', 'windowId'
    ], `P-10 ${row.state} state AT-SPI`);
    if (tree.producer !== 'openburnbar-p10-native-state-probe-v1'
        || tree.state !== row.state || tree.expectedNamePresent !== true
        || tree.appPid !== event.appPid || tree.windowId !== event.windowId || tree.capturedAt !== event.at
        || tree.desktop !== identity.desktop || tree.displayServer !== identity.displayServer
        || tree.manifestSha256 !== identity.manifestSha256
        || (row.state === 'loading' && tree.ariaBusy !== true)
        || (row.state === 'populated' && tree.layoutNamePresent !== true)
        || (row.state === 'offline' && tree.statusRolePresent !== true)
        || (row.state === 'error' && tree.alertRolePresent !== true)) {
      throw new Error(`P-10 ${row.state} state lacks installed AT-SPI semantics`);
    }
    evidence.push(row.atspi);
  }
  return evidence;
}

export function validateP10InstalledSession(document, binding, { repoRoot }) {
  exactKeys(document, [
    'candidate', 'capture', 'captures', 'desktop', 'environmentId', 'id', 'package',
    'requirementId', 'schemaVersion', 'states', 'targetHead'
  ], 'P-10 installed session');
  if (document.schemaVersion !== 1 || document.id !== 'openburnbar-linux-p10-installed-session-v1') {
    throw new Error('P-10 installed session schema is unsupported');
  }
  const envelope = validateInstalledSessionEnvelope(document, { ...binding, repoRoot }, P10_REQUIREMENT_ID, 'P-10 installed session');
  const identity = { desktop: document.desktop.desktop, displayServer: document.desktop.displayServer, manifestSha256: document.package.manifest.sha256 };
  const evidence = [
    ...envelope.attestation,
    ...validateCaptures(repoRoot, binding.environmentId, document.captures, envelope.startedAt, envelope.endedAt, identity),
    ...validateStates(repoRoot, binding.environmentId, document.states, envelope.startedAt, envelope.endedAt, identity)
  ];
  const unique = new Set();
  for (const record of evidence) {
    if (unique.has(record.path)) throw new Error(`P-10 repeats evidence artifact ${record.path}`);
    unique.add(record.path);
  }
  return { document, evidence, endedAt: envelope.endedAt };
}

export function buildP10Proof({ session, sessionRecord, collectedAt }) {
  return {
    schemaVersion: 1,
    id: 'openburnbar-linux-p10-dashboard-layout-proof-v1',
    requirementId: P10_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    collectedAt,
    source: {
      method: 'live-installed-dashboard-layout-session',
      ...sessionRecord
    },
    claim: {
      passed: true,
      layouts: [...P10_LAYOUTS],
      states: [...P10_STATES],
      viewportCount: P10_VIEWPORTS.length,
      captureCount: session.captures.length
    }
  };
}

export function validateP10Proof({ repoRoot, snapshot, ...binding }) {
  const proof = parseJson(snapshot.bytes, 'P-10 dashboard-layout proof');
  exactKeys(proof, [
    'candidate', 'claim', 'collectedAt', 'environmentId', 'id', 'requirementId',
    'schemaVersion', 'source', 'targetHead'
  ], 'P-10 dashboard-layout proof');
  if (proof.schemaVersion !== 1 || proof.id !== 'openburnbar-linux-p10-dashboard-layout-proof-v1'
      || proof.requirementId !== P10_REQUIREMENT_ID || proof.environmentId !== binding.environmentId
      || proof.targetHead !== binding.targetHead) {
    throw new Error('P-10 dashboard-layout proof is not invocation-bound');
  }
  exactKeys(proof.source, ['method', 'path', 'sha256', 'size'], 'P-10 proof source');
  if (proof.source.method !== 'live-installed-dashboard-layout-session'
      || !SHA256_PATTERN.test(proof.source.sha256 ?? '')) {
    throw new Error('P-10 proof does not reference a live installed session');
  }
  const sessionSnapshot = artifact(repoRoot, binding.environmentId, {
    path: proof.source.path, sha256: proof.source.sha256, size: proof.source.size
  }, 'P-10 proof source session', 'json', 500);
  const validated = validateP10InstalledSession(parseJson(sessionSnapshot.bytes, 'P-10 proof source session'), binding, { repoRoot });
  validateCollectedAt(proof.collectedAt, validated.endedAt);
  exactKeys(proof.claim, ['captureCount', 'layouts', 'passed', 'states', 'viewportCount'], 'P-10 claim');
  if (proof.claim.passed !== true || proof.claim.captureCount !== P10_LAYOUTS.length * P10_VIEWPORTS.length
      || proof.claim.viewportCount !== P10_VIEWPORTS.length
      || JSON.stringify(proof.claim.layouts) !== JSON.stringify(P10_LAYOUTS)
      || JSON.stringify(proof.claim.states) !== JSON.stringify(P10_STATES)) {
    throw new Error('P-10 proof claim does not match the validated installed session');
  }
  return { proof, source: sessionSnapshot, evidence: validated.evidence };
}
