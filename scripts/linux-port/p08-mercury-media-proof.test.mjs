import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { captureP08MercuryMediaProof } from './capture-p08-mercury-media-proof.mjs';
import {
  P08_DESKTOP_OBSERVATION_FILENAME,
  P08_DEVICE_OBSERVATION_FILENAME,
  P08_PROOF_FILENAME,
  P08_PROOF_ROLE,
  P08_SESSION_FILENAME,
  P08_SOURCE_CONTRACTS,
  P08_TARGET_IDS,
  p08EventChainTerminal,
  p08SourceContractMarkers,
  validateP08InstalledMediaSession,
  validateP08MercuryMediaProof,
  validateP08Observation
} from './lib/p08-mercury-media-proof.mjs';
import { buildP08Session, verifyInstalledManifestSignature } from './run-p08-mercury-media-session.mjs';
import { RELEASE_ARCHITECTURES, SUPPORT_ENVIRONMENTS } from './lib/product-proof-closure.mjs';
import { validateProductRequirement } from './product-validators/P-08.mjs';

const ENVIRONMENT = 'ubuntu-24.04-gnome-wayland-x86_64';
const HEAD = 'a'.repeat(40);
const RUN_ID = '12345';
const DIGEST = `sha256:${'b'.repeat(64)}`;
const VERSION = '1.2.3';
const SESSION_ID = '12345678-1234-4234-9234-123456789abc';
const CHALLENGE = 'c'.repeat(64);
const START = '2026-07-20T12:00:00.000Z';
const END = '2026-07-20T12:10:00.000Z';

function write(file, bytes) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  return file;
}
function writeJson(file, value) { return write(file, `${JSON.stringify(value, null, 2)}\n`); }
function sha256(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }
function record(root, file) {
  const bytes = fs.readFileSync(file);
  return { path: path.relative(root, file).split(path.sep).join('/'), sha256: sha256(bytes), size: bytes.length };
}

function metrics() {
  return {
    pairing: { authenticated: true, peerIdentityMatched: true, unauthorizedPeerRejected: true },
    presence: { heartbeatIntervalMs: 10_000, offlineObserved: true, onlineObserved: true, reconnected: true },
    'file-send': { bytesTransferred: 65_536, contentSha256: 'd'.repeat(64), receivedSha256: 'd'.repeat(64), resumedAfterInterruption: true, terminalCleanup: true },
    'file-receive': { bytesTransferred: 65_537, contentSha256: 'e'.repeat(64), receivedSha256: 'e'.repeat(64), resumedAfterInterruption: true, terminalCleanup: true },
    'call-accepted': { bidirectionalAudio: true, bidirectionalVideo: true, durationMs: 8_000, mediaFramesAfterTerminal: 0 },
    'call-rejected': { mediaFramesAfterTerminal: 0, terminalObserved: true, userVisibleReason: true },
    'call-cancelled': { mediaFramesAfterTerminal: 0, terminalObserved: true, userVisibleReason: true },
    'screen-share-consent': { deviceConsent: true, linuxPortalConsent: true, oneShotGrant: true, silentGrantRejected: true },
    'screen-share-render': { framesRendered: 120, mirroringObserved: true, multiMonitorSelection: true, p95LatencyMs: 220, sealedFramesVerified: true },
    'permission-denied': { failClosed: true, framesAfterTerminal: 0, userVisibleReason: true },
    'permission-revoked': { failClosed: true, framesAfterTerminal: 0, userVisibleReason: true },
    'packet-loss-recovery': { lossPercent: 10, queueBounded: true, recovered: true, recoveryMs: 2_500 },
    'transport-reconnect': { duplicateTerminalEvents: 0, reconnects: 2, recovered: true, recoveryMs: 3_000 },
    'suspend-resume': { recovered: true, recoveryMs: 5_000, resumed: true, staleFramesRejected: true, suspended: true },
    'codec-absence': { capabilityUnavailable: true, falseSuccessClaim: false, sessionStartRejected: true, userVisibleReason: true },
    'unpair-repair': { removedBothSides: true, rePairSucceeded: true, staleSessionRejected: true },
    cleanup: { noActiveSession: true, noBackgroundCapture: true, partialFilesRemoved: true, portalClosed: true, temporaryFilesRemoved: true }
  };
}

