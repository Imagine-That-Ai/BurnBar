import fs from 'node:fs';
import path from 'node:path';
import { readRegularSnapshot, SUPPORT_ENVIRONMENTS } from './product-proof-closure.mjs';

export const P07_REQUIREMENT_ID = 'P-07';
export const P07_PROOF_ID = 'openburnbar-linux-computer-use-proof-v1';
export const P07_SESSION_ID = 'openburnbar-linux-computer-use-session-v1';
export const P07_PROOF_ROLE = 'feature.computer-use';
export const P07_PROOF_FILENAME = 'p07-computer-use-proof.json';
export const P07_TARGET_IDS = Object.freeze([
  'VAL-CU-001',
  'VAL-CU-002',
  'VAL-CU-003',
  'VAL-MEDIA-001',
  'VAL-MOBILE-001',
  'VAL-SEC-003'
]);
export const P07_REJECTION_POLICY_FIELDS = Object.freeze([
  'fixtureOnlyRowsAcceptedAsPass',
  'staleTmpOnlyRowsAcceptedAsPass',
  'panicSessionMediaSimulatorOnlyAcceptedAsPass',
  'dockerHttpMobileRemoteOnlyAcceptedAsPass',
  'x11OrXtestFallbackAcceptedAsPass',
  'mediaSimulatorTimingOnlyAcceptedAsPass'
]);

