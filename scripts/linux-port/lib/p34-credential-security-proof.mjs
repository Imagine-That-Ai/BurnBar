import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { readRegularSnapshot, SUPPORT_ENVIRONMENTS } from './product-proof-closure.mjs';

export const P34_PROOF_ROLE = 'feature.credential-security-proof';
export const P34_PROOF_FILENAME = 'credential-security-proof.json';
export const P34_REGISTRATION_FILENAME = 'feature-proof-registration.json';

const HEAD = /^[a-f0-9]{40,64}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const CANDIDATE_DIGEST = /^sha256:[a-f0-9]{64}$/u;

export const P34_BACKEND_IDS = Object.freeze([
  'gnome-secret-service',
  'kde-kwallet',
  'headless-systemd-credentials'
]);

export const P34_CASE_IDS = Object.freeze([
  'missing',
  'locked',
  'rotation',
  'recovery',
  'redaction'
]);

const SOURCE_CONTRACTS = Object.freeze([
  'packaging/linux/release-manifest.json',
  'docs/linux-port/cloud-security-runbook.md',
  'apps/linux-desktop/src-tauri/src/lib.rs',
  'OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/LinuxSecretStorage.swift',
  'OpenBurnBarCore/Tests/OpenBurnBarComputerUseCoreTests/LinuxSecretStorageTests.swift',
  'scripts/linux-port/credential-storage-contract.test.mjs'
]);

const REQUIRED_SOURCE_MARKERS = Object.freeze({
  'packaging/linux/release-manifest.json': [
    '"primaryBackend": "org.freedesktop.secrets"',
    '"optionalBackend": "kwallet-query"',
    '"requiredCommand": "secret-tool"'
  ],
  'docs/linux-port/cloud-security-runbook.md': [
    'Secrets are passed to native tools on standard input',
    'never in arguments or the',
    'locked or failed primary keyring fails closed',
    'CREDENTIALS_DIRECTORY',
    'log only trust metadata, backend names, and redacted labels'
  ],
  'apps/linux-desktop/src-tauri/src/lib.rs': [
    'trusted_root_owned_executable',
    '"/usr/bin/secret-tool"',
    '"/usr/bin/kwallet-query"'
  ],
  'OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/LinuxSecretStorage.swift': [
    'LinuxPersistentSecretStore',
    'PlatformCrypto.sealAESGCM',
    'OPENBURNBAR_LINUX_SECRET_STORE_DIR'
  ],
  'OpenBurnBarCore/Tests/OpenBurnBarComputerUseCoreTests/LinuxSecretStorageTests.swift': [
    'testPinSavedWhileSecretServiceAvailableSurvivesHeadlessRestart',
    'testCorruptFallbackRecordFailsClosed',
    'testFileFallbackUsesOwnerOnlyPermissions'
  ],
  'scripts/linux-port/credential-storage-contract.test.mjs': [
    'runbook documents fail-closed locked keyring',
    'runbook documents fail-closed locked keyring'
  ]
});

const BACKEND_CONTRACTS = Object.freeze({
  'gnome-secret-service': {
    command: 'secret-tool',
    capability: 'secrets.secret-service',
    service: 'org.freedesktop.secrets'
  },
  'kde-kwallet': {
    command: 'kwallet-query',
    capability: 'secrets.kwallet',
    service: 'kwallet'
  },
  'headless-systemd-credentials': {
    command: 'CREDENTIALS_DIRECTORY',
    capability: 'headless.credentials',
    service: 'systemd-credentials'
  }
});

function assertObject(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
}

function assertExactKeys(value, keys, label) {
  assertObject(value, label);
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    throw new Error(`${label} fields must be exactly: ${expected.join(', ')}`);
  }
}

function assertExactSet(actual, expected, label) {
  if (!Array.isArray(actual) || actual.length !== expected.length
      || new Set(actual).size !== expected.length
      || expected.some((entry) => !actual.includes(entry))) {
    throw new Error(`${label} must contain exactly: ${expected.join(', ')}`);
  }
}

