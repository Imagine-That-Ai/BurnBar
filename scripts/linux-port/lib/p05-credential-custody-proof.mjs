import crypto from 'node:crypto';
import { readRegularSnapshot, SUPPORT_ENVIRONMENTS } from './product-proof-closure.mjs';

export const P05_PROOF_ROLE = 'feature.credential-custody-installed';
export const P05_PROOF_FILENAME = 'credential-custody-installed.json';
export const P05_SESSION_FILENAME = 'p05-installed-custody-session.json';

const HEAD = /^[a-f0-9]{40,64}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;
const VERSION = /^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$/u;

export const P05_BACKENDS = Object.freeze({
  gnome: Object.freeze({ id: 'secret-service', command: 'secret-tool', trustLevel: 'secret_service' }),
  kde: Object.freeze({ id: 'kwallet', command: 'kwallet-query', trustLevel: 'kwallet' }),
  sway: Object.freeze({ id: 'systemd-credential', command: 'systemd-creds', trustLevel: 'systemd_credential' })
});

export const P05_SOURCE_CONTRACTS = Object.freeze([
  'OpenBurnBarCore/Sources/OpenBurnBarLinuxSecurity/LinuxNativeSecretStore.swift',
  'OpenBurnBarCore/Sources/OpenBurnBarLinuxSecurity/OpenBurnBarLinuxSecurity.swift',
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarConfigStore.swift',
  'scripts/linux-port/run-p05-credential-custody-session.mjs'
]);

const SOURCE_MARKERS = Object.freeze({
  'OpenBurnBarCore/Sources/OpenBurnBarLinuxSecurity/LinuxNativeSecretStore.swift': [
    'LinuxNativeSecretStoreBackend', 'healthCheck()', 'standardInput: input', 'LinuxHeadlessSecretStoreBackend'
  ],
  'OpenBurnBarCore/Sources/OpenBurnBarLinuxSecurity/OpenBurnBarLinuxSecurity.swift': [
    'systemdCredential', 'plaintextFallbackRefused', 'O_NOFOLLOW', 'st_mode & 0o077 == 0'
  ],
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarConfigStore.swift': [
    'upsertCredentialSlot', 'secret_readback', 'removeCredentialSlot'
  ],
  'scripts/linux-port/run-p05-credential-custody-session.mjs': [
    'runNativeCustodyProbe', 'unavailableFailClosed', 'secretBytesCaptured: false'
  ]
});

