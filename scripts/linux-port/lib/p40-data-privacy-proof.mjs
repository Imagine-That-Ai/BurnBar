import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { readRegularSnapshot, SUPPORT_ENVIRONMENTS } from './product-proof-closure.mjs';

export const P40_REQUIREMENT_ID = 'P-40';
export const P40_PROOF_ROLE = 'feature.data-privacy-proof';
export const P40_PROOF_FILENAME = 'data-privacy-proof.json';
export const P40_REGISTRATION_FILENAME = 'feature-proof-registration.json';

const HEAD = /^[a-f0-9]{40,64}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const CANDIDATE_DIGEST = /^sha256:[a-f0-9]{64}$/u;

export const P40_DOMAIN_IDS = Object.freeze([
  'usage_spend',
  'conversations_chat',
  'session_logs',
  'pensieve',
  'provider_accounts',
  'connected_devices',
  'external_mcp',
  'computer_use',
  'media',
  'entitlements_billing',
  'device_trust_keys',
  'audit_timeline'
]);

export const P40_CASE_IDS = Object.freeze([
  'export-preview',
  'export-cancel',
  'export-encrypt',
  'export-redaction',
  'local-delete',
  'account-delete',
  'partial-failure',
  'retention-expiry',
  'recovery-success',
  'recovery-failure',
  'telemetry-opt-out',
  'cloud-sync-opt-out',
  'offline-queueing',
  'locked-keyring',
  'panic-sync',
  'panic-all'
]);