function observation(side) {
  const allMetrics = metrics();
  const value = {
    schemaVersion: 1,
    id: 'openburnbar-p08-mercury-observation-v1',
    requirementId: 'P-08',
    side,
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidate: { runId: RUN_ID, artifactDigest: DIGEST },
    capture: { startedAt: START, endedAt: END, mode: 'installed-live-product' },
    session: {
      challengeNonce: CHALLENGE,
      developerOverride: false,
      encryption: 'paired-ed25519-e2e',
      fixtureMode: false,
      id: SESSION_ID,
      transport: 'iroh-quic'
    },
    hardware: side === 'linux-desktop' ? {
      architecture: 'x86_64', deviceIdHash: '1'.repeat(64), formFactor: 'desktop',
      model: 'QEMU ARM Virtual Machine host hardware', osName: 'linux', osVersion: 'Ubuntu 24.04',
      physical: false, simulator: false
    } : {
      architecture: 'arm64', deviceIdHash: '2'.repeat(64), formFactor: 'tablet',
      model: 'iPad', osName: 'ipados', osVersion: '26.0', physical: true, simulator: false
    },
    producer: side === 'linux-desktop' ? {
      buildCommit: HEAD, id: 'openburnbar-daemon', source: 'installed-signed-candidate', version: VERSION
    } : {
      buildCommit: HEAD, id: 'openburnbar-mobile', source: 'installed-physical-device-app', version: VERSION
    },
    events: P08_TARGET_IDS.map((targetId) => ({
      targetId,
      status: 'passed',
      startedAt: START,
      endedAt: END,
      metrics: allMetrics[targetId]
    })),
    eventChain: {
      algorithm: 'sha256', entryCount: P08_TARGET_IDS.length,
      tamperCheckPassed: true, terminalSha256: '0'.repeat(64), verified: true
    }
  };
  value.eventChain.terminalSha256 = p08EventChainTerminal(value.events, CHALLENGE);
  return value;
}

function stageSources(root) {
  const markers = p08SourceContractMarkers();
  for (const sourcePath of P08_SOURCE_CONTRACTS) {
    const source = path.join(process.cwd(), sourcePath);
    const bytes = fs.existsSync(source) ? fs.readFileSync(source) : Buffer.from(`${markers[sourcePath].join('\n')}\n`);
    write(path.join(root, sourcePath), bytes);
  }
}

function createFixture() {
  const base = path.join(process.cwd(), '.tmp', 'p08-proof-tests');
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, 'case-'));
  stageSources(root);
  const inputRoot = path.join(root, 'docs/linux-port/evidence/product-parity-inputs/P-08', ENVIRONMENT);
  fs.mkdirSync(inputRoot, { recursive: true, mode: 0o700 });
  const desktopFile = writeJson(path.join(inputRoot, P08_DESKTOP_OBSERVATION_FILENAME), observation('linux-desktop'));
  const deviceFile = writeJson(path.join(inputRoot, P08_DEVICE_OBSERVATION_FILENAME), observation('physical-device'));
  const desktop = {
    document: JSON.parse(fs.readFileSync(desktopFile, 'utf8')),
    snapshot: { ...record(root, desktopFile), bytes: fs.readFileSync(desktopFile) },
    relative: record(root, desktopFile).path
  };
  const device = {
    document: JSON.parse(fs.readFileSync(deviceFile, 'utf8')),
    snapshot: { ...record(root, deviceFile), bytes: fs.readFileSync(deviceFile) },
    relative: record(root, deviceFile).path
  };
  const options = {
    environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST, manifestSha256: '3'.repeat(64),
    manifestSignatureSha256: '4'.repeat(64), packageVersion: VERSION
  };
  const installed = {
    contract: { architecture: 'x86_64', format: 'deb' },
    observedDesktop: 'gnome', observedSession: 'wayland',
    release: { ID: 'ubuntu', VERSION_ID: '24.04' }
  };
  const session = buildP08Session(options, installed, desktop, device);
  const sessionReport = writeJson(path.join(inputRoot, P08_SESSION_FILENAME), session);
  const captured = captureP08MercuryMediaProof({
    repoRoot: root, inputRoot, sessionReport, environmentId: ENVIRONMENT, targetHead: HEAD,
    candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST, resolveHead: () => HEAD
  });
  return { root, inputRoot, desktopFile, deviceFile, sessionReport, session, captured };
}

function cleanup(fixture) { fs.rmSync(fixture.root, { recursive: true, force: true }); }