function assertString(value, label) {
  if (typeof value !== 'string' || value.length === 0) throw new Error(`${label} is required`);
}

function sha256File(repoRoot, relativePath, label) {
  const snapshot = readRegularSnapshot(repoRoot, relativePath, label);
  return { path: snapshot.path, sha256: snapshot.sha256, size: snapshot.size, bytes: snapshot.bytes };
}

function parseJson(bytes, label) {
  try {
    return JSON.parse(bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function assertNoCredentialMaterial(value, label = 'proof') {
  if (value === null || typeof value === 'number' || typeof value === 'boolean') return;
  if (typeof value === 'string') {
    // The proof may contain identifiers and digests, but never credential-like
    // material. This deliberately rejects common bearer/JWT/API-key shapes.
    if (/\bBearer\s+|(?:^|\W)(?:sk|pk|AIza)[-_A-Za-z0-9]{8,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/u.test(value)) {
      throw new Error(`${label} contains credential-like material`);
    }
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((entry, index) => assertNoCredentialMaterial(entry, `${label}[${index}]`));
    return;
  }
  assertObject(value, label);
  for (const [key, entry] of Object.entries(value)) {
    if (/^(?:secret|password|token|bearer|credential|plaintext|value)$/iu.test(key)) {
      throw new Error(`${label}.${key} is not permitted in credential proof`);
    }
    assertNoCredentialMaterial(entry, `${label}.${key}`);
  }
}

function validateCandidate(candidate, targetHead, expectedCandidate) {
  assertExactKeys(candidate, ['runId', 'artifactDigest'], 'credential proof candidate');
  if (!RUN_ID.test(candidate.runId) || !CANDIDATE_DIGEST.test(candidate.artifactDigest)) {
    throw new Error('credential proof candidate binding is invalid');
  }
  if (candidate.runId !== expectedCandidate.runId || candidate.artifactDigest !== expectedCandidate.artifactDigest) {
    throw new Error('credential proof candidate does not match the selected release candidate');
  }
  if (!HEAD.test(targetHead)) throw new Error('credential proof target head is invalid');
}

function validateSourceEvidence(repoRoot, rows) {
  if (!Array.isArray(rows) || rows.length !== SOURCE_CONTRACTS.length) {
    throw new Error('credential proof source evidence must cover every security contract source');
  }
  const seen = new Set();
  for (const [index, row] of rows.entries()) {
    assertExactKeys(row, ['path', 'sha256'], `source evidence ${index}`);
    if (!SOURCE_CONTRACTS.includes(row.path) || seen.has(row.path) || !SHA256.test(row.sha256)) {
      throw new Error(`source evidence ${index} is not canonical`);
    }
    seen.add(row.path);
    const snapshot = sha256File(repoRoot, row.path, `source evidence ${row.path}`);
    if (snapshot.sha256 !== row.sha256) throw new Error(`source evidence hash changed: ${row.path}`);
    const source = snapshot.bytes.toString('utf8');
    for (const marker of REQUIRED_SOURCE_MARKERS[row.path]) {
      if (!source.includes(marker)) throw new Error(`${row.path} is missing required security contract marker`);
    }
  }
}

function validateCase(row, backendId, caseId) {
  assertObject(row, `${backendId}.${caseId}`);
  if (caseId === 'missing') {
    assertExactKeys(row, ['fallback', 'passed', 'readOutcome', 'writeOutcome'], `${backendId}.${caseId}`);
    if (row.readOutcome !== 'absent' || row.writeOutcome !== 'unavailable'
        || !['none', 'explicit-headless-only'].includes(row.fallback) || row.passed !== true) {
      throw new Error(`${backendId}.${caseId} does not fail closed`);
    }
    if (backendId !== 'headless-systemd-credentials' && row.fallback !== 'none') {
      throw new Error(`${backendId}.${caseId} may not use a headless fallback`);
    }
    return;
  }
  if (caseId === 'locked') {
    assertExactKeys(row, ['fallback', 'passed', 'readOutcome', 'repairable', 'writeOutcome'], `${backendId}.${caseId}`);
    if (row.readOutcome !== 'locked' || row.writeOutcome !== 'unavailable'
        || row.fallback !== 'none' || row.repairable !== true || row.passed !== true) {
      throw new Error(`${backendId}.${caseId} does not fail closed`);
    }
    return;
  }
  if (caseId === 'rotation') {
    assertExactKeys(row, ['newAccepted', 'oldAccepted', 'passed', 'restartRequired'], `${backendId}.${caseId}`);
    if (row.newAccepted !== true || row.oldAccepted !== false || row.restartRequired !== false || row.passed !== true) {
      throw new Error(`${backendId}.${caseId} does not invalidate the old credential`);
    }
    return;
  }
  if (caseId === 'recovery') {
    assertExactKeys(row, ['afterUnlock', 'passed', 'retryWithoutRestart'], `${backendId}.${caseId}`);
    if (row.afterUnlock !== 'available' || row.retryWithoutRestart !== true || row.passed !== true) {
      throw new Error(`${backendId}.${caseId} does not prove repairable recovery`);
    }
    return;
  }
  assertExactKeys(row, ['diagnosticsRedacted', 'environmentRedacted', 'logsRedacted', 'passed', 'rendererRedacted', 'supportBundleRedacted'], `${backendId}.${caseId}`);
  if (row.diagnosticsRedacted !== true || row.environmentRedacted !== true || row.logsRedacted !== true
      || row.rendererRedacted !== true || row.supportBundleRedacted !== true || row.passed !== true) {
    throw new Error(`${backendId}.${caseId} exposes credential material`);
  }
}

function validateBackend(row) {
  assertExactKeys(row, [
    'backendId', 'capability', 'command', 'commandPresent', 'evidenceOrigin',
    'mode', 'passed', 'service', 'sessionBusPresent', 'cases'
  ], `backend ${row?.backendId ?? '<missing>'}`);
  if (!P34_BACKEND_IDS.includes(row.backendId)) throw new Error(`unknown P-34 backend: ${row.backendId}`);
  const expected = BACKEND_CONTRACTS[row.backendId];
  if (row.command !== expected.command || row.capability !== expected.capability || row.service !== expected.service) {
    throw new Error(`${row.backendId} backend contract does not match the native backend`);
  }
  if (!['fixture', 'live-metadata'].includes(row.mode) || row.evidenceOrigin !== 'contract-fixture'
      || typeof row.commandPresent !== 'boolean' || typeof row.sessionBusPresent !== 'boolean'
      || row.passed !== true) {
    throw new Error(`${row.backendId} backend metadata is not honest`);
  }
  assertExactSet(Object.keys(row.cases), P34_CASE_IDS, `${row.backendId} cases`);
  for (const caseId of P34_CASE_IDS) validateCase(row.cases[caseId], row.backendId, caseId);
}

export function validateP34CredentialSecurityProof({
  repoRoot,
  snapshot,
  targetHead,
  environmentId,
  candidateRunId,
  candidateArtifactDigest
}) {
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId)) throw new Error('credential proof environment is outside the support matrix');
  const document = parseJson(snapshot.bytes, 'credential security proof');
  assertExactKeys(document, [
    'backends', 'candidate', 'capture', 'contract', 'environmentId',
    'passed', 'redaction', 'requirementId', 'schemaVersion', 'sourceEvidence', 'targetHead'
  ], 'credential security proof');
  if (document.schemaVersion !== 1 || document.requirementId !== 'P-34'
      || document.environmentId !== environmentId || document.targetHead !== targetHead || document.passed !== true) {
    throw new Error('credential security proof is not bound to P-34, the environment, and the current HEAD');
  }
  validateCandidate(document.candidate, targetHead, {
    runId: String(candidateRunId),
    artifactDigest: candidateArtifactDigest
  });
  assertExactKeys(document.capture, [
    'architecture', 'credentialsCreated', 'desktop', 'mode', 'os', 'platform', 'productionSecretsObserved', 'session', 'sessionBusPresent'
  ], 'credential proof capture');
  if (document.capture.platform !== 'linux' || !['fixture', 'live-metadata'].includes(document.capture.mode)
      || document.capture.credentialsCreated !== false || document.capture.productionSecretsObserved !== false
      || typeof document.capture.sessionBusPresent !== 'boolean') {
    throw new Error('credential proof capture is not an honest metadata-only observation');
  }
  assertString(document.capture.architecture, 'credential proof architecture');
  assertString(document.capture.desktop, 'credential proof desktop');
  assertString(document.capture.session, 'credential proof session');
  assertObject(document.capture.os, 'credential proof os');
  assertExactKeys(document.capture.os, ['id', 'versionId'], 'credential proof os');
  assertString(document.capture.os.id, 'credential proof os id');
  assertString(document.capture.os.versionId, 'credential proof os version');

  assertExactKeys(document.contract, [
    'diagnosticsRedacted', 'encryptedHeadlessCustody', 'fixedRootOwnedDiscovery',
    'headlessCredentialDirectory', 'noPlaintextFallback', 'primaryBackend',
    'primaryCommand', 'secretsOnStdinOnly'
  ], 'credential proof contract');
  if (document.contract.diagnosticsRedacted !== true
      || document.contract.encryptedHeadlessCustody !== true
      || document.contract.fixedRootOwnedDiscovery !== true
      || document.contract.headlessCredentialDirectory !== true
      || document.contract.noPlaintextFallback !== true
      || document.contract.secretsOnStdinOnly !== true
      || document.contract.primaryBackend !== 'org.freedesktop.secrets'
      || document.contract.primaryCommand !== 'secret-tool') {
    throw new Error('credential proof contract does not enforce native custody boundaries');
  }
  validateSourceEvidence(repoRoot, document.sourceEvidence);

  if (!Array.isArray(document.backends) || document.backends.length !== P34_BACKEND_IDS.length) {
    throw new Error('credential proof must cover GNOME Secret Service, KDE KWallet, and headless credentials');
  }
  const backendIds = document.backends.map((row) => row?.backendId);
  assertExactSet(backendIds, P34_BACKEND_IDS, 'credential proof backends');
  document.backends.forEach(validateBackend);

  assertExactKeys(document.redaction, [
    'diagnostics', 'environment', 'logs', 'renderer', 'secretBytesCaptured', 'supportBundle', 'tokenOccurrences'
  ], 'credential proof redaction');
  if (document.redaction.diagnostics !== 'redacted'
      || document.redaction.environment !== 'redacted'
      || document.redaction.logs !== 'redacted'
      || document.redaction.renderer !== 'redacted'
      || document.redaction.supportBundle !== 'redacted'
      || document.redaction.secretBytesCaptured !== false
      || document.redaction.tokenOccurrences !== 0) {
    throw new Error('credential proof redaction contract failed');
  }
  assertNoCredentialMaterial(document);
  return document;
}

export function sourceContractPaths() {
  return [...SOURCE_CONTRACTS];
}

export function sourceContractMarkers() {
  return Object.fromEntries(Object.entries(REQUIRED_SOURCE_MARKERS).map(([key, value]) => [key, [...value]]));
}

export function backendContracts() {
  return Object.fromEntries(Object.entries(BACKEND_CONTRACTS).map(([key, value]) => [key, { ...value }]));
}

export function sha256Bytes(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

export function canonicalSourceEvidence(repoRoot) {
  return SOURCE_CONTRACTS.map((relativePath) => {
    const snapshot = sha256File(repoRoot, relativePath, `source contract ${relativePath}`);
    return { path: relativePath, sha256: snapshot.sha256 };
  });
}

export function parseProofSnapshot(snapshot) {
  return parseJson(snapshot.bytes, 'credential security proof');
}
