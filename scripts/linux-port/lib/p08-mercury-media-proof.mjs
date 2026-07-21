import crypto from 'node:crypto';
import { readRegularSnapshot, SUPPORT_ENVIRONMENTS } from './product-proof-closure.mjs';

export const P08_REQUIREMENT_ID = 'P-08';
export const P08_PROOF_ROLE = 'feature.mercury-media-installed';
export const P08_PROOF_FILENAME = 'mercury-media-installed.json';
export const P08_SESSION_FILENAME = 'p08-installed-mercury-media-session.json';
export const P08_DESKTOP_OBSERVATION_FILENAME = 'p08-linux-desktop-observation.json';
export const P08_DEVICE_OBSERVATION_FILENAME = 'p08-physical-device-observation.json';

export const P08_TARGET_IDS = Object.freeze([
  'pairing',
  'presence',
  'file-send',
  'file-receive',
  'call-accepted',
  'call-rejected',
  'call-cancelled',
  'screen-share-consent',
  'screen-share-render',
  'permission-denied',
  'permission-revoked',
  'packet-loss-recovery',
  'transport-reconnect',
  'suspend-resume',
  'codec-absence',
  'unpair-repair',
  'cleanup'
]);

export const P08_SOURCE_CONTRACTS = Object.freeze([
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/MercuryLinuxMediaSessionController.swift',
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/MercuryLinuxCaptureEngine.swift',
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCMedia.swift',
  'apps/linux-desktop/src-tauri/src/desktop/account_media_commands.rs',
  'apps/linux-desktop/src/surfaces/media/MediaSection.tsx',
  'scripts/linux-port/run-p08-mercury-media-session.mjs'
]);

const SOURCE_MARKERS = Object.freeze({
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/MercuryLinuxMediaSessionController.swift': [
    'acceptFile', 'declineFile', 'sendFile', 'accept(', 'decline(', 'end('
  ],
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/MercuryLinuxCaptureEngine.swift': [
    'MercuryLinuxMediaCapabilities', 'PipeWire', 'GStreamer'
  ],
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCMedia.swift': [
    'daemonMediaCallAccept', 'daemonMediaFileSend', 'daemonMediaSessionState'
  ],
  'apps/linux-desktop/src-tauri/src/desktop/account_media_commands.rs': [
    'daemon.media.call.accept', 'daemon.media.file.send', 'daemon.media.session.state'
  ],
  'apps/linux-desktop/src/surfaces/media/MediaSection.tsx': [
    'MercuryCallHUD', 'MercuryFileTransferPanel', 'Paired Mercury devices'
  ],
  'scripts/linux-port/run-p08-mercury-media-session.mjs': [
    'verifyInstalledCandidate', 'validateP08Observation', 'fresh live observations'
  ]
});

const HEAD = /^[a-f0-9]{40,64}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const VERSION = /^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$/u;
const DEVICE_PLATFORMS = new Set(['ios', 'ipados', 'android', 'macos']);

function object(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value;
}

function exact(value, keys, label) {
  object(value, label);
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    throw new Error(`${label} fields must be exactly: ${expected.join(', ')}`);
  }
}

function nonEmpty(value, label) {
  if (typeof value !== 'string' || value.trim().length === 0) throw new Error(`${label} must be a non-empty string`);
  return value;
}

function finiteNumber(value, label, { minimum = 0, maximum = Number.MAX_SAFE_INTEGER } = {}) {
  if (!Number.isFinite(value) || value < minimum || value > maximum) {
    throw new Error(`${label} must be between ${minimum} and ${maximum}`);
  }
  return value;
}

function timestamp(value, label) {
  const millis = Date.parse(value);
  if (typeof value !== 'string' || !Number.isFinite(millis) || !/^\d{4}-\d{2}-\d{2}T/u.test(value)) {
    throw new Error(`${label} must be an RFC3339 timestamp`);
  }
  return millis;
}

function trueFields(metrics, fields, targetId) {
  for (const field of fields) {
    if (metrics[field] !== true) throw new Error(`P-08 ${targetId}.${field} is not proven`);
  }
}

function zero(value, label) {
  if (value !== 0) throw new Error(`${label} must be zero`);
}