function object(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be an object`);
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

function expectedEnvironment(environmentId) {
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId)) throw new Error('P-05 environment is outside the support matrix');
  const architecture = environmentId.endsWith('-aarch64') ? 'aarch64' : 'x86_64';
  const session = environmentId.includes('-x11-') ? 'x11' : 'wayland';
  if (environmentId.startsWith('ubuntu-')) {
    return { architecture, session, desktop: 'gnome', os: 'ubuntu', version: '24.04', format: 'deb', backend: P05_BACKENDS.gnome };
  }
  if (environmentId.startsWith('fedora-')) {
    return { architecture, session, desktop: 'kde', os: 'fedora', version: null, format: 'rpm', backend: P05_BACKENDS.kde };
  }
  return { architecture, session, desktop: 'sway', os: 'arch', version: null, format: 'arch', backend: P05_BACKENDS.sway };
}

function assertNoSecretMaterial(value, label = 'P-05 proof') {
  if (value === null || typeof value === 'number' || typeof value === 'boolean') return;
  if (typeof value === 'string') {
    if (/\bBearer\s+|(?:^|\W)(?:sk|pk|AIza)[-_A-Za-z0-9]{8,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/u.test(value)) {
      throw new Error(`${label} contains credential-like material`);
    }
    return;
  }
  if (Array.isArray(value)) return value.forEach((entry, index) => assertNoSecretMaterial(entry, `${label}[${index}]`));
  object(value, label);
  for (const [key, entry] of Object.entries(value)) {
    if (/^(?:secret|password|passphrase|token|bearer|credentialValue|plaintext|rawBytes)$/iu.test(key)) {
      throw new Error(`${label}.${key} is forbidden`);
    }
    assertNoSecretMaterial(entry, `${label}.${key}`);
  }
}

export function canonicalP05SourceEvidence(repoRoot) {
  return P05_SOURCE_CONTRACTS.map((relativePath) => {
    const snapshot = readRegularSnapshot(repoRoot, relativePath, `P-05 source ${relativePath}`);
    return { path: relativePath, sha256: snapshot.sha256 };
  });
}

function validateSources(repoRoot, rows) {
  if (!Array.isArray(rows) || rows.length !== P05_SOURCE_CONTRACTS.length) throw new Error('P-05 source evidence is incomplete');
  const seen = new Set();
  for (const row of rows) {
    exact(row, ['path', 'sha256'], 'P-05 source evidence row');
    if (!P05_SOURCE_CONTRACTS.includes(row.path) || seen.has(row.path) || !SHA256.test(row.sha256)) {
      throw new Error('P-05 source evidence is not canonical');
    }
    seen.add(row.path);
    const snapshot = readRegularSnapshot(repoRoot, row.path, `P-05 source ${row.path}`);
    if (snapshot.sha256 !== row.sha256) throw new Error(`P-05 source evidence hash changed: ${row.path}`);
    for (const marker of SOURCE_MARKERS[row.path]) {
      if (!snapshot.bytes.toString('utf8').includes(marker)) throw new Error(`${row.path} is missing P-05 custody marker`);
    }
  }
}

export function validateP05InstalledCustodySession(document, {
  environmentId, targetHead, candidateRunId, candidateArtifactDigest
}) {
  const expected = expectedEnvironment(environmentId);
  exact(document, ['backend', 'candidate', 'capture', 'environmentId', 'id', 'package', 'redaction', 'requirementId', 'schemaVersion', 'targetHead'], 'P-05 session');
  if (document.schemaVersion !== 1 || document.id !== 'openburnbar-linux-p05-installed-custody-session-v1'
      || document.requirementId !== 'P-05' || document.environmentId !== environmentId
      || document.targetHead !== targetHead || !HEAD.test(document.targetHead ?? '')) {
    throw new Error('P-05 session is not invocation-bound');
  }
  exact(document.candidate, ['artifactDigest', 'runId'], 'P-05 candidate');
  if (document.candidate.runId !== String(candidateRunId) || document.candidate.artifactDigest !== candidateArtifactDigest
      || !RUN_ID.test(document.candidate.runId) || !DIGEST.test(document.candidate.artifactDigest)) {
    throw new Error('P-05 session candidate does not match the selected release');
  }
  exact(document.capture, ['architecture', 'desktop', 'mode', 'os', 'platform', 'session'], 'P-05 capture');
  exact(document.capture.os, ['id', 'versionId'], 'P-05 capture os');
  if (document.capture.platform !== 'linux' || document.capture.mode !== 'installed-native-custody'
      || document.capture.architecture !== expected.architecture
      || document.capture.session.toLowerCase() !== expected.session
      || !document.capture.desktop.toLowerCase().includes(expected.desktop)
      || document.capture.os.id !== expected.os
      || (expected.version !== null && document.capture.os.versionId !== expected.version)) {
    throw new Error('P-05 capture does not match the installed support environment');
  }
  exact(document.package, ['architecture', 'format', 'installed', 'manifestSha256', 'source', 'version'], 'P-05 package');
  if (document.package.architecture !== expected.architecture || document.package.format !== expected.format
      || document.package.installed !== true || document.package.source !== 'signed-installed-candidate'
      || !SHA256.test(document.package.manifestSha256 ?? '') || !VERSION.test(document.package.version ?? '')) {
    throw new Error('P-05 package is not the signed installed candidate');
  }
  exact(document.backend, [
    'cleanupConfirmed', 'command', 'encryptedAtRest', 'firstReadbackMatched', 'healthPassed',
    'id', 'missingBeforeWrite', 'noSecretInArguments', 'oldValueRejected', 'recoveryReadbackMatched',
    'rotationReadbackMatched', 'trustLevel', 'unavailableFailClosed'
  ], 'P-05 backend');
  if (document.backend.id !== expected.backend.id || document.backend.command !== expected.backend.command
      || document.backend.trustLevel !== expected.backend.trustLevel) throw new Error('P-05 selected the wrong native custodian');
  for (const key of [
    'cleanupConfirmed', 'firstReadbackMatched', 'healthPassed', 'missingBeforeWrite',
    'noSecretInArguments', 'oldValueRejected', 'recoveryReadbackMatched',
    'rotationReadbackMatched', 'unavailableFailClosed'
  ]) if (document.backend[key] !== true) throw new Error(`P-05 backend ${key} is not proven`);
  if (document.backend.encryptedAtRest !== (expected.backend.id === 'systemd-credential')) {
    throw new Error('P-05 encrypted-at-rest claim does not match the native backend');
  }
  exact(document.redaction, ['diagnosticsRedacted', 'secretBytesCaptured', 'secretOccurrences', 'stderrRedacted', 'stdoutRedacted'], 'P-05 redaction');
  if (document.redaction.diagnosticsRedacted !== true || document.redaction.stderrRedacted !== true
      || document.redaction.stdoutRedacted !== true || document.redaction.secretBytesCaptured !== false
      || document.redaction.secretOccurrences !== 0) throw new Error('P-05 proof exposes credential material');
  assertNoSecretMaterial(document);
  return document;
}

export function validateP05CredentialCustodyProof({
  repoRoot, snapshot, environmentId, targetHead, candidateRunId, candidateArtifactDigest, sourceSnapshot
}) {
  let document;
  try { document = JSON.parse(snapshot.bytes.toString('utf8')); } catch (error) { throw new Error(`P-05 proof is not JSON: ${error.message}`); }
  exact(document, ['candidate', 'capture', 'environmentId', 'observed', 'passed', 'requirementId', 'schemaVersion', 'source', 'sourceEvidence', 'targetHead'], 'P-05 proof');
  if (document.schemaVersion !== 1 || document.requirementId !== 'P-05' || document.environmentId !== environmentId
      || document.targetHead !== targetHead || document.passed !== true) throw new Error('P-05 proof is not a passed candidate-bound proof');
  exact(document.source, ['method', 'path', 'sha256'], 'P-05 proof source');
  if (document.source.method !== 'installed-native-custody-session'
      || !document.source.path.endsWith(`/${P05_SESSION_FILENAME}`)
      || !SHA256.test(document.source.sha256 ?? '')) throw new Error('P-05 proof source is not canonical');
  if (sourceSnapshot !== undefined && (sourceSnapshot.sha256 !== document.source.sha256
      || !sourceSnapshot.bytes.equals(Buffer.from(`${JSON.stringify(document.observed, null, 2)}\n`)))) {
    throw new Error('P-05 proof source does not match the captured session bytes');
  }
  validateP05InstalledCustodySession(document.observed, { environmentId, targetHead, candidateRunId, candidateArtifactDigest });
  if (document.candidate.runId !== String(candidateRunId) || document.candidate.artifactDigest !== candidateArtifactDigest
      || JSON.stringify(document.capture) !== JSON.stringify(document.observed.capture)) throw new Error('P-05 proof binding is inconsistent');
  validateSources(repoRoot, document.sourceEvidence);
  assertNoSecretMaterial(document);
  return document;
}

export function sha256P05(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

export function p05SourceContractMarkers() {
  return Object.fromEntries(Object.entries(SOURCE_MARKERS).map(([key, markers]) => [key, [...markers]]));
}
