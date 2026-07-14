import fs from 'node:fs';
import path from 'node:path';
import {
  readRegularSnapshot,
  SUPPORT_ENVIRONMENTS
} from './product-proof-closure.mjs';

export const P40_REQUIREMENT_ID = 'P-40';
export const P40_PROOF_ROLE = 'feature.data-and-privacy';
export const P40_PROOF_FILENAME = 'data-and-privacy-proof.json';
export const P40_SESSION_FILENAME = 'p40-live-session.json';
export const P40_STORES = Object.freeze(['proxy_route_log', 'text_expansion_store']);
export const P40_RPC_METHODS = Object.freeze([
  'daemon.privacy.deletion.execute',
  'daemon.privacy.deletion.preview',
  'daemon.privacy.export',
  'daemon.privacy.inventory',
  'daemon.privacy.retention.apply',
  'daemon.privacy.retention.status'
]);

export const P40_RETENTION_CONTRACT = Object.freeze({
  confirmationPhrase: 'DELETE LOCAL DATA',
  retentionConfirmationPhrase: 'APPLY RETENTION POLICY',
  minimumRetentionAgeSeconds: 3_600,
  maximumRetentionAgeSeconds: 31_536_000,
  minimumRetentionBytes: 65_536,
  maximumRetentionBytes: 67_108_864,
  exportFormatVersion: 1
});

export const P40_DEFAULT_RETENTION_RULES = Object.freeze([
  Object.freeze({ store: 'proxy_route_log', maxAgeSeconds: 2_592_000, maxBytes: 8_388_608 }),
  Object.freeze({ store: 'text_expansion_store', maxAgeSeconds: 31_536_000, maxBytes: 4_194_304 })
]);

export const P40_SOURCE_CONTRACTS = Object.freeze([
  'OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarLinuxPrivacyContracts.swift',
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/BurnBarLinuxPrivacyService.swift',
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCPrivacy.swift',
  'OpenBurnBarDaemon/Tests/OpenBurnBarDaemonLinuxGatewayTests/BurnBarLinuxPrivacyServiceTests.swift',
  'apps/linux-desktop/src-tauri/src/lib.rs',
  'apps/linux-desktop/src/bridgeRpcBehavior.test.ts',
  'apps/linux-desktop/src/state/settingsWiringStore.ts',
  'apps/linux-desktop/src/surfaces/settings/SettingsDetailPane.tsx',
  'apps/linux-desktop/src/tauriBridge.ts'
]);

const SOURCE_MARKERS = Object.freeze({
  'OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarLinuxPrivacyContracts.swift': [
    'BurnBarLinuxPrivacyStoreID', 'BurnBarLinuxPrivacyRetentionRule', 'BurnBarLinuxPrivacyExportRequest'
  ],
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/BurnBarLinuxPrivacyService.swift': [
    'retentionConfirmationPhrase', 'minimumRetentionAgeSeconds', 'executeDeletion', 'applyRetention', 'export('
  ],
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCPrivacy.swift': [
    'handleLinuxPrivacyRPC', 'linuxPrivacyDeletionPreview', 'linuxPrivacyRetentionApply'
  ],
  'OpenBurnBarDaemon/Tests/OpenBurnBarDaemonLinuxGatewayTests/BurnBarLinuxPrivacyServiceTests.swift': [
    'testInventoryAndPreviewExposeMetadataOnlyAndExecuteIsIdempotent',
    'testEncryptedExportIsBoundedOwnerOnlyAndContainsNoPlaintextOnDisk',
    'testRetentionStatusAndApplyTrimOnlyOutOfPolicyData'
  ],
  'apps/linux-desktop/src-tauri/src/lib.rs': [
    'linux_privacy_inventory', 'linux_privacy_retention_apply', 'daemon.privacy.retention.status'
  ],
  'apps/linux-desktop/src/bridgeRpcBehavior.test.ts': [
    'linuxPrivacyDeletionPreview', 'linuxPrivacyExport', 'linuxPrivacyRetentionApply'
  ],
  'apps/linux-desktop/src/state/settingsWiringStore.ts': [
    'loadPrivacyInventory', 'executePrivacyDeletion', 'applyPrivacyRetention'
  ],
  'apps/linux-desktop/src/surfaces/settings/SettingsDetailPane.tsx': [
    'PrivacyDeletionControl', 'PrivacyExportControl', 'PrivacyRetentionControl'
  ],
  'apps/linux-desktop/src/tauriBridge.ts': [
    'LinuxPrivacyDeletionPreview', 'LinuxPrivacyExportResult', 'LinuxPrivacyRetentionApplyResult'
  ]
});