function validateTargetMetrics(targetId, metrics) {
  object(metrics, `P-08 ${targetId} metrics`);
  switch (targetId) {
    case 'pairing':
      exact(metrics, ['authenticated', 'peerIdentityMatched', 'unauthorizedPeerRejected'], 'P-08 pairing metrics');
      trueFields(metrics, ['authenticated', 'peerIdentityMatched', 'unauthorizedPeerRejected'], targetId);
      break;
    case 'presence':
      exact(metrics, ['heartbeatIntervalMs', 'offlineObserved', 'onlineObserved', 'reconnected'], 'P-08 presence metrics');
      trueFields(metrics, ['offlineObserved', 'onlineObserved', 'reconnected'], targetId);
      finiteNumber(metrics.heartbeatIntervalMs, 'P-08 presence heartbeatIntervalMs', { minimum: 1, maximum: 60_000 });
      break;
    case 'file-send':
    case 'file-receive':
      exact(metrics, ['bytesTransferred', 'contentSha256', 'receivedSha256', 'resumedAfterInterruption', 'terminalCleanup'], `P-08 ${targetId} metrics`);
      finiteNumber(metrics.bytesTransferred, `P-08 ${targetId} bytesTransferred`, { minimum: 1 });
      if (!SHA256.test(metrics.contentSha256 ?? '') || metrics.receivedSha256 !== metrics.contentSha256) {
        throw new Error(`P-08 ${targetId} content digest did not survive transfer`);
      }
      trueFields(metrics, ['resumedAfterInterruption', 'terminalCleanup'], targetId);
      break;
    case 'call-accepted':
      exact(metrics, ['bidirectionalAudio', 'bidirectionalVideo', 'durationMs', 'mediaFramesAfterTerminal'], 'P-08 call-accepted metrics');
      trueFields(metrics, ['bidirectionalAudio', 'bidirectionalVideo'], targetId);
      finiteNumber(metrics.durationMs, 'P-08 call durationMs', { minimum: 5_000, maximum: 3_600_000 });
      zero(metrics.mediaFramesAfterTerminal, 'P-08 call mediaFramesAfterTerminal');
      break;
    case 'call-rejected':
    case 'call-cancelled':
      exact(metrics, ['mediaFramesAfterTerminal', 'terminalObserved', 'userVisibleReason'], `P-08 ${targetId} metrics`);
      trueFields(metrics, ['terminalObserved', 'userVisibleReason'], targetId);
      zero(metrics.mediaFramesAfterTerminal, `P-08 ${targetId} mediaFramesAfterTerminal`);
      break;
    case 'screen-share-consent':
      exact(metrics, ['deviceConsent', 'linuxPortalConsent', 'oneShotGrant', 'silentGrantRejected'], 'P-08 screen-share-consent metrics');
      trueFields(metrics, ['deviceConsent', 'linuxPortalConsent', 'oneShotGrant', 'silentGrantRejected'], targetId);
      break;
    case 'screen-share-render':
      exact(metrics, ['framesRendered', 'mirroringObserved', 'multiMonitorSelection', 'p95LatencyMs', 'sealedFramesVerified'], 'P-08 screen-share-render metrics');
      trueFields(metrics, ['mirroringObserved', 'multiMonitorSelection', 'sealedFramesVerified'], targetId);
      finiteNumber(metrics.framesRendered, 'P-08 screen-share framesRendered', { minimum: 30 });
      finiteNumber(metrics.p95LatencyMs, 'P-08 screen-share p95LatencyMs', { minimum: 0, maximum: 250 });
      break;
    case 'permission-denied':
    case 'permission-revoked':
      exact(metrics, ['failClosed', 'framesAfterTerminal', 'userVisibleReason'], `P-08 ${targetId} metrics`);
      trueFields(metrics, ['failClosed', 'userVisibleReason'], targetId);
      zero(metrics.framesAfterTerminal, `P-08 ${targetId} framesAfterTerminal`);
      break;
    case 'packet-loss-recovery':
      exact(metrics, ['lossPercent', 'queueBounded', 'recovered', 'recoveryMs'], 'P-08 packet-loss-recovery metrics');
      trueFields(metrics, ['queueBounded', 'recovered'], targetId);
      finiteNumber(metrics.lossPercent, 'P-08 injected lossPercent', { minimum: 5, maximum: 30 });
      finiteNumber(metrics.recoveryMs, 'P-08 packet-loss recoveryMs', { minimum: 0, maximum: 30_000 });
      break;
    case 'transport-reconnect':
      exact(metrics, ['duplicateTerminalEvents', 'reconnects', 'recovered', 'recoveryMs'], 'P-08 transport-reconnect metrics');
      trueFields(metrics, ['recovered'], targetId);
      finiteNumber(metrics.reconnects, 'P-08 reconnect count', { minimum: 1, maximum: 20 });
      finiteNumber(metrics.recoveryMs, 'P-08 reconnect recoveryMs', { minimum: 0, maximum: 30_000 });
      zero(metrics.duplicateTerminalEvents, 'P-08 duplicateTerminalEvents');
      break;
    case 'suspend-resume':
      exact(metrics, ['recovered', 'recoveryMs', 'resumed', 'staleFramesRejected', 'suspended'], 'P-08 suspend-resume metrics');
      trueFields(metrics, ['recovered', 'resumed', 'staleFramesRejected', 'suspended'], targetId);
      finiteNumber(metrics.recoveryMs, 'P-08 suspend recoveryMs', { minimum: 0, maximum: 60_000 });
      break;
    case 'codec-absence':
      exact(metrics, ['capabilityUnavailable', 'falseSuccessClaim', 'sessionStartRejected', 'userVisibleReason'], 'P-08 codec-absence metrics');
      trueFields(metrics, ['capabilityUnavailable', 'sessionStartRejected', 'userVisibleReason'], targetId);
      if (metrics.falseSuccessClaim !== false) throw new Error('P-08 codec absence was accepted as a false success');
      break;
    case 'unpair-repair':
      exact(metrics, ['removedBothSides', 'rePairSucceeded', 'staleSessionRejected'], 'P-08 unpair-repair metrics');
      trueFields(metrics, ['removedBothSides', 'rePairSucceeded', 'staleSessionRejected'], targetId);
      break;
    case 'cleanup':
      exact(metrics, ['noActiveSession', 'noBackgroundCapture', 'partialFilesRemoved', 'portalClosed', 'temporaryFilesRemoved'], 'P-08 cleanup metrics');
      trueFields(metrics, ['noActiveSession', 'noBackgroundCapture', 'partialFilesRemoved', 'portalClosed', 'temporaryFilesRemoved'], targetId);
      break;
    default:
      throw new Error(`unknown P-08 target: ${targetId}`);
  }
}