function requirementContext(fixture) {
  const proofFile = path.join(fixture.inputRoot, 'feature-artifacts', P08_PROOF_FILENAME);
  const aggregateFile = writeJson(path.join(fixture.inputRoot, 'release-subjects/aggregate.json'), { passed: true });
  const manifestFile = writeJson(path.join(fixture.inputRoot, 'release-subjects/manifest.json'), {
    gitCommit: HEAD, packageArchitecture: 'x86_64', packageFormat: 'deb', packageVersion: VERSION
  });
  const runtimeFile = writeJson(path.join(fixture.inputRoot, 'release-subjects/runtime.json'), { shellVersion: VERSION, daemonVersion: VERSION });
  const environmentFile = writeJson(path.join(fixture.inputRoot, 'release-subjects/environment.json'), {
    environmentId: ENVIRONMENT, targetHead: HEAD, architecture: 'x86_64', passed: true
  });
  const signatureFile = write(path.join(fixture.inputRoot, 'release-subjects/manifest.sig'), 'signature\n');
  const packageFile = write(path.join(fixture.inputRoot, 'release-subjects/package.deb'), 'package\n');
  const aggregate = record(fixture.root, aggregateFile);
  const proof = record(fixture.root, proofFile);
  const manifest = record(fixture.root, manifestFile);
  const runtime = record(fixture.root, runtimeFile);
  const environment = record(fixture.root, environmentFile);
  const signature = record(fixture.root, signatureFile);
  const packageRecord = record(fixture.root, packageFile);
  const closure = {
    schemaVersion: 3, targetHead: HEAD, sourceCommit: HEAD, status: 'passed', requirementId: 'P-08',
    environmentId: ENVIRONMENT, version: VERSION, blockers: [], architectures: [...RELEASE_ARCHITECTURES],
    supportEnvironments: [...SUPPORT_ENVIRONMENTS], selectedPackage: { architecture: 'x86_64', format: 'deb' },
    candidate: { runId: RUN_ID, artifactDigest: DIGEST }, packageManifestSignature: signature,
    proofs: [{ role: 'aggregate-product-proof-closure', ...aggregate }, { role: P08_PROOF_ROLE, ...proof }]
  };
  return {
    schemaVersion: 1, repoRoot: fixture.root, requirementId: 'P-08', checkId: 'p-08.mercury-media',
    environmentId: ENVIRONMENT, targetHead: HEAD, releaseClosure: { document: closure },
    subjects: {
      release: aggregate, packageManifest: manifest, packages: [packageRecord], runtimes: [runtime],
      installation: [aggregate], environment,
      features: [{ role: P08_PROOF_ROLE, mediaType: 'application/json', ...proof }]
    }
  };
}

test('P-08 capture and independent validator accept exact installed Linux plus physical iPad evidence', async () => {
  const fixture = createFixture();
  try {
    assert.equal(fixture.captured.document.observed.targets.length, P08_TARGET_IDS.length);
    assert.deepEqual(JSON.parse(fs.readFileSync(fixture.captured.registration, 'utf8')).artifacts, [
      { role: P08_PROOF_ROLE, path: `feature-artifacts/${P08_PROOF_FILENAME}` }
    ]);
    assert.equal((await validateProductRequirement(requirementContext(fixture))).status, 'passed');
  } finally { cleanup(fixture); }
});

test('P-08 observation rejects simulator, fixture, stale candidate, weak capability, missing consent, and missing recovery claims', () => {
  const binding = { environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST };
  for (const [label, mutate, pattern] of [
    ['simulator', (value) => { value.hardware.simulator = true; }, /invalid hardware provenance/u],
    ['fixture', (value) => { value.capture.mode = 'fixture'; }, /fixture or source-only/u],
    ['candidate', (value) => { value.candidate.runId = '999'; }, /selected release candidate/u],
    ['capability only', (value) => { value.events.find((row) => row.targetId === 'screen-share-render').metrics.framesRendered = 0; }, /framesRendered/u],
    ['missing consent', (value) => { value.events.find((row) => row.targetId === 'screen-share-consent').metrics.deviceConsent = false; }, /deviceConsent/u],
    ['missing recovery', (value) => { value.events.find((row) => row.targetId === 'packet-loss-recovery').metrics.recovered = false; }, /recovered/u],
    ['event-chain mutation', (value) => { value.eventChain.terminalSha256 = '9'.repeat(64); }, /does not authenticate its events/u]
  ]) {
    const value = observation('physical-device');
    mutate(value);
    assert.throws(() => validateP08Observation(value, binding, 'physical-device'), pattern, label);
  }
});

