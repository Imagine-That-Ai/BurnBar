import crypto from 'node:crypto';
import path from 'node:path';
import { readRegularSnapshot, SUPPORT_ENVIRONMENTS } from './product-proof-closure.mjs';

export const P06_PROOF_ROLE = 'feature.gateway-credential-boundary-installed';
export const P06_PROOF_FILENAME = 'gateway-credential-boundary-installed.json';
export const P06_SESSION_FILENAME = 'p06-gateway-boundary-session.json';

export const P06_SOURCE_CONTRACTS = Object.freeze([
  'apps/linux-desktop/src-tauri/src/desktop/gateway.rs',
  'apps/linux-desktop/src-tauri/src/desktop/tray_runtime.rs',
  'apps/linux-desktop/src-tauri/src/desktop/tests_core.rs',
  'apps/linux-desktop/src/tauriBridge.ts',
  'apps/linux-desktop/src/chat/gatewayClient.ts',
  'apps/linux-desktop/src-tauri/tauri.conf.json',
  'scripts/linux-port/run-p06-gateway-boundary-session.mjs'
]);

const SOURCE_MARKERS = Object.freeze({
  'apps/linux-desktop/src-tauri/src/desktop/gateway.rs': [
    'gateway_endpoint_from_health', 'gateway_non_loopback_host_refused', '.bearer_auth(token)',
    'gateway_chat_stream', 'gateway_chat_cancel', 'GATEWAY_MAX_RESPONSE_BYTES'
  ],
  'apps/linux-desktop/src-tauri/src/desktop/tray_runtime.rs': [
    'gateway_probe', 'gateway_chat_stream', 'gateway_chat_cancel'
  ],
  'apps/linux-desktop/src-tauri/src/desktop/tests_core.rs': [
    'gateway_endpoint_is_fixed_to_loopback_health_authority', 'gateway_non_loopback_host_refused'
  ],
  'apps/linux-desktop/src/tauriBridge.ts': [
    "invoke<boolean>('gateway_probe')", "invoke<void>('gateway_chat_stream'", "invoke<void>('gateway_chat_cancel'"
  ],
  'apps/linux-desktop/src/chat/gatewayClient.ts': [
    'NativeGatewayChatTransport', 'OpenAICompatibleSSEParser'
  ],
  'apps/linux-desktop/src-tauri/tauri.conf.json': ['connect-src'],
  'scripts/linux-port/run-p06-gateway-boundary-session.mjs': [
    'verifyInstalledCandidate', 'inspectRendererProcesses', 'secretOccurrences: processes.secretOccurrences + assets.secretOccurrences'
  ]
});

const HEAD = /^[a-f0-9]{40,64}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;
const VERSION = /^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$/u;
const FORBIDDEN_MATERIAL = /\bBearer\s+|(?:^|\W)(?:sk|pk|AIza)[-_A-Za-z0-9]{8,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/u;

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

function truthyFields(value, keys, label) {
  for (const key of keys) if (value[key] !== true) throw new Error(`${label}.${key} is not proven`);
}

function expectedEnvironment(environmentId) {
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId)) throw new Error('P-06 environment is outside the support matrix');
  const architecture = environmentId.endsWith('-aarch64') ? 'aarch64' : 'x86_64';
  const session = environmentId.includes('-x11-') ? 'x11' : 'wayland';
  if (environmentId.startsWith('ubuntu-')) return { architecture, session, desktop: 'gnome', os: 'ubuntu', version: '24.04', format: 'deb' };
  if (environmentId.startsWith('fedora-')) return { architecture, session, desktop: 'kde', os: 'fedora', version: null, format: 'rpm' };
  return { architecture, session, desktop: 'sway', os: 'arch', version: null, format: 'arch' };
}

function assertNoSecretMaterial(value, label = 'P-06 proof') {
  if (value === null || typeof value === 'number' || typeof value === 'boolean') return;
  if (typeof value === 'string') {
    if (FORBIDDEN_MATERIAL.test(value)) throw new Error(`${label} contains credential-like material`);
    return;
  }
  if (Array.isArray(value)) return value.forEach((entry, index) => assertNoSecretMaterial(entry, `${label}[${index}]`));
  object(value, label);
  for (const [key, entry] of Object.entries(value)) {
    if (/^(?:secret|password|passphrase|token|bearer|authorization|credentialValue|plaintext|rawBytes)$/iu.test(key)) {
      throw new Error(`${label}.${key} is forbidden`);
    }
    assertNoSecretMaterial(entry, `${label}.${key}`);
  }
}

export function p06SourceContractMarkers() {
  return Object.fromEntries(Object.entries(SOURCE_MARKERS).map(([key, markers]) => [key, [...markers]]));
}