const HEAD = /^[a-f0-9]{40,64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const PHYSICAL_MOBILE_CONTROLLERS = new Set(['physical-android', 'physical-ipad', 'physical-iphone']);

function exactObject(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value;
}

function exactStringSet(actual, expected, label) {
  if (!Array.isArray(actual) || actual.length !== expected.length
      || [...actual].sort().join('\0') !== [...expected].sort().join('\0')) {
    throw new Error(`${label} must contain exactly: ${expected.join(', ')}`);
  }
}

function validateBinding(session, expected) {
  if (session.schemaVersion !== 1 || session.id !== P07_SESSION_ID
      || session.requirementId !== P07_REQUIREMENT_ID
      || session.environmentId !== expected.environmentId
      || session.targetHead !== expected.targetHead) {
    throw new Error('P-07 live session is not bound to the requested requirement, environment, and HEAD');
  }
  const candidate = exactObject(session.candidate, 'P-07 session candidate');
  if (!RUN_ID.test(candidate.runId ?? '') || !DIGEST.test(candidate.artifactDigest ?? '')
      || candidate.runId !== String(expected.candidateRunId)
      || candidate.artifactDigest !== expected.candidateArtifactDigest) {
    throw new Error('P-07 live session is not bound to the requested release candidate');
  }
}

function validateCapture(session, expected) {
  const capture = exactObject(session.capture, 'P-07 capture metadata');
  if (capture.mode !== 'installed-native-live' || capture.candidateExecuted !== true
      || capture.browserBackend !== 'playwright-chromium'
      || !PHYSICAL_MOBILE_CONTROLLERS.has(capture.mobileController)
      || capture.checkoutHead !== expected.targetHead
      || capture.installedArtifactDigest !== expected.candidateArtifactDigest) {
    throw new Error('P-07 capture must exercise the installed candidate with Playwright and a physical mobile controller');
  }
  const started = Date.parse(capture.startedAt ?? '');
  const completed = Date.parse(capture.completedAt ?? '');
  if (!Number.isFinite(started) || !Number.isFinite(completed) || completed < started) {
    throw new Error('P-07 capture timestamps are invalid');
  }
}

function validateRejectionPolicy(session) {
  const policy = exactObject(session.rejectionPolicy, 'P-07 rejection policy');
  for (const field of P07_REJECTION_POLICY_FIELDS) {
    if (policy[field] !== false) throw new Error(`P-07 rejection policy must reject ${field}`);
  }
}

function normalizeTargets(session) {
  exactStringSet(session.targetIds, P07_TARGET_IDS, 'P-07 targetIds');
  const targets = exactObject(session.targets, 'P-07 targets');
  exactStringSet(Object.keys(targets), P07_TARGET_IDS, 'P-07 target rows');
  for (const target of P07_TARGET_IDS) {
    const row = exactObject(targets[target], `P-07 ${target} row`);
    if (row.target !== target || row.status !== 'pass' || row.acceptedAsPass !== true
        || row.notClaimedAsPass === true || row.evidenceClass !== 'installed-native-live') {
      throw new Error(`P-07 ${target} is not an installed-native accepted pass`);
    }
    if (!Array.isArray(row.evidence) || row.evidence.length === 0
        || row.evidence.some((entry) => typeof entry !== 'string' || entry.length === 0)) {
      throw new Error(`P-07 ${target} has no evidence artifact list`);
    }
    if ((Array.isArray(row.failures) && row.failures.length > 0)
        || (Array.isArray(row.blockers) && row.blockers.length > 0)) {
      throw new Error(`P-07 ${target} contains failures or blockers`);
    }
  }
  if (targets['VAL-CU-003'].prerequisite !== 'VAL-CU-002') {
    throw new Error('P-07 panic proof must depend on the installed input-adapter proof');
  }
  if (!Array.isArray(session.failedTargets) || session.failedTargets.length !== 0) {
    throw new Error('P-07 live session contains failed targets');
  }
  return targets;
}

function inputRootPrefix(repoRoot, inputRoot) {
  const relative = path.relative(repoRoot, inputRoot).split(path.sep).join('/');
  return `${relative}/`;
}

function validateSourceEvidence(session, targets, repoRoot, inputRoot) {
  if (!Array.isArray(session.sourceEvidence) || session.sourceEvidence.length === 0) {
    throw new Error('P-07 live session has no source evidence');
  }
  const rootPrefix = inputRootPrefix(repoRoot, inputRoot);
  const records = [];
  const byPath = new Map();
  for (const [index, record] of session.sourceEvidence.entries()) {
    exactObject(record, `P-07 source evidence ${index}`);
    if (typeof record.path !== 'string' || !record.path.startsWith(rootPrefix)
        || !SHA256.test(record.sha256 ?? '') || !Number.isSafeInteger(record.size) || record.size <= 0
        || record.captureMode !== 'installed-native-live') {
      throw new Error(`P-07 source evidence ${index} is not a canonical installed-native record`);
    }
    if (byPath.has(record.path)) throw new Error(`P-07 source evidence repeats ${record.path}`);
    const repositorySnapshot = readRegularSnapshot(repoRoot, record.path, `P-07 source evidence ${record.path}`);
    if (repositorySnapshot.sha256 !== record.sha256 || repositorySnapshot.size !== record.size) {
      throw new Error(`P-07 source evidence changed: ${record.path}`);
    }
    const relativeToInput = path.relative(inputRoot, repositorySnapshot.absolute).split(path.sep).join('/');
    readRegularSnapshot(inputRoot, relativeToInput, `P-07 source evidence ${record.path}`);
    const targetIds = record.targetIds;
    if (!Array.isArray(targetIds) || targetIds.length === 0
        || new Set(targetIds).size !== targetIds.length
        || targetIds.some((id) => !P07_TARGET_IDS.includes(id))) {
      throw new Error(`P-07 source evidence has invalid target coverage: ${record.path}`);
    }
    const normalized = {
      path: repositorySnapshot.path,
      sha256: repositorySnapshot.sha256,
      size: repositorySnapshot.size,
      captureMode: record.captureMode,
      targetIds: [...targetIds]
    };
    byPath.set(record.path, normalized);
    records.push(normalized);
  }
  for (const target of P07_TARGET_IDS) {
    for (const reference of targets[target].evidence) {
      const record = byPath.get(reference);
      if (!record || !record.targetIds.includes(target)) {
        throw new Error(`P-07 ${target} references unregistered source evidence: ${reference}`);
      }
    }
  }
  return records;
}

export function validateP07CandidateSession({
  session,
  repoRoot,
  inputRoot,
  environmentId,
  targetHead,
  candidateRunId,
  candidateArtifactDigest
}) {
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId)) throw new Error(`unknown support environment: ${environmentId}`);
  if (!HEAD.test(targetHead) || !RUN_ID.test(String(candidateRunId)) || !DIGEST.test(candidateArtifactDigest)) {
    throw new Error('P-07 requested candidate binding is invalid');
  }
  exactObject(session, 'P-07 live session');
  validateBinding(session, { environmentId, targetHead, candidateRunId, candidateArtifactDigest });
  validateCapture(session, { targetHead, candidateArtifactDigest });
  validateRejectionPolicy(session);
  const targets = normalizeTargets(session);
  const sourceEvidence = validateSourceEvidence(session, targets, repoRoot, inputRoot);
  return { targets, sourceEvidence };
}
