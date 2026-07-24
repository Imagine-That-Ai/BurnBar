import { readRegularSnapshot } from '../lib/product-proof-closure.mjs';
import { result, validateRequirementContext } from './lib.mjs';

const PROOF_ROLE = 'feature.computer-use';
const PROOF_MEDIA_TYPE = 'application/json';
const TARGET_IDS = Object.freeze([
  'VAL-CU-001',
  'VAL-CU-002',
  'VAL-CU-003',
  'VAL-MEDIA-001',
  'VAL-MOBILE-001',
  'VAL-SEC-003'
]);
const CANDIDATE_DIGEST = /^sha256:[a-f0-9]{64}$/u;
const CANDIDATE_RUN_ID = /^[1-9][0-9]*$/u;
const HEAD = /^[a-f0-9]{40,64}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const P07_INPUT_ROOT = 'docs/linux-port/evidence/product-parity-inputs/P-07/';
const REJECTION_POLICY_FIELDS = Object.freeze([
  'fixtureOnlyRowsAcceptedAsPass',
  'staleTmpOnlyRowsAcceptedAsPass',
  'panicSessionMediaSimulatorOnlyAcceptedAsPass',
  'dockerHttpMobileRemoteOnlyAcceptedAsPass',
  'x11OrXtestFallbackAcceptedAsPass',
  'mediaSimulatorTimingOnlyAcceptedAsPass'
]);