test('P-08 paired session accepts side-local metrics but rejects missing targets and payload disagreement', () => {
  const binding = { environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST };
  const missing = observation('linux-desktop');
  missing.events.pop();
  assert.throws(() => validateP08Observation(missing, binding, 'linux-desktop'), /exactly 17 target events/u);

  const desktop = observation('linux-desktop');
  const device = observation('physical-device');
  device.events.find((row) => row.targetId === 'call-accepted').metrics.durationMs = 9_000;
  device.eventChain.terminalSha256 = p08EventChainTerminal(device.events, CHALLENGE);
  const wrapper = (document, relative) => ({
    document, relative, snapshot: { sha256: '4'.repeat(64), bytes: Buffer.from('observation') }
  });
  buildP08Session({
    environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST, manifestSha256: '3'.repeat(64),
    manifestSignatureSha256: '4'.repeat(64), packageVersion: VERSION
  }, {
    contract: { architecture: 'x86_64', format: 'deb' }, observedDesktop: 'gnome', observedSession: 'wayland',
    release: { ID: 'ubuntu', VERSION_ID: '24.04' }
  }, wrapper(desktop, 'desktop.json'), wrapper(device, 'device.json'));

  device.events.find((row) => row.targetId === 'file-send').metrics.contentSha256 = '9'.repeat(64);
  device.events.find((row) => row.targetId === 'file-send').metrics.receivedSha256 = '9'.repeat(64);
  device.eventChain.terminalSha256 = p08EventChainTerminal(device.events, CHALLENGE);
  assert.throws(() => buildP08Session({
    environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST, manifestSha256: '3'.repeat(64),
    manifestSignatureSha256: '4'.repeat(64), packageVersion: VERSION
  }, {
    contract: { architecture: 'x86_64', format: 'deb' }, observedDesktop: 'gnome', observedSession: 'wayland',
    release: { ID: 'ubuntu', VERSION_ID: '24.04' }
  }, wrapper(desktop, 'desktop.json'), wrapper(device, 'device.json')), /payload identity/u);
});

test('P-08 installed attestation rejects an unsigned or root-owned-but-forged manifest', () => {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const manifestBytes = Buffer.from('{"candidate":"exact"}\n');
  const signatureBytes = crypto.sign(null, manifestBytes, privateKey);
  const publicKeyBytes = publicKey.export({ type: 'spki', format: 'pem' });
  verifyInstalledManifestSignature({
    manifestBytes,
    signatureBytes,
    publicKeyBytes,
    expectedManifestSha256: sha256(manifestBytes),
    expectedSignatureSha256: sha256(signatureBytes)
  });
  const forged = Buffer.from('{"candidate":"forged"}\n');
  assert.throws(() => verifyInstalledManifestSignature({
    manifestBytes: forged,
    signatureBytes,
    publicKeyBytes,
    expectedManifestSha256: sha256(forged),
    expectedSignatureSha256: sha256(signatureBytes)
  }), /signature verification failed/u);
  assert.throws(() => verifyInstalledManifestSignature({
    manifestBytes,
    signatureBytes: Buffer.alloc(0),
    publicKeyBytes,
    expectedManifestSha256: sha256(manifestBytes),
    expectedSignatureSha256: sha256(Buffer.alloc(0))
  }), /must be Ed25519/u);
});

test('P-08 proof rejects source-only substitution and mutated raw physical-device bytes', () => {
  const fixture = createFixture();
  try {
    const proofBytes = fs.readFileSync(fixture.captured.output);
    const proof = JSON.parse(proofBytes);
    proof.source.method = 'source-summary';
    assert.throws(() => validateP08MercuryMediaProof({
      repoRoot: fixture.root, snapshot: { bytes: Buffer.from(`${JSON.stringify(proof, null, 2)}\n`) },
      environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST
    }), /not a live installed session/u);

    fs.appendFileSync(fixture.deviceFile, '\n');
    assert.throws(() => validateP08InstalledMediaSession(fixture.session, {
      environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST
    }, { repoRoot: fixture.root }), /raw observation bytes changed/u);
  } finally { cleanup(fixture); }
});

test('P-08 validator rejects candidate substitution and physical-device evidence mutation', async () => {
  const fixture = createFixture();
  try {
    const substituted = requirementContext(fixture);
    substituted.releaseClosure.document.candidate.artifactDigest = `sha256:${'8'.repeat(64)}`;
    await assert.rejects(() => validateProductRequirement(substituted), /selected release candidate/u);

    fs.appendFileSync(fixture.deviceFile, '\n');
    await assert.rejects(
      () => validateProductRequirement(requirementContext(fixture)),
      /raw observation bytes changed/u
    );
  } finally { cleanup(fixture); }
});