export const P40_SOURCE_CONTRACTS = Object.freeze({
  'packages/data-domains/registry.json': [
    '"schemaVersion": 1',
    '"id": "usage_spend"',
    '"retention": "rolling"',
    '"actions": ["view", "export", "delete"]'
  ],
  'AgentLens/Services/DataControlCenterViewModel.swift': [
    'getDataDomainUsage',
    'exportUserData',
    'deleteDomainData',
    'setupRecovery',
    'revokeAllAccess',
    'verifyAuditLog'
  ],
  'AgentLens/Views/Settings/DataControlCenter/DataControlCenterActions.swift': [
    'Type DELETE to confirm',
    'confirmWord',
    'Set up recovery',
    'PanicRevokeSheet'
  ],
  'functions/src/callables/dataExport.ts': [
    'exportUserData',
    'MAX_INLINE_DOCS_PER_COLLECTION',
    'sealAwareSerializeDoc',
    'appendAuditEventRequired'
  ],
  'functions/src/callables/dataDeletion.ts': [
    'UNDELETABLE_DOMAINS',
    'recursiveDelete',
    'appendAuditEventRequired',
    'deleteDomainData'
  ],
  'functions/src/callables/panic.ts': [
    'revokeAllAccess',
    'scope must be sync or all',
    'appendAuditEventRequired'
  ],
  'functions/src/callables/recovery.ts': [
    'setupRecovery',
    'confirmRecovery',
    'verificationHash',
    'appendAuditEvent'
  ],
  'OpenBurnBarCore/Sources/OpenBurnBarLinuxSecurity/OpenBurnBarLinuxSecurity.swift': [
    'LinuxTelemetryRecorder',
    'LinuxCloudSyncPrivacyGuard',
    'LinuxRedactionSurfaceEvidence'
  ],
  'OpenBurnBarCore/Tests/OpenBurnBarLinuxSecurityTests/OpenBurnBarLinuxSecurityTests.swift': [
    'testTelemetryConsentRedactionAndSupportBundleSample',
    'testTelemetryBridgeControlsAndRedactionSurfaceProofs',
    'testCloudSyncPrivacyBOLASealedPayloadsAndWatermarkCommitBoundary'
  ],
  'apps/linux-desktop/src/surfaces/settings/SettingsDetailPane.tsx': [
    "case 'data-privacy'",
    'ReadOnlyToggle',
    'Support & diagnostics'
  ]
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

function parseJson(bytes, label) {
  try {
    return JSON.parse(Buffer.from(bytes).toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function sha256File(repoRoot, relativePath, label) {
  const snapshot = readRegularSnapshot(repoRoot, relativePath, label);
  return { path: snapshot.path, sha256: snapshot.sha256, size: snapshot.size, bytes: snapshot.bytes };
}

function expectedEnvironmentMetadata(environmentId) {
  const architecture = environmentId.endsWith('-aarch64') ? 'aarch64' : 'x86_64';
  const session = environmentId.includes('-x11-') ? 'x11' : 'wayland';
  const os = environmentId.startsWith('ubuntu-')
    ? { id: 'ubuntu', versionId: '24.04' }
    : environmentId.startsWith('fedora-')
      ? { id: 'fedora', versionId: null }
      : { id: 'arch', versionId: null };
  const desktop = environmentId.startsWith('ubuntu-') ? 'gnome'
    : environmentId.startsWith('fedora-') ? 'kde'
      : 'sway';
  return { architecture, session, os, desktop };
}

function validateEnvironmentMetadata(capture, environmentId) {
  const expected = expectedEnvironmentMetadata(environmentId);
  if (capture.architecture !== expected.architecture || capture.session.toLowerCase() !== expected.session
      || !capture.desktop.toLowerCase().includes(expected.desktop)) {
    throw new Error('data privacy proof host metadata does not match the canonical environment');
  }
  if (capture.os.id !== expected.os.id
      || (expected.os.versionId !== null && capture.os.versionId !== expected.os.versionId)) {
    throw new Error('data privacy proof host operating system does not match the canonical environment');
  }
}

function validateCandidate(candidate, targetHead, expectedCandidate) {
  assertExactKeys(candidate, ['artifactDigest', 'runId'], 'data privacy proof candidate');
  if (!RUN_ID.test(String(candidate.runId ?? '')) || !CANDIDATE_DIGEST.test(candidate.artifactDigest ?? '')) {
    throw new Error('data privacy proof candidate binding is invalid');
  }
  if (String(candidate.runId) !== String(expectedCandidate.runId)
      || candidate.artifactDigest !== expectedCandidate.artifactDigest) {
    throw new Error('data privacy proof candidate does not match the selected release candidate');
  }
  if (!HEAD.test(targetHead ?? '')) throw new Error('data privacy proof target head is invalid');
}

function validateSourceEvidence(repoRoot, rows) {
  const expectedPaths = Object.keys(P40_SOURCE_CONTRACTS);
  if (!Array.isArray(rows) || rows.length !== expectedPaths.length) {
    throw new Error('data privacy source evidence must cover every privacy contract source');
  }
  const seen = new Set();
  for (const [index, row] of rows.entries()) {
    assertExactKeys(row, ['path', 'sha256'], `data privacy source evidence ${index}`);
    if (!expectedPaths.includes(row.path) || seen.has(row.path) || !SHA256.test(row.sha256 ?? '')) {
      throw new Error(`data privacy source evidence ${index} is not canonical`);
    }
    seen.add(row.path);
    const snapshot = sha256File(repoRoot, row.path, `data privacy source ${row.path}`);
    if (snapshot.sha256 !== row.sha256) throw new Error(`data privacy source hash changed: ${row.path}`);
    const source = snapshot.bytes.toString('utf8');
    for (const marker of P40_SOURCE_CONTRACTS[row.path]) {
      if (!source.includes(marker)) throw new Error(`${row.path} is missing required data privacy marker`);
    }
  }
}

function validateInventory(repoRoot, inventory, sourceEvidence) {
  assertExactKeys(inventory, ['domainCount', 'domains', 'registryPath', 'registrySha256'], 'data privacy inventory');
  if (inventory.registryPath !== 'packages/data-domains/registry.json'
      || !SHA256.test(inventory.registrySha256 ?? '')
      || inventory.domainCount !== P40_DOMAIN_IDS.length) {
    throw new Error('data privacy inventory is not bound to the canonical domain registry');
  }
  const registry = parseJson(
    readRegularSnapshot(repoRoot, inventory.registryPath, 'data privacy domain registry').bytes,
    'data privacy domain registry'
  );
  const registrySnapshot = sha256File(repoRoot, inventory.registryPath, 'data privacy domain registry');
  if (registrySnapshot.sha256 !== inventory.registrySha256) {
    throw new Error('data privacy domain registry hash changed');
  }
  const registryEvidence = sourceEvidence.find((row) => row.path === inventory.registryPath);
  if (!registryEvidence || registryEvidence.sha256 !== inventory.registrySha256) {
    throw new Error('data privacy inventory registry evidence is not canonical');
  }
  const domains = registry.domains;
  if (!Array.isArray(domains) || domains.length !== P40_DOMAIN_IDS.length) {
    throw new Error('data privacy domain registry does not contain the complete inventory');
  }
  if (!Array.isArray(inventory.domains) || inventory.domains.length !== domains.length) {
    throw new Error('data privacy inventory does not cover every domain');
  }
  for (const [index, domain] of domains.entries()) {
    const row = inventory.domains[index];
    assertExactKeys(row, ['actions', 'encryptionTier', 'id', 'retention'], `data privacy inventory domain ${index}`);
    if (row.id !== P40_DOMAIN_IDS[index] || row.id !== domain.id
        || row.encryptionTier !== domain.encryptionTier || row.retention !== domain.retention
        || JSON.stringify(row.actions) !== JSON.stringify(domain.actions)) {
      throw new Error(`data privacy inventory domain ${index} does not match the macOS domain registry`);
    }
    assertExactSet(row.actions, domain.actions, `data privacy inventory ${row.id} actions`);
  }
}

function validateControls(controls) {
  assertExactKeys(controls, ['consent', 'deletion', 'export', 'panic', 'recovery', 'redaction', 'retention'], 'data privacy controls');
  assertExactKeys(controls.export, ['audit', 'cancel', 'redacted', 'scopeSelection', 'sealedFacetProtection'], 'data privacy export controls');
  if (Object.values(controls.export).some((value) => value !== true)) {
    throw new Error('data privacy export controls are incomplete');
  }
  assertExactKeys(controls.deletion, [
    'accountScope', 'auditIntent', 'confirmation', 'localScope', 'partialFailureRetry',
    'secureEraseMeaningful', 'serverReceipt'
  ], 'data privacy deletion controls');
  if (controls.deletion.accountScope !== 'server-coordinated'
      || controls.deletion.localScope !== 'daemon-owned'
      || Object.entries(controls.deletion).some(([key, value]) => !['accountScope', 'localScope'].includes(key) && value !== true)) {
    throw new Error('data privacy deletion controls are incomplete');
  }
  assertExactKeys(controls.retention, ['appendOnly', 'expiry', 'rolling', 'untilDeleted', 'untilRevoked'], 'data privacy retention controls');
  if (Object.values(controls.retention).some((value) => value !== true)) {
    throw new Error('data privacy retention controls are incomplete');
  }
  assertExactKeys(controls.recovery, ['failureClosed', 'rawKeyNeverSent', 'setup', 'success'], 'data privacy recovery controls');
  if (Object.values(controls.recovery).some((value) => value !== true)) {
    throw new Error('data privacy recovery controls are incomplete');
  }
  assertExactKeys(controls.consent, [
    'cloudSyncDefault', 'cloudSyncOptOut', 'emissionGate', 'persisted', 'telemetryDefault', 'telemetryOptOut'
  ], 'data privacy consent controls');
  if (controls.consent.cloudSyncDefault !== 'off' || controls.consent.telemetryDefault !== 'off'
      || controls.consent.emissionGate !== 'consent-required'
      || controls.consent.cloudSyncOptOut !== true || controls.consent.persisted !== true
      || controls.consent.telemetryOptOut !== true) {
    throw new Error('data privacy consent controls are incomplete');
  }
  assertExactKeys(controls.panic, ['allScope', 'audit', 'syncScope', 'typedConfirmation'], 'data privacy panic controls');
  if (Object.values(controls.panic).some((value) => value !== true)) {
    throw new Error('data privacy panic controls are incomplete');
  }
  assertExactKeys(controls.redaction, [
    'diagnostics', 'export', 'paths', 'pii', 'secrets', 'supportBundle', 'telemetry'
  ], 'data privacy redaction controls');
  if (Object.values(controls.redaction).some((value) => value !== true)) {
    throw new Error('data privacy redaction controls are incomplete');
  }
}

function validateCases(cases) {
  assertExactSet(Object.keys(cases), P40_CASE_IDS, 'data privacy cases');
  const expected = {
    'export-preview': ['cancelable', 'passed', 'previewed'],
    'export-cancel': ['noWrite', 'passed', 'userCancelled'],
    'export-encrypt': ['passed', 'sealedFacetProtection', 'secretBytesObserved'],
    'export-redaction': ['passed', 'piiOccurrences', 'redacted'],
    'local-delete': ['auditIntent', 'passed', 'scope'],
    'account-delete': ['passed', 'scope', 'serverReceipt'],
    'partial-failure': ['destroyedPartialData', 'passed', 'retryable'],
    'retention-expiry': ['auditPreserved', 'expiredDataRemoved', 'passed'],
    'recovery-success': ['passed', 'rawKeyTransmitted', 'recovered'],
    'recovery-failure': ['failedClosed', 'passed', 'rawKeyTransmitted'],
    'telemetry-opt-out': ['emitted', 'passed', 'requiresConsent'],
    'cloud-sync-opt-out': ['passed', 'requiresConsent', 'uploaded'],
    'offline-queueing': ['consentRecheckedOnFlush', 'passed', 'queuedLocally'],
    'locked-keyring': ['failedClosed', 'localPlaintextFallback', 'passed'],
    'panic-sync': ['passed', 'revoked', 'scope', 'typedConfirmation'],
    'panic-all': ['passed', 'revoked', 'scope', 'typedConfirmation']
  };
  for (const caseId of P40_CASE_IDS) {
    const row = cases[caseId];
    assertExactKeys(row, expected[caseId], `data privacy case ${caseId}`);
    if (row.passed !== true) throw new Error(`data privacy case ${caseId} did not pass`);
  }
  if (cases['export-preview'].previewed !== true || cases['export-preview'].cancelable !== true
      || cases['export-cancel'].userCancelled !== true || cases['export-cancel'].noWrite !== true
      || cases['export-encrypt'].sealedFacetProtection !== true || cases['export-encrypt'].secretBytesObserved !== false
      || cases['export-redaction'].redacted !== true || cases['export-redaction'].piiOccurrences !== 0
      || cases['local-delete'].scope !== 'local' || cases['local-delete'].auditIntent !== true
      || cases['account-delete'].scope !== 'account' || cases['account-delete'].serverReceipt !== true
      || cases['partial-failure'].destroyedPartialData !== false || cases['partial-failure'].retryable !== true
      || cases['retention-expiry'].expiredDataRemoved !== true || cases['retention-expiry'].auditPreserved !== true
      || cases['recovery-success'].recovered !== true || cases['recovery-success'].rawKeyTransmitted !== false
      || cases['recovery-failure'].failedClosed !== true || cases['recovery-failure'].rawKeyTransmitted !== false
      || cases['telemetry-opt-out'].requiresConsent !== true || cases['telemetry-opt-out'].emitted !== false
      || cases['cloud-sync-opt-out'].requiresConsent !== true || cases['cloud-sync-opt-out'].uploaded !== false
      || cases['offline-queueing'].queuedLocally !== true || cases['offline-queueing'].consentRecheckedOnFlush !== true
      || cases['locked-keyring'].failedClosed !== true || cases['locked-keyring'].localPlaintextFallback !== false
      || cases['panic-sync'].scope !== 'sync' || cases['panic-sync'].revoked !== true
      || cases['panic-all'].scope !== 'all' || cases['panic-all'].revoked !== true
      || cases['panic-sync'].typedConfirmation !== true || cases['panic-all'].typedConfirmation !== true) {
    throw new Error('data privacy case matrix contains an unsafe or incomplete outcome');
  }
}

function assertNoSensitiveMaterial(value, label = 'data privacy proof') {
  if (value === null || typeof value === 'number' || typeof value === 'boolean') return;
  if (typeof value === 'string') {
    if (/(?:Bearer\s+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|(?:^|\W)(?:sk|pk|AIza)[-_A-Za-z0-9]{8,}|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|\/home\/|\/Users\/)/iu.test(value)) {
      throw new Error(`${label} contains sensitive material`);
    }
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((entry, index) => assertNoSensitiveMaterial(entry, `${label}[${index}]`));
    return;
  }
  assertObject(value, label);
  for (const [key, entry] of Object.entries(value)) {
    if (/^(?:secret|password|token|credential|plaintext|prompt|body|cookie|email|raw)$/iu.test(key)) {
      throw new Error(`${label}.${key} is not permitted in data privacy proof`);
    }
    assertNoSensitiveMaterial(entry, `${label}.${key}`);
  }
}

function validateDocument({ repoRoot, document, targetHead, environmentId, candidateRunId, candidateArtifactDigest }) {
  assertExactKeys(document, [
    'candidate', 'capture', 'cases', 'controls', 'environmentId', 'id', 'inventory',
    'passed', 'requirementId', 'schemaVersion', 'sourceEvidence', 'targetHead'
  ], 'data privacy proof');
  if (document.schemaVersion !== 1 || document.id !== 'openburnbar-linux-p40-data-privacy-proof-v1'
      || document.requirementId !== P40_REQUIREMENT_ID || document.environmentId !== environmentId
      || document.targetHead !== targetHead || document.passed !== true) {
    throw new Error('data privacy proof is not bound to P-40, the environment, and the current HEAD');
  }
  validateCandidate(document.candidate, targetHead, {
    runId: String(candidateRunId), artifactDigest: candidateArtifactDigest
  });
  assertExactKeys(document.capture, [
    'architecture', 'desktop', 'evidenceOrigin', 'mode', 'os', 'piiObserved',
    'platform', 'productionDataObserved', 'secretBytesObserved', 'session'
  ], 'data privacy proof capture');
  if (document.capture.platform !== 'linux' || document.capture.mode !== 'fixture'
      || document.capture.evidenceOrigin !== 'contract-fixture'
      || document.capture.piiObserved !== false || document.capture.productionDataObserved !== false
      || document.capture.secretBytesObserved !== false) {
    throw new Error('data privacy proof capture is not an honest metadata-only fixture');
  }
  assertString(document.capture.architecture, 'data privacy proof architecture');
  assertString(document.capture.desktop, 'data privacy proof desktop');
  assertString(document.capture.session, 'data privacy proof session');
  assertObject(document.capture.os, 'data privacy proof os');
  assertExactKeys(document.capture.os, ['id', 'versionId'], 'data privacy proof os');
  assertString(document.capture.os.id, 'data privacy proof os id');
  assertString(document.capture.os.versionId, 'data privacy proof os version');
  validateEnvironmentMetadata(document.capture, environmentId);
  validateSourceEvidence(repoRoot, document.sourceEvidence);
  validateInventory(repoRoot, document.inventory, document.sourceEvidence);
  validateControls(document.controls);
  validateCases(document.cases);
  assertNoSensitiveMaterial(document);
  return document;
}

export function validateP40DataPrivacyProof({
  repoRoot,
  snapshot,
  targetHead,
  environmentId,
  candidateRunId,
  candidateArtifactDigest
}) {
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId)) {
    throw new Error('data privacy proof environment is outside the support matrix');
  }
  return validateDocument({
    repoRoot,
    document: parseJson(snapshot.bytes, 'data privacy proof'),
    targetHead,
    environmentId,
    candidateRunId,
    candidateArtifactDigest
  });
}

export function parseP40Json(bytes, label = 'data privacy proof') {
  return parseJson(bytes, label);
}

export function sourceContractPaths() {
  return Object.keys(P40_SOURCE_CONTRACTS);
}

export function sourceContractMarkers() {
  return Object.fromEntries(Object.entries(P40_SOURCE_CONTRACTS).map(([key, value]) => [key, [...value]]));
}

export function canonicalSourceEvidence(repoRoot) {
  return sourceContractPaths().map((relativePath) => {
    const snapshot = sha256File(repoRoot, relativePath, `data privacy source ${relativePath}`);
    return { path: relativePath, sha256: snapshot.sha256 };
  });
}

export function canonicalInventory(repoRoot) {
  const snapshot = sha256File(repoRoot, 'packages/data-domains/registry.json', 'data privacy domain registry');
  const registry = parseJson(snapshot.bytes, 'data privacy domain registry');
  if (!Array.isArray(registry.domains) || registry.domains.length !== P40_DOMAIN_IDS.length) {
    throw new Error('data privacy domain registry does not contain exactly twelve domains');
  }
  return {
    domainCount: registry.domains.length,
    domains: registry.domains.map((domain) => ({
      actions: [...domain.actions],
      encryptionTier: domain.encryptionTier,
      id: domain.id,
      retention: domain.retention
    })),
    registryPath: snapshot.path,
    registrySha256: snapshot.sha256
  };
}

export function canonicalControls() {
  return {
    export: {
      audit: true,
      cancel: true,
      redacted: true,
      scopeSelection: true,
      sealedFacetProtection: true
    },
    deletion: {
      accountScope: 'server-coordinated',
      auditIntent: true,
      confirmation: true,
      localScope: 'daemon-owned',
      partialFailureRetry: true,
      secureEraseMeaningful: true,
      serverReceipt: true
    },
    retention: {
      appendOnly: true,
      expiry: true,
      rolling: true,
      untilDeleted: true,
      untilRevoked: true
    },
    recovery: {
      failureClosed: true,
      rawKeyNeverSent: true,
      setup: true,
      success: true
    },
    consent: {
      cloudSyncDefault: 'off',
      cloudSyncOptOut: true,
      emissionGate: 'consent-required',
      persisted: true,
      telemetryDefault: 'off',
      telemetryOptOut: true
    },
    panic: {
      allScope: true,
      audit: true,
      syncScope: true,
      typedConfirmation: true
    },
    redaction: {
      diagnostics: true,
      export: true,
      paths: true,
      pii: true,
      secrets: true,
      supportBundle: true,
      telemetry: true
    }
  };
}

export function canonicalCases() {
  return {
    'export-preview': { cancelable: true, passed: true, previewed: true },
    'export-cancel': { noWrite: true, passed: true, userCancelled: true },
    'export-encrypt': { passed: true, sealedFacetProtection: true, secretBytesObserved: false },
    'export-redaction': { passed: true, piiOccurrences: 0, redacted: true },
    'local-delete': { auditIntent: true, passed: true, scope: 'local' },
    'account-delete': { passed: true, scope: 'account', serverReceipt: true },
    'partial-failure': { destroyedPartialData: false, passed: true, retryable: true },
    'retention-expiry': { auditPreserved: true, expiredDataRemoved: true, passed: true },
    'recovery-success': { passed: true, rawKeyTransmitted: false, recovered: true },
    'recovery-failure': { failedClosed: true, passed: true, rawKeyTransmitted: false },
    'telemetry-opt-out': { emitted: false, passed: true, requiresConsent: true },
    'cloud-sync-opt-out': { passed: true, requiresConsent: true, uploaded: false },
    'offline-queueing': { consentRecheckedOnFlush: true, passed: true, queuedLocally: true },
    'locked-keyring': { failedClosed: true, localPlaintextFallback: false, passed: true },
    'panic-sync': { passed: true, revoked: true, scope: 'sync', typedConfirmation: true },
    'panic-all': { passed: true, revoked: true, scope: 'all', typedConfirmation: true }
  };
}

export function sha256Bytes(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}