function validateCandidate(candidate, binding, label) {
  exact(candidate, ['artifactDigest', 'runId'], label);
  if (!RUN_ID.test(candidate.runId ?? '') || !DIGEST.test(candidate.artifactDigest ?? '')
      || candidate.runId !== String(binding.candidateRunId)
      || candidate.artifactDigest !== binding.candidateArtifactDigest) {
    throw new Error(`${label} does not match the selected release candidate`);
  }
}

function validateSessionBinding(session, expected, label) {
  exact(session, ['challengeNonce', 'developerOverride', 'encryption', 'fixtureMode', 'id', 'transport'], label);
  if (!UUID.test(session.id ?? '') || !SHA256.test(session.challengeNonce ?? '')
      || session.transport !== 'iroh-quic' || session.encryption !== 'paired-ed25519-e2e'
      || session.fixtureMode !== false || session.developerOverride !== false) {
    throw new Error(`${label} is not a real paired Mercury session`);
  }
  if (expected && (session.id !== expected.id || session.challengeNonce !== expected.challengeNonce)) {
    throw new Error(`${label} does not match the paired session challenge`);
  }
}

function validateHardware(hardware, side) {
  exact(hardware, ['architecture', 'deviceIdHash', 'formFactor', 'model', 'osName', 'osVersion', 'physical', 'simulator'], `P-08 ${side} hardware`);
  if (!SHA256.test(hardware.deviceIdHash ?? '') || typeof hardware.physical !== 'boolean' || hardware.simulator !== false) {
    throw new Error(`P-08 ${side} observation has invalid hardware provenance`);
  }
  for (const field of ['architecture', 'formFactor', 'model', 'osName', 'osVersion']) nonEmpty(hardware[field], `P-08 ${side} hardware.${field}`);
  if (side === 'physical-device' && (hardware.physical !== true
      || !DEVICE_PLATFORMS.has(hardware.osName.toLowerCase())
      || !['phone', 'tablet', 'desktop'].includes(hardware.formFactor))) {
    throw new Error('P-08 paired peer is not a supported physical device');
  }
  if (side === 'linux-desktop' && (hardware.osName.toLowerCase() !== 'linux' || hardware.formFactor !== 'desktop')) {
    throw new Error('P-08 desktop observation is not Linux desktop hardware');
  }
}