export const P40_ENVIRONMENTS = Object.freeze({
  'ubuntu-24.04-gnome-x11-x86_64': {
    architecture: 'x86_64', format: 'deb', desktop: 'GNOME', session: 'X11', os: { id: 'ubuntu', versionId: '24.04' }
  },
  'ubuntu-24.04-gnome-x11-aarch64': {
    architecture: 'aarch64', format: 'deb', desktop: 'GNOME', session: 'X11', os: { id: 'ubuntu', versionId: '24.04' }
  },
  'ubuntu-24.04-gnome-wayland-x86_64': {
    architecture: 'x86_64', format: 'deb', desktop: 'GNOME', session: 'Wayland', os: { id: 'ubuntu', versionId: '24.04' }
  },
  'ubuntu-24.04-gnome-wayland-aarch64': {
    architecture: 'aarch64', format: 'deb', desktop: 'GNOME', session: 'Wayland', os: { id: 'ubuntu', versionId: '24.04' }
  },
  'fedora-kde-wayland-x86_64': {
    architecture: 'x86_64', format: 'rpm', desktop: 'KDE Plasma', session: 'Wayland', os: { id: 'fedora', versionId: null }
  },
  'fedora-kde-wayland-aarch64': {
    architecture: 'aarch64', format: 'rpm', desktop: 'KDE Plasma', session: 'Wayland', os: { id: 'fedora', versionId: null }
  },
  'arch-sway-wayland-x86_64': {
    architecture: 'x86_64', format: 'arch', desktop: 'Sway/wlroots', session: 'Wayland', os: { id: 'arch', versionId: null }
  }
});

const HEAD = /^[a-f0-9]{40,64}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const CANDIDATE_DIGEST = /^sha256:[a-f0-9]{64}$/u;
const VERSION = /^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$/u;
const FORBIDDEN_EVIDENCE = /(?:fixture|mock|synthetic|xvfb)/iu;