function parseJson(snapshot, label) {
  try {
    return JSON.parse(snapshot.bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function exactObject(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value;
}

function validateBinding(document, context, closure) {
  if (document.schemaVersion !== 1
      || document.id !== 'openburnbar-linux-computer-use-proof-v1'
      || document.requirementId !== 'P-07'
      || document.environmentId !== context.environmentId
      || document.targetHead !== context.targetHead
      || !HEAD.test(document.targetHead)) {
    throw new Error('P-07 computer-use proof is not bound to the invoked requirement, environment, or HEAD');
  }
  const candidate = exactObject(document.candidate, 'P-07 candidate binding');
  if (!CANDIDATE_RUN_ID.test(candidate.runId ?? '')
      || !CANDIDATE_DIGEST.test(candidate.artifactDigest ?? '')
      || candidate.runId !== closure.candidate.runId
      || candidate.artifactDigest !== closure.candidate.artifactDigest) {
    throw new Error('P-07 computer-use proof candidate binding does not match the release closure');
  }
}

function normalizeTargets(document) {
  const raw = document.targets;
  let rows;
  if (Array.isArray(raw)) {
    rows = raw.map((row, index) => {
      exactObject(row, `P-07 target ${index}`);
      if (typeof row.target !== 'string') throw new Error(`P-07 target ${index} has no target id`);
      return row;
    });
  } else {
    exactObject(raw, 'P-07 targets');
    rows = Object.entries(raw).map(([target, row]) => {
      exactObject(row, `P-07 target ${target}`);
      if (row.target !== undefined && row.target !== target) {
        throw new Error(`P-07 target ${target} has a conflicting target id`);
      }
      return { ...row, target };
    });
  }
  const byTarget = new Map();
  for (const row of rows) {
    if (!TARGET_IDS.includes(row.target) || byTarget.has(row.target)) {
      throw new Error(`P-07 target set must contain exactly: ${TARGET_IDS.join(', ')}`);
    }
    byTarget.set(row.target, row);
  }
  if (byTarget.size !== TARGET_IDS.length || TARGET_IDS.some((target) => !byTarget.has(target))) {
    throw new Error(`P-07 target set must contain exactly: ${TARGET_IDS.join(', ')}`);
  }
  if (document.targetIds !== undefined) {
    if (!Array.isArray(document.targetIds)
        || document.targetIds.length !== TARGET_IDS.length
        || [...document.targetIds].sort().join('\0') !== [...TARGET_IDS].sort().join('\0')) {
      throw new Error(`P-07 targetIds must contain exactly: ${TARGET_IDS.join(', ')}`);
    }
  }
  return byTarget;
}

function validateRejectionPolicy(document) {
  const policy = exactObject(document.rejectionPolicy, 'P-07 rejection policy');
  for (const field of REJECTION_POLICY_FIELDS) {
    if (policy[field] !== false) {
      throw new Error(`P-07 rejection policy must reject ${field}`);
    }
  }
}

function validateTargetRows(document, byTarget) {
  if (document.failedTargets !== undefined
      && (!Array.isArray(document.failedTargets) || document.failedTargets.length !== 0)) {
    throw new Error('P-07 computer-use proof contains failed targets');
  }
  for (const target of TARGET_IDS) {
    const row = byTarget.get(target);
    if (row.status !== 'pass' || row.acceptedAsPass !== true || row.notClaimedAsPass === true) {
      throw new Error(`P-07 target ${target} is not an accepted pass`);
    }
    if (!Array.isArray(row.evidence) || row.evidence.length === 0
        || row.evidence.some((entry) => typeof entry !== 'string' || entry.length === 0)) {
      throw new Error(`P-07 target ${target} has no evidence artifact list`);
    }
    if ((Array.isArray(row.failures) && row.failures.length > 0)
        || (Array.isArray(row.blockers) && row.blockers.length > 0)) {
      throw new Error(`P-07 target ${target} contains failures or blockers`);
    }
  }
  if (byTarget.get('VAL-CU-003').prerequisite !== 'VAL-CU-002'
      && byTarget.get('VAL-CU-003').dependency !== 'VAL-CU-002') {
    throw new Error('P-07 panic proof is not explicitly dependent on the input-adapter proof');
  }
}

function validateSourceEvidence(document, context, byTarget) {
  if (!Array.isArray(document.sourceEvidence) || document.sourceEvidence.length === 0) {
    throw new Error('P-07 computer-use proof has no source evidence records');
  }
  const records = [];
  const paths = new Set();
  for (const [index, record] of document.sourceEvidence.entries()) {
    exactObject(record, `P-07 source evidence ${index}`);
    if (typeof record.path !== 'string' || !record.path.startsWith(P07_INPUT_ROOT)
        || !SHA256.test(record.sha256 ?? '')) {
      throw new Error(`P-07 source evidence ${index} must remain under the P-07 evidence root with SHA-256`);
    }
    if (paths.has(record.path)) throw new Error(`P-07 source evidence repeats ${record.path}`);
    paths.add(record.path);
    const snapshot = readRegularSnapshot(context.repoRoot, record.path, `P-07 source evidence ${record.path}`);
    if (snapshot.sha256 !== record.sha256) throw new Error(`P-07 source evidence hash changed: ${record.path}`);
    if (record.size !== undefined && record.size !== snapshot.size) {
      throw new Error(`P-07 source evidence size changed: ${record.path}`);
    }
    records.push({ path: snapshot.path, sha256: snapshot.sha256 });
  }
  const evidencePaths = new Set(records.map((record) => record.path));
  for (const target of TARGET_IDS) {
    const references = byTarget.get(target).evidence;
    if (!references.some((reference) => evidencePaths.has(reference)
        || records.some((record) => record.path.endsWith(`/${reference}`)))) {
      throw new Error(`P-07 source evidence does not cover ${target}`);
    }
  }
  return records;
}

function proofSubject(context, closure) {
  const features = context.subjects.features ?? [];
  if (features.length !== 1 || features[0].role !== PROOF_ROLE
      || features[0].mediaType !== PROOF_MEDIA_TYPE) {
    throw new Error(`P-07 feature proof role must occur exactly once as ${PROOF_ROLE}`);
  }
  const feature = features[0];
  const snapshot = readRegularSnapshot(context.repoRoot, feature.path, 'P-07 computer-use feature proof');
  if (snapshot.sha256 !== feature.sha256) throw new Error('P-07 computer-use feature proof bytes changed');
  const document = parseJson(snapshot, 'P-07 computer-use feature proof');
  validateBinding(document, context, closure);
  validateRejectionPolicy(document);
  const targets = normalizeTargets(document);
  validateTargetRows(document, targets);
  const sourceEvidence = validateSourceEvidence(document, context, targets);
  return { feature, document, sourceEvidence };
}

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, ['aggregate-product-proof-closure', PROOF_ROLE]);
  const proof = proofSubject(context, validated.closure);
  const featureArtifact = { path: proof.feature.path, sha256: proof.feature.sha256 };
  const artifacts = [...validated.artifacts, featureArtifact, ...proof.sourceEvidence];
  const unique = new Map();
  for (const artifact of artifacts) unique.set(artifact.path, artifact);
  return result(context, [...unique.values()]);
}