function validateProducer(producer, side, targetHead) {
  exact(producer, ['buildCommit', 'id', 'source', 'version'], `P-08 ${side} producer`);
  if (producer.buildCommit !== targetHead || !VERSION.test(producer.version ?? '')) {
    throw new Error(`P-08 ${side} producer is not built from the target HEAD`);
  }
  const expected = side === 'linux-desktop'
    ? { id: 'openburnbar-daemon', source: 'installed-signed-candidate' }
    : { id: 'openburnbar-mobile', source: 'installed-physical-device-app' };
  if (producer.id !== expected.id || producer.source !== expected.source) {
    throw new Error(`P-08 ${side} producer is not an installed product runtime`);
  }
}

function validateEventChain(chain, expectedCount, side) {
  exact(chain, ['algorithm', 'entryCount', 'tamperCheckPassed', 'terminalSha256', 'verified'], `P-08 ${side} event chain`);
  if (chain.algorithm !== 'sha256' || chain.entryCount !== expectedCount
      || !SHA256.test(chain.terminalSha256 ?? '') || chain.verified !== true
      || chain.tamperCheckPassed !== true) {
    throw new Error(`P-08 ${side} event chain is incomplete or unverified`);
  }
}

export function p08EventChainTerminal(events, challengeNonce) {
  if (!Array.isArray(events) || !SHA256.test(challengeNonce ?? '')) {
    throw new Error('P-08 event-chain input is invalid');
  }
  let head = crypto.createHash('sha256')
    .update(Buffer.from(`openburnbar-p08-event-chain-v1\0${challengeNonce}`, 'utf8'))
    .digest();
  for (const event of events) {
    head = crypto.createHash('sha256')
      .update(head)
      .update(Buffer.from(JSON.stringify(event), 'utf8'))
      .digest();
  }
  return head.toString('hex');
}

function normalizeEvents(events, captureStart, captureEnd, side) {
  if (!Array.isArray(events) || events.length !== P08_TARGET_IDS.length) {
    throw new Error(`P-08 ${side} observation must contain exactly ${P08_TARGET_IDS.length} target events`);
  }
  const byId = new Map();
  for (const [index, event] of events.entries()) {
    exact(event, ['endedAt', 'metrics', 'startedAt', 'status', 'targetId'], `P-08 ${side} event ${index}`);
    if (!P08_TARGET_IDS.includes(event.targetId) || byId.has(event.targetId) || event.status !== 'passed') {
      throw new Error(`P-08 ${side} target set is incomplete, duplicated, or not passed`);
    }
    if (event.targetId !== P08_TARGET_IDS[index]) {
      throw new Error(`P-08 ${side} target events are not in canonical order`);
    }
    const started = timestamp(event.startedAt, `P-08 ${side} ${event.targetId}.startedAt`);
    const ended = timestamp(event.endedAt, `P-08 ${side} ${event.targetId}.endedAt`);
    if (started < captureStart || ended > captureEnd || ended < started) {
      throw new Error(`P-08 ${side} ${event.targetId} timestamps escape the capture interval`);
    }
    validateTargetMetrics(event.targetId, event.metrics);
    byId.set(event.targetId, event);
  }
  for (const targetId of P08_TARGET_IDS) if (!byId.has(targetId)) throw new Error(`P-08 ${side} is missing ${targetId}`);
  return byId;
}