function assertObject(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be an object`);
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
  if (!Array.isArray(actual) || actual.length !== expected.length || new Set(actual).size !== expected.length
      || expected.some((entry) => !actual.includes(entry))) {
    throw new Error(`${label} must contain exactly: ${expected.join(', ')}`);
  }
}

function assertBoolean(value, label) {
  if (value !== true) throw new Error(`${label} must be true`);
}

function parseJson(bytes, label) {
  try {
    return JSON.parse(Buffer.from(bytes).toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function assertCandidate(candidate, targetHead, candidateRunId, candidateArtifactDigest, label) {
  assertExactKeys(candidate, ['artifactDigest', 'runId'], `${label} candidate`);
  if (!RUN_ID.test(String(candidate.runId ?? '')) || String(candidate.runId) !== String(candidateRunId)) {
    throw new Error(`${label} candidate run id is not invocation-bound`);
  }
  if (!CANDIDATE_DIGEST.test(candidate.artifactDigest ?? '') || candidate.artifactDigest !== candidateArtifactDigest) {
    throw new Error(`${label} candidate artifact digest is not invocation-bound`);
  }
  if (!HEAD.test(targetHead ?? '')) throw new Error(`${label} target HEAD is invalid`);
}

function expectedEnvironment(environmentId) {
  const expected = P40_ENVIRONMENTS[environmentId];
  if (!expected || !SUPPORT_ENVIRONMENTS.includes(environmentId)) throw new Error(`unknown P-40 support environment: ${environmentId}`);
  return expected;
}

function validateEvidencePaths(paths, label) {
  if (!Array.isArray(paths) || paths.length === 0 || new Set(paths).size !== paths.length) {
    throw new Error(`${label} must contain unique evidence paths`);
  }
  for (const evidencePath of paths) {
    if (typeof evidencePath !== 'string' || evidencePath.length === 0 || evidencePath.startsWith('/')
        || evidencePath.includes('\\') || path.posix.normalize(evidencePath) !== evidencePath
        || evidencePath === '..' || evidencePath.startsWith('../') || FORBIDDEN_EVIDENCE.test(evidencePath)) {
      throw new Error(`${label} contains a forbidden or non-portable path`);
    }
  }
  return [...paths];
}

function assertNoSensitiveMaterial(value, label = 'P-40 proof') {
  if (value === null || typeof value === 'number' || typeof value === 'boolean') return;
  if (typeof value === 'string') {
    if (/\bBearer\s+|(?:^|\W)(?:sk|pk|AIza)[-_A-Za-z0-9]{8,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/u.test(value)) {
      throw new Error(`${label} contains credential-like material`);
    }
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((entry, index) => assertNoSensitiveMaterial(entry, `${label}[${index}]`));
    return;
  }
  assertObject(value, label);
  for (const [key, entry] of Object.entries(value)) {
    if (/^(?:secret|password|passphrase|token|bearer|credential|plaintext|contents|destinationPath|absolutePath|storePath|rawBytes)$/iu.test(key)) {
      throw new Error(`${label}.${key} is not permitted in P-40 proof`);
    }
    assertNoSensitiveMaterial(entry, `${label}.${key}`);
  }
}

function validateSourceEvidence(repoRoot, rows) {
  if (!Array.isArray(rows) || rows.length !== P40_SOURCE_CONTRACTS.length) {
    throw new Error('P-40 source evidence must cover every privacy contract source');
  }
  const seen = new Set();
  for (const [index, row] of rows.entries()) {
    assertExactKeys(row, ['path', 'sha256'], `P-40 source evidence ${index}`);
    if (!P40_SOURCE_CONTRACTS.includes(row.path) || seen.has(row.path) || !SHA256.test(row.sha256)) {
      throw new Error(`P-40 source evidence ${index} is not canonical`);
    }
    seen.add(row.path);
    const snapshot = readRegularSnapshot(repoRoot, row.path, `P-40 source evidence ${row.path}`);
    if (snapshot.sha256 !== row.sha256) throw new Error(`P-40 source evidence hash changed: ${row.path}`);
    for (const marker of SOURCE_MARKERS[row.path]) {
      if (!snapshot.bytes.toString('utf8').includes(marker)) throw new Error(`${row.path} is missing its privacy contract marker`);
    }
  }
}

function validateCapture(capture, environmentId) {
  assertExactKeys(capture, ['architecture', 'desktop', 'mode', 'os', 'platform', 'session'], 'P-40 capture');
  const expected = expectedEnvironment(environmentId);
  if (capture.platform !== 'linux' || capture.mode !== 'installed-rpc'
      || capture.architecture !== expected.architecture || capture.desktop !== expected.desktop
      || capture.session !== expected.session) {
    throw new Error('P-40 capture is not an installed Linux session');
  }
  assertExactKeys(capture.os, ['id', 'versionId'], 'P-40 capture os');
  if (capture.os.id !== expected.os.id || (expected.os.versionId !== null && capture.os.versionId !== expected.os.versionId)) {
    throw new Error('P-40 capture operating system does not match the support environment');
  }
  if (typeof capture.os.versionId !== 'string' || capture.os.versionId.length === 0) throw new Error('P-40 capture os version is required');
}

function validatePackage(packageObservation, environmentId) {
  assertExactKeys(packageObservation, ['architecture', 'format', 'installed', 'manifestSha256', 'source', 'version'], 'P-40 package');
  const expected = expectedEnvironment(environmentId);
  if (packageObservation.architecture !== expected.architecture || packageObservation.format !== expected.format
      || packageObservation.installed !== true || packageObservation.source !== 'signed-installed-candidate'
      || !SHA256.test(packageObservation.manifestSha256 ?? '') || !VERSION.test(packageObservation.version ?? '')) {
    throw new Error('P-40 package is not the signed installed candidate');
  }
}

function validateDesktop(desktop, capture) {
  assertExactKeys(desktop, ['desktop', 'liveSession', 'session'], 'P-40 desktop');
  if (desktop.desktop !== capture.desktop || desktop.session !== capture.session || desktop.liveSession !== true) {
    throw new Error('P-40 desktop observation is not a live supported session');
  }
}

function validateDaemon(daemon) {
  assertExactKeys(daemon, ['installed', 'rpcMethods', 'running', 'source'], 'P-40 daemon');
  if (daemon.installed !== true || daemon.running !== true || daemon.source !== 'installed-candidate-daemon') {
    throw new Error('P-40 daemon observation is not the installed candidate');
  }
  assertExactSet(daemon.rpcMethods, P40_RPC_METHODS, 'P-40 daemon RPC methods');
}

function validateStoreRows(rows, label) {
  if (!Array.isArray(rows) || rows.length !== P40_STORES.length) throw new Error(`${label} must cover every supported store`);
  assertExactSet(rows.map((row) => row?.store), P40_STORES, `${label} stores`);
  for (const row of rows) {
    assertExactKeys(row, ['bytes', 'state', 'store'], `${label} ${row?.store ?? '<missing>'}`);
    if (!P40_STORES.includes(row.store) || !['absent', 'ready', 'blocked'].includes(row.state)
        || !Number.isSafeInteger(row.bytes) || row.bytes < 0) {
      throw new Error(`${label} contains invalid store metadata`);
    }
  }
}

function validateInventory(inventory) {
  assertExactKeys(inventory, ['evidencePaths', 'metadataOnly', 'noAbsolutePaths', 'noContents', 'stores'], 'P-40 inventory');
  assertBoolean(inventory.metadataOnly, 'P-40 inventory metadataOnly');
  assertBoolean(inventory.noAbsolutePaths, 'P-40 inventory noAbsolutePaths');
  assertBoolean(inventory.noContents, 'P-40 inventory noContents');
  validateEvidencePaths(inventory.evidencePaths, 'P-40 inventory evidencePaths');
  validateStoreRows(inventory.stores, 'P-40 inventory');
}

function validateDeletion(deletion) {
  assertExactKeys(deletion, [
    'changedPreviewRejected', 'confirmationExact', 'evidencePaths', 'expiredPreviewRejected',
    'idempotent', 'noAbsolutePaths', 'noContentsReturned', 'outsidePathUntouched',
    'previewScopeBound', 'selectedScope'
  ], 'P-40 deletion');
  for (const key of [
    'changedPreviewRejected', 'confirmationExact', 'expiredPreviewRejected', 'idempotent',
    'noAbsolutePaths', 'noContentsReturned', 'outsidePathUntouched', 'previewScopeBound', 'selectedScope'
  ]) assertBoolean(deletion[key], `P-40 deletion ${key}`);
  validateEvidencePaths(deletion.evidencePaths, 'P-40 deletion evidencePaths');
}

function validateExport(exportObservation) {
  assertExactKeys(exportObservation, [
    'encrypted', 'evidencePaths', 'formatVersion', 'noPlaintextOnDisk',
    'ownerOnlyPermissions', 'passphraseNotPersisted', 'selectedScope'
  ], 'P-40 export');
  for (const key of ['encrypted', 'noPlaintextOnDisk', 'ownerOnlyPermissions', 'passphraseNotPersisted', 'selectedScope']) {
    assertBoolean(exportObservation[key], `P-40 export ${key}`);
  }
  if (exportObservation.formatVersion !== P40_RETENTION_CONTRACT.exportFormatVersion) throw new Error('P-40 export format drifted');
  validateEvidencePaths(exportObservation.evidencePaths, 'P-40 export evidencePaths');
}

function validateRules(rules, label, allowDefaults = false) {
  if (!Array.isArray(rules) || rules.length !== P40_STORES.length) throw new Error(`${label} must cover every supported store`);
  assertExactSet(rules.map((row) => row?.store), P40_STORES, `${label} stores`);
  for (const row of rules) {
    assertExactKeys(row, ['maxAgeSeconds', 'maxBytes', 'store'], `${label} ${row?.store ?? '<missing>'}`);
    if (!P40_STORES.includes(row.store) || !Number.isSafeInteger(row.maxAgeSeconds)
        || !Number.isSafeInteger(row.maxBytes) || row.maxAgeSeconds < P40_RETENTION_CONTRACT.minimumRetentionAgeSeconds
        || row.maxAgeSeconds > P40_RETENTION_CONTRACT.maximumRetentionAgeSeconds
        || row.maxBytes < P40_RETENTION_CONTRACT.minimumRetentionBytes
        || row.maxBytes > P40_RETENTION_CONTRACT.maximumRetentionBytes) {
      throw new Error(`${label} contains a rule outside the daemon safety bounds`);
    }
  }
  if (allowDefaults && JSON.stringify(rules) !== JSON.stringify(P40_DEFAULT_RETENTION_RULES)) {
    throw new Error('P-40 default retention rules drifted');
  }
}

function validateRetention(retention) {
  assertExactKeys(retention, [
    'agedExpansionPurged', 'appliedRules', 'defaultRules', 'evidencePaths',
    'freshRouteRetained', 'invalidBoundsRejected', 'invalidConfirmationRejected',
    'malformedStoreFailClosed', 'noMutationOnFailure', 'oldRoutePurged', 'statusObserved'
  ], 'P-40 retention');
  for (const key of [
    'agedExpansionPurged', 'freshRouteRetained', 'invalidBoundsRejected',
    'invalidConfirmationRejected', 'malformedStoreFailClosed', 'noMutationOnFailure',
    'oldRoutePurged', 'statusObserved'
  ]) assertBoolean(retention[key], `P-40 retention ${key}`);
  validateRules(retention.defaultRules, 'P-40 retention defaultRules', true);
  validateRules(retention.appliedRules, 'P-40 retention appliedRules');
  validateEvidencePaths(retention.evidencePaths, 'P-40 retention evidencePaths');
}

function validateContract(contract) {
  assertExactKeys(contract, [
    'confirmationPhrase', 'defaultRetentionRules', 'encryptedExport', 'exportFormatVersion',
    'maximumRetentionAgeSeconds', 'maximumRetentionBytes', 'minimumRetentionAgeSeconds',
    'minimumRetentionBytes', 'retentionConfirmationPhrase', 'rpcMethods', 'stores'
  ], 'P-40 contract');
  if (contract.confirmationPhrase !== P40_RETENTION_CONTRACT.confirmationPhrase
      || contract.retentionConfirmationPhrase !== P40_RETENTION_CONTRACT.retentionConfirmationPhrase
      || contract.minimumRetentionAgeSeconds !== P40_RETENTION_CONTRACT.minimumRetentionAgeSeconds
      || contract.maximumRetentionAgeSeconds !== P40_RETENTION_CONTRACT.maximumRetentionAgeSeconds
      || contract.minimumRetentionBytes !== P40_RETENTION_CONTRACT.minimumRetentionBytes
      || contract.maximumRetentionBytes !== P40_RETENTION_CONTRACT.maximumRetentionBytes
      || contract.exportFormatVersion !== P40_RETENTION_CONTRACT.exportFormatVersion) {
    throw new Error('P-40 privacy contract constants do not match the daemon');
  }
  assertBoolean(contract.encryptedExport, 'P-40 contract encryptedExport');
  assertExactSet(contract.stores, P40_STORES, 'P-40 contract stores');
  assertExactSet(contract.rpcMethods, P40_RPC_METHODS, 'P-40 contract rpcMethods');
  validateRules(contract.defaultRetentionRules, 'P-40 contract defaultRetentionRules', true);
}

export function validateP40LiveSession(document, {
  environmentId,
  targetHead,
  candidateRunId,
  candidateArtifactDigest
}) {
  assertExactKeys(document, [
    'candidate', 'capture', 'contract', 'daemon', 'desktop', 'environmentId', 'id',
    'observations', 'package', 'requirementId', 'schemaVersion', 'targetHead'
  ], 'P-40 live privacy session');
  if (document.schemaVersion !== 1 || document.id !== 'openburnbar-linux-p40-live-session-v1'
      || document.requirementId !== P40_REQUIREMENT_ID || document.environmentId !== environmentId
      || document.targetHead !== targetHead || !HEAD.test(document.targetHead ?? '')) {
    throw new Error('P-40 live privacy session is not invocation-bound');
  }
  assertCandidate(document.candidate, targetHead, candidateRunId, candidateArtifactDigest, 'P-40 live privacy session');
  validateCapture(document.capture, environmentId);
  validatePackage(document.package, environmentId);
  validateDesktop(document.desktop, document.capture);
  validateDaemon(document.daemon);
  validateContract(document.contract);
  assertExactKeys(document.observations, ['deletion', 'export', 'inventory', 'retention'], 'P-40 observations');
  validateInventory(document.observations.inventory);
  validateDeletion(document.observations.deletion);
  validateExport(document.observations.export);
  validateRetention(document.observations.retention);
  assertNoSensitiveMaterial(document);
  return document;
}

export function validateP40PrivacyProof({
  repoRoot,
  snapshot,
  targetHead,
  environmentId,
  candidateRunId,
  candidateArtifactDigest
}) {
  const document = parseJson(snapshot.bytes, 'P-40 privacy proof');
  assertExactKeys(document, [
    'candidate', 'capture', 'contract', 'daemon', 'desktop', 'environmentId', 'id',
    'observations', 'package', 'passed', 'requirementId', 'role', 'schemaVersion',
    'source', 'sourceEvidence', 'targetHead'
  ], 'P-40 privacy proof');
  if (document.schemaVersion !== 1 || document.id !== 'openburnbar-linux-p40-privacy-proof-v1'
      || document.requirementId !== P40_REQUIREMENT_ID || document.role !== P40_PROOF_ROLE
      || document.environmentId !== environmentId || document.targetHead !== targetHead || document.passed !== true) {
    throw new Error('P-40 privacy proof is not a passed candidate-bound proof');
  }
  const session = {
    candidate: document.candidate,
    capture: document.capture,
    contract: document.contract,
    daemon: document.daemon,
    desktop: document.desktop,
    environmentId: document.environmentId,
    id: 'openburnbar-linux-p40-live-session-v1',
    observations: document.observations,
    package: document.package,
    requirementId: document.requirementId,
    schemaVersion: document.schemaVersion,
    targetHead: document.targetHead
  };
  validateP40LiveSession(session, { environmentId, targetHead, candidateRunId, candidateArtifactDigest });
  assertExactKeys(document.source, ['method', 'path', 'sha256'], 'P-40 proof source');
  if (document.source.method !== 'live-installed-candidate-privacy-rpc-session'
      || typeof document.source.path !== 'string' || document.source.path.startsWith('/')
      || path.posix.normalize(document.source.path) !== document.source.path || !SHA256.test(document.source.sha256 ?? '')) {
    throw new Error('P-40 proof source is not a canonical live-session record');
  }
  validateSourceEvidence(repoRoot, document.sourceEvidence);
  assertNoSensitiveMaterial(document);
  return document;
}

export function buildP40Proof({ session, sourcePath, sourceSha256, repoRoot }) {
  validateP40LiveSession(session, {
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidateRunId: session.candidate.runId,
    candidateArtifactDigest: session.candidate.artifactDigest
  });
  return {
    schemaVersion: 1,
    id: 'openburnbar-linux-p40-privacy-proof-v1',
    requirementId: P40_REQUIREMENT_ID,
    role: P40_PROOF_ROLE,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    capture: session.capture,
    package: session.package,
    desktop: session.desktop,
    daemon: session.daemon,
    contract: session.contract,
    observations: session.observations,
    source: {
      path: sourcePath,
      sha256: sourceSha256,
      method: 'live-installed-candidate-privacy-rpc-session'
    },
    sourceEvidence: canonicalSourceEvidence(repoRoot),
    passed: true
  };
}

export function canonicalSourceEvidence(repoRoot) {
  return P40_SOURCE_CONTRACTS.map((relativePath) => {
    const snapshot = readRegularSnapshot(repoRoot, relativePath, `P-40 source contract ${relativePath}`);
    return { path: relativePath, sha256: snapshot.sha256 };
  });
}

export function parseP40Json(bytes, label) {
  return parseJson(bytes, label);
}

export function sourceContractMarkers() {
  return Object.fromEntries(Object.entries(SOURCE_MARKERS).map(([key, value]) => [key, [...value]]));
}