export function canonicalP06SourceEvidence(repoRoot) {
  return P06_SOURCE_CONTRACTS.map((relativePath) => {
    const snapshot = readRegularSnapshot(repoRoot, relativePath, `P-06 source ${relativePath}`);
    return { path: relativePath, sha256: snapshot.sha256 };
  });
}

function validateSources(repoRoot, rows) {
  if (!Array.isArray(rows) || rows.length !== P06_SOURCE_CONTRACTS.length) throw new Error('P-06 source evidence is incomplete');
  const seen = new Set();
  for (const row of rows) {
    exact(row, ['path', 'sha256'], 'P-06 source evidence row');
    if (!P06_SOURCE_CONTRACTS.includes(row.path) || seen.has(row.path) || !SHA256.test(row.sha256 ?? '')) {
      throw new Error('P-06 source evidence is not canonical');
    }
    seen.add(row.path);
    const snapshot = readRegularSnapshot(repoRoot, row.path, `P-06 source ${row.path}`);
    if (snapshot.sha256 !== row.sha256) throw new Error(`P-06 source evidence hash changed: ${row.path}`);
    const text = snapshot.bytes.toString('utf8');
    for (const marker of SOURCE_MARKERS[row.path]) {
      if (!text.includes(marker)) throw new Error(`${row.path} is missing P-06 gateway marker`);
    }
  }
  const native = readRegularSnapshot(repoRoot, P06_SOURCE_CONTRACTS[0], 'P-06 native gateway').bytes.toString('utf8');
  if (/\[tauri::command\][\s\S]{0,160}(?:fn|async\s+fn)\s+gateway_auth_token/u.test(native)) {
    throw new Error('P-06 native gateway exposes a bearer-returning command');
  }
  const renderer = [P06_SOURCE_CONTRACTS[3], P06_SOURCE_CONTRACTS[4]]
    .map((file) => readRegularSnapshot(repoRoot, file, `P-06 renderer ${file}`).bytes.toString('utf8')).join('\n');
  if (/\bgatewayAuthToken\b|\bbearerToken\b|\bAuthorization\b|\bfetch\s*\(/u.test(renderer)) {
    throw new Error('P-06 renderer source exposes a credential or direct network surface');
  }
}

export function validateP06GatewayBoundarySession(document, {
  environmentId, targetHead, candidateRunId, candidateArtifactDigest
}) {
  const expected = expectedEnvironment(environmentId);
  exact(document, ['candidate', 'capture', 'environmentId', 'id', 'nativeProxy', 'package', 'redaction', 'rendererIsolation', 'requirementId', 'schemaVersion', 'targetHead'], 'P-06 session');
  if (document.schemaVersion !== 1 || document.id !== 'openburnbar-linux-p06-gateway-boundary-session-v1'
      || document.requirementId !== 'P-06' || document.environmentId !== environmentId
      || document.targetHead !== targetHead || !HEAD.test(document.targetHead ?? '')) {
    throw new Error('P-06 session is not invocation-bound');
  }
  exact(document.candidate, ['artifactDigest', 'runId'], 'P-06 candidate');
  if (document.candidate.runId !== String(candidateRunId) || document.candidate.artifactDigest !== candidateArtifactDigest
      || !RUN_ID.test(document.candidate.runId) || !DIGEST.test(document.candidate.artifactDigest)) {
    throw new Error('P-06 session candidate does not match the selected release');
  }
  exact(document.capture, ['architecture', 'desktop', 'mode', 'os', 'platform', 'session'], 'P-06 capture');
  exact(document.capture.os, ['id', 'versionId'], 'P-06 capture os');
  if (document.capture.platform !== 'linux' || document.capture.mode !== 'installed-live-renderer-boundary'
      || document.capture.architecture !== expected.architecture || document.capture.session.toLowerCase() !== expected.session
      || !document.capture.desktop.toLowerCase().includes(expected.desktop) || document.capture.os.id !== expected.os
      || (expected.version !== null && document.capture.os.versionId !== expected.version)) {
    throw new Error('P-06 capture does not match the installed support environment');
  }
  exact(document.package, ['architecture', 'format', 'installed', 'manifestSha256', 'source', 'version'], 'P-06 package');
  if (document.package.architecture !== expected.architecture || document.package.format !== expected.format
      || document.package.installed !== true || document.package.source !== 'signed-installed-candidate'
      || !SHA256.test(document.package.manifestSha256 ?? '') || !VERSION.test(document.package.version ?? '')) {
    throw new Error('P-06 package is not the signed installed candidate');
  }
  exact(document.nativeProxy, [
    'authenticationInjectedNatively', 'boundedRequest', 'boundedResponse', 'cancellationOwnedNatively',
    'commandsRegistered', 'installedBinaryMatchedManifest', 'loopbackOnly', 'productionBinaryInspected'
  ], 'P-06 native proxy');
  truthyFields(document.nativeProxy, Object.keys(document.nativeProxy), 'P-06 native proxy');
  exact(document.rendererIsolation, [
    'cspBlocksDirectNetwork', 'desktopProcessLive', 'directFetchAbsent', 'installedAssetsMatchedManifest',
    'rendererArgumentsScanned', 'rendererAssetsScanned', 'rendererEnvironmentScanned', 'rendererProcessCount',
    'rendererProcessesLive', 'tauriCredentialCommandAbsent'
  ], 'P-06 renderer isolation');
  truthyFields(document.rendererIsolation, [
    'cspBlocksDirectNetwork', 'desktopProcessLive', 'directFetchAbsent', 'installedAssetsMatchedManifest',
    'rendererArgumentsScanned', 'rendererAssetsScanned', 'rendererEnvironmentScanned',
    'rendererProcessesLive', 'tauriCredentialCommandAbsent'
  ], 'P-06 renderer isolation');
  if (!Number.isInteger(document.rendererIsolation.rendererProcessCount) || document.rendererIsolation.rendererProcessCount < 1) {
    throw new Error('P-06 did not inspect a live renderer process');
  }
  exact(document.redaction, ['diagnosticsRedacted', 'secretBytesCaptured', 'secretOccurrences', 'stderrRedacted', 'stdoutRedacted'], 'P-06 redaction');
  if (document.redaction.diagnosticsRedacted !== true || document.redaction.stderrRedacted !== true
      || document.redaction.stdoutRedacted !== true || document.redaction.secretBytesCaptured !== false
      || document.redaction.secretOccurrences !== 0) throw new Error('P-06 proof exposes gateway credential material');
  assertNoSecretMaterial(document);
  return document;
}

export function buildP06GatewayBoundaryProof({ session, sourcePath, sourceSha256, repoRoot }) {
  const document = {
    schemaVersion: 1,
    requirementId: 'P-06',
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: structuredClone(session.candidate),
    capture: structuredClone(session.capture),
    source: { method: 'installed-live-renderer-boundary-session', path: sourcePath, sha256: sourceSha256 },
    sourceEvidence: canonicalP06SourceEvidence(repoRoot),
    observed: structuredClone(session),
    passed: true
  };
  assertNoSecretMaterial(document);
  return document;
}

export function validateP06GatewayBoundaryProof({
  repoRoot, snapshot, environmentId, targetHead, candidateRunId, candidateArtifactDigest, sourceSnapshot
}) {
  let document;
  try { document = JSON.parse(snapshot.bytes.toString('utf8')); } catch (error) { throw new Error(`P-06 proof is not JSON: ${error.message}`); }
  exact(document, ['candidate', 'capture', 'environmentId', 'observed', 'passed', 'requirementId', 'schemaVersion', 'source', 'sourceEvidence', 'targetHead'], 'P-06 proof');
  if (document.schemaVersion !== 1 || document.requirementId !== 'P-06' || document.environmentId !== environmentId
      || document.targetHead !== targetHead || document.passed !== true) throw new Error('P-06 proof is not a passed candidate-bound proof');
  exact(document.source, ['method', 'path', 'sha256'], 'P-06 proof source');
  if (document.source.method !== 'installed-live-renderer-boundary-session'
      || !document.source.path.endsWith(`/${P06_SESSION_FILENAME}`) || !SHA256.test(document.source.sha256 ?? '')) {
    throw new Error('P-06 proof source is not canonical');
  }
  if (sourceSnapshot !== undefined && (sourceSnapshot.sha256 !== document.source.sha256
      || !sourceSnapshot.bytes.equals(Buffer.from(`${JSON.stringify(document.observed, null, 2)}\n`)))) {
    throw new Error('P-06 proof source does not match the captured session bytes');
  }
  validateP06GatewayBoundarySession(document.observed, { environmentId, targetHead, candidateRunId, candidateArtifactDigest });
  if (JSON.stringify(document.candidate) !== JSON.stringify(document.observed.candidate)
      || JSON.stringify(document.capture) !== JSON.stringify(document.observed.capture)) {
    throw new Error('P-06 proof binding is inconsistent');
  }
  validateSources(repoRoot, document.sourceEvidence);
  assertNoSecretMaterial(document);
  return document;
}

export function sha256P06(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

export function normalizeEvidencePath(repoRoot, file) {
  return path.relative(repoRoot, file).split(path.sep).join('/');
}