export function validateP08Observation(document, binding, expectedSide, expectedSession = null) {
  exact(document, ['candidate', 'capture', 'environmentId', 'eventChain', 'events', 'hardware', 'id', 'producer', 'requirementId', 'schemaVersion', 'session', 'side', 'targetHead'], `P-08 ${expectedSide} observation`);
  if (document.schemaVersion !== 1 || document.id !== 'openburnbar-p08-mercury-observation-v1'
      || document.requirementId !== P08_REQUIREMENT_ID || document.side !== expectedSide
      || document.environmentId !== binding.environmentId || document.targetHead !== binding.targetHead
      || !HEAD.test(document.targetHead ?? '')) {
    throw new Error(`P-08 ${expectedSide} observation is not invocation-bound`);
  }
  validateCandidate(document.candidate, binding, `P-08 ${expectedSide} candidate`);
  exact(document.capture, ['endedAt', 'mode', 'startedAt'], `P-08 ${expectedSide} capture`);
  if (document.capture.mode !== 'installed-live-product') throw new Error(`P-08 ${expectedSide} capture is fixture or source-only evidence`);
  const captureStart = timestamp(document.capture.startedAt, `P-08 ${expectedSide} capture.startedAt`);
  const captureEnd = timestamp(document.capture.endedAt, `P-08 ${expectedSide} capture.endedAt`);
  if (captureEnd < captureStart || captureEnd - captureStart > 4 * 60 * 60 * 1000) throw new Error(`P-08 ${expectedSide} capture interval is invalid`);
  validateSessionBinding(document.session, expectedSession, `P-08 ${expectedSide} session`);
  validateHardware(document.hardware, expectedSide);
  validateProducer(document.producer, expectedSide, binding.targetHead);
  const events = normalizeEvents(document.events, captureStart, captureEnd, expectedSide);
  validateEventChain(document.eventChain, events.size, expectedSide);
  if (document.eventChain.terminalSha256 !== p08EventChainTerminal(document.events, document.session.challengeNonce)) {
    throw new Error(`P-08 ${expectedSide} event chain terminal does not authenticate its events`);
  }
  return { document, events, captureStart, captureEnd };
}

function expectedEnvironment(environmentId) {
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId)) throw new Error('P-08 environment is outside the support matrix');
  const architecture = environmentId.endsWith('-aarch64') ? 'aarch64' : 'x86_64';
  const session = environmentId.includes('-x11-') ? 'x11' : 'wayland';
  if (environmentId.startsWith('ubuntu-')) return { architecture, session, desktop: 'gnome', os: 'ubuntu', version: '24.04', format: 'deb' };
  if (environmentId.startsWith('fedora-')) return { architecture, session, desktop: 'kde', os: 'fedora', version: null, format: 'rpm' };
  return { architecture, session, desktop: 'sway', os: 'arch', version: null, format: 'arch' };
}

function parseSnapshot(snapshot, label) {
  try { return JSON.parse(snapshot.bytes.toString('utf8')); } catch (error) { throw new Error(`${label} is not JSON: ${error.message}`); }
}

function validateRawEvidence(repoRoot, rows, binding, expectedSession) {
  if (!Array.isArray(rows) || rows.length !== 2) throw new Error('P-08 session requires exactly two raw observation artifacts');
  const observations = new Map();
  for (const row of rows) {
    exact(row, ['path', 'sha256', 'side'], 'P-08 raw evidence row');
    if (!['linux-desktop', 'physical-device'].includes(row.side) || observations.has(row.side)
        || !SHA256.test(row.sha256 ?? '') || typeof row.path !== 'string'
        || !row.path.startsWith('docs/linux-port/evidence/product-parity-inputs/P-08/')) {
      throw new Error('P-08 raw observation evidence is noncanonical');
    }
    const expectedName = row.side === 'linux-desktop' ? P08_DESKTOP_OBSERVATION_FILENAME : P08_DEVICE_OBSERVATION_FILENAME;
    if (!row.path.endsWith(`/${expectedName}`) || /fixture|sample|mock/iu.test(row.path)) {
      throw new Error('P-08 raw observation evidence is fixture-like or misnamed');
    }
    const snapshot = readRegularSnapshot(repoRoot, row.path, `P-08 ${row.side} raw observation`);
    if (snapshot.sha256 !== row.sha256) throw new Error(`P-08 ${row.side} raw observation bytes changed`);
    const observation = parseSnapshot(snapshot, `P-08 ${row.side} raw observation`);
    observations.set(row.side, validateP08Observation(observation, binding, row.side, expectedSession));
  }
  if (observations.size !== 2) throw new Error('P-08 raw evidence does not include both installed Linux and physical device observations');
  const desktop = observations.get('linux-desktop');
  const device = observations.get('physical-device');
  if (desktop.captureStart > device.captureEnd || device.captureStart > desktop.captureEnd) {
    throw new Error('P-08 paired observations do not overlap in time');
  }
  validatePairedAgreement(desktop.events, device.events);
  return observations;
}

export function validatePairedAgreement(desktopEvents, deviceEvents) {
  for (const targetId of P08_TARGET_IDS) {
    if (!desktopEvents.has(targetId) || !deviceEvents.has(targetId)) {
      throw new Error(`P-08 paired observations do not both contain ${targetId}`);
    }
  }
  for (const targetId of ['file-send', 'file-receive']) {
    const desktop = desktopEvents.get(targetId).metrics;
    const device = deviceEvents.get(targetId).metrics;
    if (desktop.contentSha256 !== device.contentSha256
        || desktop.receivedSha256 !== device.receivedSha256
        || desktop.bytesTransferred !== device.bytesTransferred) {
      throw new Error(`P-08 paired observations disagree on ${targetId} payload identity`);
    }
  }
  const desktopPair = desktopEvents.get('pairing').metrics;
  const devicePair = deviceEvents.get('pairing').metrics;
  if (desktopPair.peerIdentityMatched !== true || devicePair.peerIdentityMatched !== true) {
    throw new Error('P-08 paired observations do not agree on authenticated peer identity');
  }
}

export function validateP08InstalledMediaSession(document, binding, { repoRoot } = {}) {
  exact(document, ['candidate', 'capture', 'environmentId', 'id', 'package', 'passed', 'peer', 'rawEvidence', 'requirementId', 'schemaVersion', 'session', 'targetHead', 'targets'], 'P-08 installed media session');
  if (document.schemaVersion !== 1 || document.id !== 'openburnbar-linux-p08-installed-mercury-media-session-v1'
      || document.requirementId !== P08_REQUIREMENT_ID || document.environmentId !== binding.environmentId
      || document.targetHead !== binding.targetHead || document.passed !== true) {
    throw new Error('P-08 installed media session is not a passed invocation-bound session');
  }
  validateCandidate(document.candidate, binding, 'P-08 session candidate');
  validateSessionBinding(document.session, null, 'P-08 installed media session binding');
  const expected = expectedEnvironment(binding.environmentId);
  exact(document.capture, ['architecture', 'desktop', 'mode', 'os', 'platform', 'session'], 'P-08 installed capture');
  exact(document.capture.os, ['id', 'versionId'], 'P-08 installed capture os');
  if (document.capture.mode !== 'installed-linux-paired-physical-device' || document.capture.platform !== 'linux'
      || document.capture.architecture !== expected.architecture || document.capture.session.toLowerCase() !== expected.session
      || !document.capture.desktop.toLowerCase().includes(expected.desktop) || document.capture.os.id !== expected.os
      || (expected.version !== null && document.capture.os.versionId !== expected.version)) {
    throw new Error('P-08 capture does not match the installed support environment');
  }
  exact(document.package, ['architecture', 'format', 'installed', 'manifestSha256', 'manifestSignatureSha256', 'source', 'version'], 'P-08 package');
  if (document.package.architecture !== expected.architecture || document.package.format !== expected.format
      || document.package.installed !== true || document.package.source !== 'signed-installed-candidate'
      || !SHA256.test(document.package.manifestSha256 ?? '')
      || !SHA256.test(document.package.manifestSignatureSha256 ?? '')
      || !VERSION.test(document.package.version ?? '')) {
    throw new Error('P-08 package is not the signed installed candidate');
  }
  validateHardware(document.peer, 'physical-device');
  if (repoRoot === undefined) throw new Error('P-08 validator requires raw paired observation bytes');
  const observations = validateRawEvidence(repoRoot, document.rawEvidence, binding, document.session);
  const expectedTargets = P08_TARGET_IDS.map((targetId) => ({
    targetId,
    desktopMetrics: structuredClone(observations.get('linux-desktop').events.get(targetId).metrics),
    deviceMetrics: structuredClone(observations.get('physical-device').events.get(targetId).metrics),
    passed: true
  }));
  if (JSON.stringify(document.targets) !== JSON.stringify(expectedTargets)) {
    throw new Error('P-08 installed session targets do not exactly match paired raw observations');
  }
  if (JSON.stringify(document.peer) !== JSON.stringify(observations.get('physical-device').document.hardware)) {
    throw new Error('P-08 installed session peer does not match the physical-device observation');
  }
  return { document, observations };
}

export function canonicalP08SourceEvidence(repoRoot) {
  return P08_SOURCE_CONTRACTS.map((relativePath) => {
    const snapshot = readRegularSnapshot(repoRoot, relativePath, `P-08 source ${relativePath}`);
    for (const marker of SOURCE_MARKERS[relativePath]) {
      if (!snapshot.bytes.toString('utf8').includes(marker)) throw new Error(`${relativePath} is missing P-08 source marker ${marker}`);
    }
    return { path: relativePath, sha256: snapshot.sha256 };
  });
}

function validateSources(repoRoot, rows) {
  if (!Array.isArray(rows) || rows.length !== P08_SOURCE_CONTRACTS.length) throw new Error('P-08 source evidence is incomplete');
  const expected = canonicalP08SourceEvidence(repoRoot);
  if (JSON.stringify(rows) !== JSON.stringify(expected)) throw new Error('P-08 source evidence is stale or noncanonical');
}

export function validateP08MercuryMediaProof({
  repoRoot, snapshot, sourceSnapshot, environmentId, targetHead, candidateRunId, candidateArtifactDigest
}) {
  const document = parseSnapshot(snapshot, 'P-08 Mercury media proof');
  exact(document, ['candidate', 'environmentId', 'observed', 'passed', 'requirementId', 'schemaVersion', 'source', 'sourceEvidence', 'targetHead'], 'P-08 Mercury media proof');
  if (document.schemaVersion !== 1 || document.requirementId !== P08_REQUIREMENT_ID
      || document.environmentId !== environmentId || document.targetHead !== targetHead || document.passed !== true) {
    throw new Error('P-08 proof is not a passed candidate-bound proof');
  }
  const binding = { environmentId, targetHead, candidateRunId, candidateArtifactDigest };
  validateCandidate(document.candidate, binding, 'P-08 proof candidate');
  exact(document.source, ['method', 'path', 'sha256'], 'P-08 proof source');
  if (document.source.method !== 'installed-linux-physical-device-session'
      || !document.source.path.endsWith(`/${P08_SESSION_FILENAME}`) || !SHA256.test(document.source.sha256 ?? '')) {
    throw new Error('P-08 proof source is not a live installed session');
  }
  if (!document.source.path.startsWith('docs/linux-port/evidence/product-parity-inputs/P-08/')) {
    throw new Error('P-08 proof source is outside the requirement evidence root');
  }
  const source = sourceSnapshot ?? readRegularSnapshot(repoRoot, document.source.path, 'P-08 installed media session source');
  if (source.sha256 !== document.source.sha256) throw new Error('P-08 installed media session source bytes changed');
  const observedBytes = Buffer.from(`${JSON.stringify(document.observed, null, 2)}\n`);
  if (!source.bytes.equals(observedBytes)) throw new Error('P-08 proof observed value does not exactly match its live session source');
  validateP08InstalledMediaSession(document.observed, binding, { repoRoot });
  validateSources(repoRoot, document.sourceEvidence);
  return document;
}

export function sha256P08(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

export function p08SourceContractMarkers() {
  return Object.fromEntries(Object.entries(SOURCE_MARKERS).map(([key, markers]) => [key, [...markers]]));
}
