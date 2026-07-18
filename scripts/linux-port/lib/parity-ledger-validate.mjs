/**
 * Pure, fail-closed product parity ledger validation.
 *
 * The tracked ledger declares requirements and evidence commands. Ready rows point at
 * generated attestations that bind their proof to a target HEAD; the tracked ledger
 * never tries to embed the SHA of the commit that contains itself.
 */
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { verifyGitHubArtifactProvenance } from './github-artifact-provenance.mjs';

const REQUIRED_ROW_FIELDS = [
  'id',
  'requirementId',
  'tier',
  'status',
  'scope',
  'evidencePath',
  'command',
  'platform',
  'sourceOracle',
  'acceptedDivergence',
  'owner',
  'promotionCriterion',
  'environment'
];
const REQUIRED_ENVIRONMENT_COVERAGE_FIELDS = [
  'id',
  'status',
  'evidencePath',
  'command'
];

const FORBIDDEN_HEAD_FIELDS = [
  'commit',
  'evidenceHead',
  'validatedAtHead',
  'staleWhenHeadDiffers'
];

const SUBJECT_FIELDS = [
  'releaseClosureSha256',
  'packageManifestSha256',
  'installedEnvironmentSha256',
  'runtimeManifestSha256'
];
const REGISTERED_PRODUCER_FIELDS = [
  'id',
  'version',
  'commandTemplate',
  'sourcePaths',
  'repository',
  'signerWorkflow'
];
const RECEIPT_PRODUCER_FIELDS = [
  'id',
  'version',
  'command',
  'sourceTree',
  'repository',
  'workflow',
  'sourceRef'
];
const PRODUCT_VALIDATOR_REPOSITORY = 'Imagine-That-Ai/BurnBar';
const PRODUCT_VALIDATOR_WORKFLOW = 'github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-product-parity.yml';
const ENVIRONMENT_ATTESTATION_FIELDS = [
  'schemaVersion',
  'generatedAt',
  'environmentId',
  'targetHead',
  'status',
  'artifacts',
  'git',
  'declared',
  'detected',
  'evidenceInputs',
  'checks',
  'blocked',
  'note'
];
const ENVIRONMENT_INPUT_FIELDS = ['path', 'sha256', 'passed', 'commit'];
const ENVIRONMENT_CHECK_FIELDS = ['id', 'passed', 'detail'];
const ENVIRONMENT_GIT_FIELDS = ['commit', 'branch', 'remote', 'dirty', 'dirtyEntries', 'gitAvailable'];
const ENVIRONMENT_DECLARED_FIELDS = ['id', 'os', 'desktop', 'session', 'architecture'];
const HEAD_PATTERN = /^[a-f0-9]{40,64}$/u;

export const PRODUCT_ATTESTER_PATH = 'scripts/linux-port/attest-product-requirement.mjs';
export const PRODUCT_EVIDENCE_POLICY_PATH = 'docs/linux-port/product-parity-evidence-policies.json';
export const PRODUCT_EVIDENCE_POLICY_ID = 'openburnbar-linux-product-parity-evidence-policies-v1';
export const PRODUCT_REQUIREMENTS_SHA256 = '1ea8f51cd0a38fc73f616230398ccf87815a065485f6f6b53d5cb55a83e53a62';
const PRODUCT_REQUIREMENTS_ID = 'openburnbar-linux-macos-parity-v1';

export function canonicalProductAttestationCommand(requirementId) {
  return `node ${PRODUCT_ATTESTER_PATH} --requirement ${requirementId}`;
}

function canonicalValidatorCommand(requirementId, checkId, environmentId) {
  return [
    'node scripts/linux-port/run-product-requirement-validator.mjs',
    `--requirement ${requirementId}`,
    `--environment ${environmentId}`,
    `--release-closure docs/linux-port/evidence/product-parity-inputs/${requirementId}/${environmentId}/release-closure.json`,
    `--output docs/linux-port/evidence/validator-receipts/${requirementId}/${checkId}/${environmentId}.json`
  ].join(' ');
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function isInside(parent, child) {
  return child === parent || child.startsWith(`${parent}${path.sep}`);
}

/** Resolve both lexical traversal and symlink escapes without requiring the leaf to exist. */
function resolveConfinedPath(repoRoot, relativePath) {
  const root = fs.realpathSync(repoRoot);
  if (typeof relativePath !== 'string' || relativePath.length === 0) {
    return { error: 'path must be a non-empty string' };
  }
  if (path.isAbsolute(relativePath)) return { error: 'absolute paths are forbidden' };
  if (relativePath.includes('\\') || path.posix.normalize(relativePath) !== relativePath) {
    return { error: 'path is not a canonical repository-relative POSIX path' };
  }

  const lexical = path.resolve(root, relativePath);
  if (!isInside(root, lexical)) return { error: 'path escapes the repository' };

  let current = root;
  let ancestor = root;
  for (const component of path.relative(root, lexical).split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    let stat;
    try {
      stat = fs.lstatSync(current);
    } catch (error) {
      if (error.code === 'ENOENT') break;
      return { error: `path inspection failed: ${error.message}` };
    }
    if (stat.isSymbolicLink()) return { error: 'path traverses a symlink' };
    ancestor = current;
  }
  const realAncestor = fs.realpathSync(ancestor);
  if (!isInside(root, realAncestor)) return { error: 'path escapes the repository through a symlink' };

  const exists = fs.existsSync(lexical);
  if (exists) {
    const real = fs.realpathSync(lexical);
    if (!isInside(root, real)) return { error: 'path escapes the repository through a symlink' };
    return { path: real, exists: true };
  }
  return { path: lexical, exists: false };
}

function validateAcceptedDivergence(value, fail, row) {
  if (typeof value === 'string') {
    if (value.trim().length === 0) fail('acceptedDivergence must not be empty', row);
    return;
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    fail('acceptedDivergence must be a string or structured divergence record', row);
    return;
  }
  for (const field of ['reason', 'owner', 'linuxNativeOutcome', 'reviewCriterion']) {
    if (typeof value[field] !== 'string' || value[field].trim().length === 0) {
      fail(`acceptedDivergence.${field} is required`, row);
    }
  }
}

function validateEvidencePolicies(policies, requirementRows, minimumSupportMatrix, options, failStructural) {
  if (policies === null || typeof policies !== 'object' || Array.isArray(policies)) {
    failStructural('product parity evidence policy manifest was not loaded.');
    return new Map();
  }
  if (policies.schemaVersion !== 1) {
    failStructural('product parity evidence policy schemaVersion must be 1.');
  }
  if (policies.id !== PRODUCT_EVIDENCE_POLICY_ID) {
    failStructural(`product parity evidence policy manifest id must be ${PRODUCT_EVIDENCE_POLICY_ID}.`);
  }
  if (policies.requirementsManifest !== 'docs/linux-port/product-parity-requirements.json') {
    failStructural('evidence policies must reference the canonical product parity requirements manifest.');
  }
  const manifestFields = ['schemaVersion', 'id', 'requirementsManifest', 'policies'].sort();
  const actualManifestFields = Object.keys(policies).sort();
  if (actualManifestFields.length !== manifestFields.length
      || actualManifestFields.some((field, index) => field !== manifestFields[index])) {
    failStructural('product parity evidence policy manifest fields are not canonical.');
  }
  if (!Array.isArray(policies.policies) || policies.policies.length === 0) {
    failStructural('product parity evidence policy manifest has no policies.');
    return new Map();
  }

  const requirementIds = new Set(requirementRows.map((requirement) => requirement.id));
  const requirementsById = new Map(requirementRows.map((requirement) => [requirement.id, requirement]));
  const requiredEnvironmentIds = minimumSupportMatrix.map((environment) => environment.id);
  const byRequirement = new Map();
  for (const policy of policies.policies) {
    const requirementId = policy?.requirementId;
    if (typeof requirementId !== 'string' || requirementId.length === 0) {
      failStructural('product parity evidence policy is missing requirementId.');
      continue;
    }
    if (byRequirement.has(requirementId)) {
      failStructural(`duplicate product parity evidence policy: ${requirementId}`);
      continue;
    }
    byRequirement.set(requirementId, policy);
    const policyFields = [
      'requirementId',
      'policyVersion',
      'requiredCheckIds',
      'requiredEnvironmentIds',
      'allowedArtifactRoots',
      'minArtifactCount',
      'registeredProducer',
      'requiredSubjectFields'
    ].sort();
    const actualPolicyFields = Object.keys(policy).sort();
    if (actualPolicyFields.length !== policyFields.length
        || actualPolicyFields.some((field, index) => field !== policyFields[index])) {
      failStructural(`evidence policy ${requirementId} fields are not canonical.`);
    }
    if (!requirementIds.has(requirementId)) {
      failStructural(`evidence policy names unknown product parity requirement: ${requirementId}`);
    }
    if (!Number.isInteger(policy.policyVersion) || policy.policyVersion < 1) {
      failStructural(`evidence policy ${requirementId} has invalid policyVersion.`);
    }
    for (const field of ['requiredCheckIds', 'requiredEnvironmentIds', 'allowedArtifactRoots']) {
      const values = policy[field];
      if (!Array.isArray(values) || values.length === 0) {
        failStructural(`evidence policy ${requirementId} has no ${field}.`);
        continue;
      }
      if (new Set(values).size !== values.length) {
        failStructural(`evidence policy ${requirementId} has duplicate ${field}.`);
      }
      if (values.some((value) => typeof value !== 'string' || value.trim().length === 0)) {
        failStructural(`evidence policy ${requirementId} has invalid ${field}.`);
      }
    }
    for (const checkId of policy.requiredCheckIds ?? []) {
      if (!/^[a-z0-9][a-z0-9._-]*$/.test(checkId)) {
        failStructural(`evidence policy ${requirementId} has invalid check id: ${checkId}`);
      }
    }
    const requirement = requirementsById.get(requirementId);
    const canonicalCheckId = requirement
      ? `${requirementId.toLowerCase()}.${requirement.area}`
      : null;
    if (canonicalCheckId && !sameStringArray(policy.requiredCheckIds, [canonicalCheckId])) {
      failStructural(`evidence policy ${requirementId} check ids must be exactly: ${canonicalCheckId}`);
    }
    if (!sameStringArray(policy.requiredEnvironmentIds, requiredEnvironmentIds)) {
      failStructural(`evidence policy ${requirementId} environment matrix differs from the minimum support matrix.`);
    }
    const canonicalArtifactRoot = `docs/linux-port/evidence/product-parity-inputs/${requirementId}`;
    if (!sameStringArray(policy.allowedArtifactRoots, [canonicalArtifactRoot])) {
      failStructural(`evidence policy ${requirementId} artifact root must be exactly: ${canonicalArtifactRoot}`);
    }
    for (const artifactRoot of policy.allowedArtifactRoots ?? []) {
      const resolved = resolveConfinedPath(options.repoRoot, artifactRoot);
      if (resolved.error) {
        failStructural(`evidence policy ${requirementId} artifact root ${resolved.error}: ${artifactRoot}`);
      }
    }
    if (!Number.isInteger(policy.minArtifactCount) || policy.minArtifactCount < 1) {
      failStructural(`evidence policy ${requirementId} has invalid minArtifactCount.`);
    }
    const producer = policy.registeredProducer;
    const producerFields = producer && typeof producer === 'object' && !Array.isArray(producer)
      ? Object.keys(producer).sort()
      : [];
    if (!sameStringArray(producerFields, [...REGISTERED_PRODUCER_FIELDS].sort())) {
      failStructural(`evidence policy ${requirementId} registeredProducer fields are not canonical.`);
    } else {
      const checkId = canonicalCheckId ?? '<invalid-check>';
      const expectedTemplate = canonicalValidatorCommand(requirementId, '{checkId}', '{environment}');
      const expectedSources = [
        'scripts/linux-port/run-product-requirement-validator.mjs',
        `scripts/linux-port/product-validators/${requirementId}.mjs`
      ];
      if (producer.id !== 'openburnbar-linux-product-validator'
          || producer.version !== 1
          || producer.commandTemplate !== expectedTemplate
          || producer.repository !== PRODUCT_VALIDATOR_REPOSITORY
          || producer.signerWorkflow !== PRODUCT_VALIDATOR_WORKFLOW
          || !sameStringArray(producer.sourcePaths, expectedSources)) {
        failStructural(`evidence policy ${requirementId} registeredProducer is not canonical.`);
      }
      if (checkId === '<invalid-check>') {
        failStructural(`evidence policy ${requirementId} cannot bind a producer without a canonical check.`);
      }
    }
    if (!sameStringArray(policy.requiredSubjectFields, SUBJECT_FIELDS)) {
      failStructural(`evidence policy ${requirementId} requiredSubjectFields are not canonical.`);
    }
  }
  for (const requirementId of requirementIds) {
    if (!byRequirement.has(requirementId)) {
      failStructural(`product parity requirement ${requirementId} has no evidence policy.`);
    }
  }
  return byRequirement;
}

function validateCanonicalAttester(options, failStructural) {
  const resolved = resolveConfinedPath(options.repoRoot, PRODUCT_ATTESTER_PATH);
  if (resolved.error) {
    failStructural(`canonical product requirement attester ${resolved.error}.`);
    return;
  }
  if (!resolved.exists) {
    failStructural(`canonical product requirement attester is missing: ${PRODUCT_ATTESTER_PATH}`);
    return;
  }
  const lexical = path.join(fs.realpathSync(options.repoRoot), PRODUCT_ATTESTER_PATH);
  const stat = fs.lstatSync(lexical);
  if (stat.isSymbolicLink() || !stat.isFile()) {
    failStructural('canonical product requirement attester must be a regular, non-symlink file.');
    return;
  }
  if ((stat.mode & 0o111) === 0) {
    failStructural('canonical product requirement attester must be executable.');
  }
}

function sameStringArray(actual, expected) {
  return Array.isArray(actual)
    && actual.length === expected.length
    && actual.every((value, index) => value === expected[index]);
}

function normalizeEnvironmentArchitecture(value) {
  if (value === 'x64' || value === 'amd64') return 'x86_64';
  if (value === 'arm64' || value === 'armv8l') return 'aarch64';
  return value;
}

function normalizeEnvironmentSession(value) {
  return typeof value === 'string' ? value.trim().toLowerCase() : value;
}

function environmentDesktopMatches(expected, actual) {
  const value = typeof actual === 'string' ? actual.toLowerCase() : '';
  if (expected === 'GNOME') return value.includes('gnome');
  if (expected === 'KDE Plasma') return value.includes('kde') || value.includes('plasma');
  if (expected === 'Sway/wlroots') return value.includes('sway') || value.includes('wlroots');
  return false;
}

function environmentOSMatches(expected, detected) {
  if (expected === 'Ubuntu 24.04') {
    return detected?.osId === 'ubuntu' && detected?.osVersion === '24.04';
  }
  if (expected === 'Fedora') return detected?.osId === 'fedora';
  if (expected === 'Arch Linux') return detected?.osId === 'arch';
  return false;
}

function validateAttestation(attestation, row, policy, options, failPromotion, failStructural) {
  if (attestation?.schemaVersion !== 1) {
    failPromotion('ready evidence attestation schemaVersion must be 1', row);
    return;
  }
  if (attestation.rowId !== row.id || attestation.requirementId !== row.requirementId) {
    failPromotion('ready evidence attestation does not name its row and requirement', row);
  }
  if (attestation.targetHead !== options.currentHead) {
    failPromotion(
      `ready evidence target HEAD ${attestation.targetHead ?? '<missing>'} differs from current HEAD ${options.currentHead}`,
      row
    );
  }
  if (attestation.status !== 'passed') {
    failPromotion('ready evidence attestation status is not passed', row);
  }
  const expectedFields = [
    'schemaVersion',
    'rowId',
    'requirementId',
    'targetHead',
    'status',
    'candidate',
    'policy',
    'checks',
    'environments',
    'validatorReceipts',
    'artifacts'
  ].sort();
  const actualFields = attestation && typeof attestation === 'object' && !Array.isArray(attestation)
    ? Object.keys(attestation).sort()
    : [];
  if (actualFields.length !== expectedFields.length
      || actualFields.some((field, index) => field !== expectedFields[index])) {
    failStructural('ready evidence attestation fields are not canonical', row);
  }
  const candidateFields = attestation.candidate && typeof attestation.candidate === 'object'
    && !Array.isArray(attestation.candidate) ? Object.keys(attestation.candidate).sort() : [];
  const expectedCandidateFields = ['runId', 'artifactDigest', 'productProofClosureSha256'].sort();
  if (candidateFields.length !== expectedCandidateFields.length
      || candidateFields.some((field, index) => field !== expectedCandidateFields[index])
      || !/^[1-9][0-9]*$/u.test(attestation.candidate?.runId ?? '')
      || !/^sha256:[a-f0-9]{64}$/u.test(attestation.candidate?.artifactDigest ?? '')
      || !/^[a-f0-9]{64}$/u.test(attestation.candidate?.productProofClosureSha256 ?? '')) {
    failStructural('ready evidence candidate binding is invalid', row);
  }
  if (!policy) {
    failStructural('ready evidence attestation has no canonical policy', row);
    return;
  }
  const expectedPolicyFields = ['manifest', 'manifestId', 'policyVersion'].sort();
  const actualPolicyFields = attestation.policy && typeof attestation.policy === 'object' && !Array.isArray(attestation.policy)
    ? Object.keys(attestation.policy).sort()
    : [];
  if (actualPolicyFields.length !== expectedPolicyFields.length
      || actualPolicyFields.some((field, index) => field !== expectedPolicyFields[index])
      || attestation.policy?.manifest !== PRODUCT_EVIDENCE_POLICY_PATH
      || attestation.policy?.manifestId !== options.evidencePolicies?.id
      || attestation.policy?.policyVersion !== policy.policyVersion) {
    failPromotion('ready evidence attestation policy binding is invalid', row);
  }
  if (!sameStringArray(attestation.checks, policy.requiredCheckIds)) {
    failPromotion('ready evidence attestation check set differs from policy', row);
  }
  if (!sameStringArray(attestation.environments, policy.requiredEnvironmentIds)) {
    failPromotion('ready evidence attestation environment set differs from policy', row);
  }
  if (!Array.isArray(attestation.artifacts) || attestation.artifacts.length === 0) {
    failPromotion('ready evidence attestation has no artifact hashes', row);
    return;
  }

  const artifactPaths = new Set();
  const artifactsByPath = new Map();
  for (const artifact of attestation.artifacts) {
    const fields = artifact && typeof artifact === 'object' && !Array.isArray(artifact)
      ? Object.keys(artifact).sort()
      : [];
    if (!sameStringArray(fields, ['path', 'sha256'])) {
      failStructural('attested artifact fields are not canonical', row);
      continue;
    }
    if (artifactPaths.has(artifact?.path)) {
      failStructural(`duplicate attested artifact path: ${artifact?.path ?? '<missing>'}`, row);
      continue;
    }
    artifactPaths.add(artifact?.path);
    const resolved = resolveConfinedPath(options.repoRoot, artifact?.path);
    if (resolved.error) {
      failStructural(`attested artifact ${resolved.error}: ${artifact?.path ?? '<missing>'}`, row);
      continue;
    }
    if (!resolved.exists) {
      failPromotion(`attested artifact does not exist: ${artifact.path}`, row);
      continue;
    }
    if (!fs.statSync(resolved.path).isFile()) {
      failStructural(`attested artifact must be a regular file: ${artifact.path}`, row);
      continue;
    }
    if (!/^[a-f0-9]{64}$/.test(artifact.sha256 ?? '')) {
      failStructural(`attested artifact has invalid sha256: ${artifact.path}`, row);
      continue;
    }
    if (sha256(resolved.path) !== artifact.sha256) {
      failPromotion(`attested artifact hash mismatch: ${artifact.path}`, row);
    }
    if (!(policy.allowedArtifactRoots ?? []).some((root) => artifact.path === root || artifact.path.startsWith(`${root}/`))) {
      failStructural(`attested artifact is outside the policy roots: ${artifact.path}`, row);
    }
    artifactsByPath.set(artifact.path, artifact.sha256);
  }
  if (artifactPaths.size < policy.minArtifactCount) {
    failPromotion(`ready evidence has fewer than ${policy.minArtifactCount} policy artifacts`, row);
  }
  if (!artifactsByPath.size
      || ![...artifactsByPath.values()].includes(attestation.candidate?.productProofClosureSha256)) {
    failPromotion('ready evidence candidate product proof is not bound to an artifact', row);
  }

  const receipts = Array.isArray(attestation.validatorReceipts) ? attestation.validatorReceipts : [];
  const expectedReceiptCount = policy.requiredCheckIds.length * policy.requiredEnvironmentIds.length;
  if (receipts.length !== expectedReceiptCount) {
    failPromotion(`ready evidence must contain exactly ${expectedReceiptCount} validator receipts`, row);
  }
  const receiptPaths = new Set();
  const receiptPairs = new Set();
  const receiptArtifacts = new Map();
  const provenanceVerifier = options.provenanceVerifier ?? verifyGitHubArtifactProvenance;
  for (const receiptRef of receipts) {
    const fields = receiptRef && typeof receiptRef === 'object' && !Array.isArray(receiptRef)
      ? Object.keys(receiptRef).sort()
      : [];
    const expected = [
      'checkId', 'environmentId', 'path', 'sha256', 'candidate', 'subject', 'producer', 'provenance'
    ].sort();
    if (fields.length !== expected.length || fields.some((field, index) => field !== expected[index])) {
      failStructural('validator receipt reference fields are not canonical', row);
      continue;
    }
    if (receiptPaths.has(receiptRef.path)) {
      failStructural(`duplicate validator receipt path: ${receiptRef.path}`, row);
      continue;
    }
    receiptPaths.add(receiptRef.path);
    const pair = `${receiptRef.checkId}\u0000${receiptRef.environmentId}`;
    if (receiptPairs.has(pair)) {
      failStructural(`duplicate validator receipt pair: ${receiptRef.checkId}/${receiptRef.environmentId}`, row);
      continue;
    }
    receiptPairs.add(pair);
    if (!policy.requiredCheckIds.includes(receiptRef.checkId)
        || !policy.requiredEnvironmentIds.includes(receiptRef.environmentId)) {
      failPromotion(`validator receipt is outside the policy matrix: ${receiptRef.checkId}/${receiptRef.environmentId}`, row);
    }
    const resolved = resolveConfinedPath(options.repoRoot, receiptRef.path);
    if (resolved.error) {
      failStructural(`validator receipt ${resolved.error}: ${receiptRef.path}`, row);
      continue;
    }
    if (!resolved.exists) {
      failPromotion(`validator receipt does not exist: ${receiptRef.path}`, row);
      continue;
    }
    if (!fs.statSync(resolved.path).isFile()) {
      failStructural(`validator receipt must be a regular file: ${receiptRef.path}`, row);
      continue;
    }
    if (!/^[a-f0-9]{64}$/.test(receiptRef.sha256 ?? '')) {
      failStructural(`validator receipt has invalid sha256: ${receiptRef.path}`, row);
      continue;
    }
    if (sha256(resolved.path) !== receiptRef.sha256) {
      failPromotion(`validator receipt hash mismatch: ${receiptRef.path}`, row);
      continue;
    }
    let receipt;
    try {
      receipt = JSON.parse(fs.readFileSync(resolved.path, 'utf8'));
    } catch {
      failPromotion(`validator receipt is not valid JSON: ${receiptRef.path}`, row);
      continue;
    }
    const receiptFields = receipt && typeof receipt === 'object' && !Array.isArray(receipt)
      ? Object.keys(receipt).sort()
      : [];
    const expectedReceiptFields = [
      'schemaVersion', 'requirementId', 'checkId', 'environmentId', 'targetHead', 'status',
      'candidate', 'subject', 'producer', 'artifacts'
    ].sort();
    if (receiptFields.length !== expectedReceiptFields.length
        || receiptFields.some((field, index) => field !== expectedReceiptFields[index])) {
      failStructural(`validator receipt fields are not canonical: ${receiptRef.path}`, row);
      continue;
    }
    if (receipt.schemaVersion !== 2
        || receipt.requirementId !== row.requirementId
        || receipt.checkId !== receiptRef.checkId
        || receipt.environmentId !== receiptRef.environmentId
        || receipt.targetHead !== options.currentHead
        || receipt.status !== 'passed') {
      failPromotion(`validator receipt binding is invalid: ${receiptRef.path}`, row);
    }
    if (JSON.stringify(receipt.candidate) !== JSON.stringify(receiptRef.candidate)
        || JSON.stringify(receipt.candidate) !== JSON.stringify(attestation.candidate)) {
      failPromotion(`validator receipt candidate binding is invalid: ${receiptRef.path}`, row);
    }
    const subjectFields = receipt.subject && typeof receipt.subject === 'object' && !Array.isArray(receipt.subject)
      ? Object.keys(receipt.subject).sort()
      : [];
    const subjectRefFields = receiptRef.subject && typeof receiptRef.subject === 'object'
      && !Array.isArray(receiptRef.subject)
      ? Object.keys(receiptRef.subject).sort()
      : [];
    if (!sameStringArray(subjectFields, [...SUBJECT_FIELDS].sort())
        || !sameStringArray(subjectRefFields, [...SUBJECT_FIELDS].sort())
        || SUBJECT_FIELDS.some((field) => !/^[a-f0-9]{64}$/.test(receipt.subject?.[field] ?? ''))
        || SUBJECT_FIELDS.some((field) => receiptRef.subject?.[field] !== receipt.subject?.[field])) {
      failPromotion(`validator receipt subject binding is invalid: ${receiptRef.path}`, row);
    }
    const producerFields = receipt.producer && typeof receipt.producer === 'object' && !Array.isArray(receipt.producer)
      ? Object.keys(receipt.producer).sort()
      : [];
    const producerRefFields = receiptRef.producer && typeof receiptRef.producer === 'object'
      && !Array.isArray(receiptRef.producer)
      ? Object.keys(receiptRef.producer).sort()
      : [];
    const expectedProducer = policy.registeredProducer;
    if (!sameStringArray(producerFields, [...RECEIPT_PRODUCER_FIELDS].sort())
        || !sameStringArray(producerRefFields, [...RECEIPT_PRODUCER_FIELDS].sort())
        || receipt.producer?.id !== expectedProducer.id
        || receipt.producer?.version !== expectedProducer.version
        || receipt.producer?.command !== canonicalValidatorCommand(row.requirementId, receipt.checkId, receipt.environmentId)
        || receipt.producer?.sourceTree !== options.currentHead
        || receipt.producer?.repository !== expectedProducer.repository
        || receipt.producer?.workflow !== expectedProducer.signerWorkflow
        || !/^refs\/(heads|tags)\/[A-Za-z0-9._/-]+$/.test(receipt.producer?.sourceRef ?? '')
        || RECEIPT_PRODUCER_FIELDS.some((field) => receiptRef.producer?.[field] !== receipt.producer?.[field])) {
      failPromotion(`validator receipt producer binding is invalid: ${receiptRef.path}`, row);
    }
    const provenanceFields = receiptRef.provenance && typeof receiptRef.provenance === 'object'
      && !Array.isArray(receiptRef.provenance)
      ? Object.keys(receiptRef.provenance).sort()
      : [];
    if (!sameStringArray(provenanceFields, ['bundlePath', 'bundleSha256'])
        || receiptRef.provenance?.bundlePath !== `${receiptRef.path}.sigstore.jsonl`
        || !/^[a-f0-9]{64}$/.test(receiptRef.provenance?.bundleSha256 ?? '')) {
      failStructural(`validator receipt provenance reference is not canonical: ${receiptRef.path}`, row);
    } else {
      const bundle = resolveConfinedPath(options.repoRoot, receiptRef.provenance.bundlePath);
      if (bundle.error || !bundle.exists || !fs.statSync(bundle.path).isFile()) {
        failPromotion(`validator receipt provenance bundle is unavailable: ${receiptRef.provenance.bundlePath}`, row);
      } else if (sha256(bundle.path) !== receiptRef.provenance.bundleSha256) {
        failPromotion(`validator receipt provenance bundle hash mismatch: ${receiptRef.provenance.bundlePath}`, row);
      } else {
        try {
          const verification = provenanceVerifier({
            receiptPath: resolved.path,
            bundlePath: bundle.path,
            repository: expectedProducer.repository,
            signerWorkflow: expectedProducer.signerWorkflow,
            sourceDigest: options.currentHead,
            sourceRef: receipt.producer.sourceRef
          });
          if (verification?.receiptSha256 !== receiptRef.sha256 || verification?.verifiedAttestationCount < 1) {
            failPromotion(`validator receipt provenance does not bind exact bytes: ${receiptRef.path}`, row);
          }
        } catch (error) {
          failPromotion(`validator receipt provenance verification failed: ${receiptRef.path}: ${error.message}`, row);
        }
      }
    }
    if (!Array.isArray(receipt.artifacts) || receipt.artifacts.length === 0) {
      failPromotion(`validator receipt has no artifacts: ${receiptRef.path}`, row);
      continue;
    }
    const localPaths = new Set();
    const localDigests = new Set();
    for (const artifact of receipt.artifacts) {
      const fields = artifact && typeof artifact === 'object' && !Array.isArray(artifact)
        ? Object.keys(artifact).sort()
        : [];
      if (!sameStringArray(fields, ['path', 'sha256'])) {
        failStructural(`validator receipt artifact fields are not canonical: ${receiptRef.path}`, row);
        continue;
      }
      if (localPaths.has(artifact?.path)) {
        failStructural(`validator receipt duplicates artifact: ${artifact?.path ?? '<missing>'}`, row);
        continue;
      }
      localPaths.add(artifact?.path);
      localDigests.add(artifact?.sha256);
      if (artifactsByPath.get(artifact?.path) !== artifact?.sha256) {
        failPromotion(`validator receipt artifact differs from attestation: ${artifact?.path ?? '<missing>'}`, row);
      }
      receiptArtifacts.set(artifact?.path, artifact?.sha256);
    }
    for (const field of policy.requiredSubjectFields) {
      if (!localDigests.has(receipt.subject?.[field])) {
        failPromotion(`validator receipt subject.${field} is not bound to an artifact: ${receiptRef.path}`, row);
      }
    }
  }
  for (const checkId of policy.requiredCheckIds) {
    for (const environmentId of policy.requiredEnvironmentIds) {
      if (!receiptPairs.has(`${checkId}\u0000${environmentId}`)) {
        failPromotion(`validator receipt matrix is missing: ${checkId}/${environmentId}`, row);
      }
    }
  }
  if (receiptArtifacts.size !== artifactsByPath.size
      || [...artifactsByPath].some(([artifactPath, digest]) => receiptArtifacts.get(artifactPath) !== digest)) {
    failPromotion('validator receipt artifact union differs from the attestation', row);
  }
}

function validateEnvironmentAttestation(attestation, coverage, options, failPromotion, failStructural) {
  const actualFields = attestation && typeof attestation === 'object' && !Array.isArray(attestation)
    ? Object.keys(attestation).sort()
    : [];
  if (!sameStringArray(actualFields, [...ENVIRONMENT_ATTESTATION_FIELDS].sort())) {
    failStructural(`${coverage.id} environment evidence fields are not canonical.`);
  }
  if (attestation?.schemaVersion !== 1 || attestation?.environmentId !== coverage.id) {
    failPromotion(`environment evidence does not name ${coverage.id}.`);
  }
  if (attestation?.targetHead !== options.currentHead) {
    failPromotion(`minimum support environment ${coverage.id} evidence does not match current HEAD.`);
  }
  if (attestation?.status !== 'passed') {
    failPromotion(`minimum support environment ${coverage.id} attestation is not passed.`);
  }
  if (typeof attestation?.generatedAt !== 'string' || attestation.generatedAt.trim().length === 0) {
    failStructural(`${coverage.id} environment evidence generatedAt is required.`);
  }
  if (typeof attestation?.note !== 'string' || attestation.note.trim().length === 0) {
    failStructural(`${coverage.id} environment evidence note is required.`);
  }

  // The matrix harness records declared and detected identity separately. Bind both
  // to the canonical support row so a current-HEAD artifact from another desktop,
  // session, OS, or architecture cannot be promoted by changing only environmentId.
  const expectedEnvironment = options.requirements?.minimumSupportMatrix?.find(
    (environment) => environment.id === coverage.id
  );
  if (expectedEnvironment?.desktop && expectedEnvironment?.session && expectedEnvironment?.architecture) {
    const declared = attestation.declared;
    const declaredFields = declared && typeof declared === 'object' && !Array.isArray(declared)
      ? Object.keys(declared).sort()
      : [];
    if (!sameStringArray(declaredFields, [...ENVIRONMENT_DECLARED_FIELDS].sort())) {
      failStructural(`${coverage.id} declared environment fields are not canonical.`);
    } else {
      for (const field of ENVIRONMENT_DECLARED_FIELDS) {
        if (declared[field] !== expectedEnvironment[field]) {
          failPromotion(`${coverage.id} declared ${field} does not match the support matrix.`);
        }
      }
    }

    const detected = attestation.detected;
    if (detected === null || typeof detected !== 'object' || Array.isArray(detected)) {
      failPromotion(`${coverage.id} detected environment identity is missing.`);
    } else {
      if (detected.platform !== 'linux') {
        failPromotion(`${coverage.id} detected platform is not Linux.`);
      }
      if (normalizeEnvironmentArchitecture(detected.architecture) !== expectedEnvironment.architecture) {
        failPromotion(`${coverage.id} detected architecture does not match the support matrix.`);
      }
      if (normalizeEnvironmentSession(detected.session) !== normalizeEnvironmentSession(expectedEnvironment.session)) {
        failPromotion(`${coverage.id} detected session does not match the support matrix.`);
      }
      if (!environmentDesktopMatches(expectedEnvironment.desktop, detected.desktop)) {
        failPromotion(`${coverage.id} detected desktop does not match the support matrix.`);
      }
      if (!environmentOSMatches(expectedEnvironment.os, detected)) {
        failPromotion(`${coverage.id} detected OS does not match the support matrix.`);
      }
    }
  }

  const gitFields = attestation.git && typeof attestation.git === 'object' && !Array.isArray(attestation.git)
    ? Object.keys(attestation.git).sort()
    : [];
  if (!sameStringArray(gitFields, [...ENVIRONMENT_GIT_FIELDS].sort())) {
    failStructural(`${coverage.id} environment evidence git fields are not canonical.`);
  } else {
    if (attestation.git.commit !== options.currentHead) {
      failPromotion(`minimum support environment ${coverage.id} git commit does not match current HEAD.`);
    }
    if (attestation.git.dirty !== false
        || !Array.isArray(attestation.git.dirtyEntries)
        || attestation.git.dirtyEntries.length !== 0
        || attestation.git.gitAvailable !== true) {
      failPromotion(`minimum support environment ${coverage.id} git state is not a clean, available checkout.`);
    }
    for (const field of ['branch', 'remote']) {
      if (typeof attestation.git[field] !== 'string' || attestation.git[field].trim().length === 0) {
        failStructural(`${coverage.id} environment evidence git.${field} is required.`);
      }
    }
  }

  const evidenceInputs = attestation.evidenceInputs;
  const inputFields = evidenceInputs && typeof evidenceInputs === 'object' && !Array.isArray(evidenceInputs)
    ? Object.keys(evidenceInputs).sort()
    : [];
  if (!sameStringArray(inputFields, ['accessibilityEvidence', 'installedEvidence'].sort())) {
    failStructural(`${coverage.id} environment evidence inputs are not canonical.`);
  }
  const inputArtifacts = new Map();
  for (const inputName of ['installedEvidence', 'accessibilityEvidence']) {
    const input = evidenceInputs?.[inputName];
    const fields = input && typeof input === 'object' && !Array.isArray(input)
      ? Object.keys(input).sort()
      : [];
    if (!sameStringArray(fields, [...ENVIRONMENT_INPUT_FIELDS].sort())) {
      failStructural(`${coverage.id} ${inputName} fields are not canonical.`);
      continue;
    }
    const resolved = resolveConfinedPath(options.repoRoot, input.path);
    if (resolved.error) {
      failStructural(`${coverage.id} ${inputName} ${resolved.error}: ${input.path ?? '<missing>'}.`);
      continue;
    }
    if (!resolved.exists) {
      failPromotion(`${coverage.id} ${inputName} does not exist: ${input.path}.`);
      continue;
    }
    if (!fs.statSync(resolved.path).isFile()) {
      failStructural(`${coverage.id} ${inputName} must be a regular file: ${input.path}.`);
      continue;
    }
    if (!/^[a-f0-9]{64}$/u.test(input.sha256 ?? '')) {
      failStructural(`${coverage.id} ${inputName} has an invalid SHA-256 digest.`);
      continue;
    }
    if (sha256(resolved.path) !== input.sha256) {
      failPromotion(`${coverage.id} ${inputName} hash mismatch: ${input.path}.`);
    }
    if (input.passed !== true || input.commit !== options.currentHead) {
      failPromotion(`${coverage.id} ${inputName} is not a passed current-HEAD input.`);
    }
    inputArtifacts.set(input.path, input.sha256);
  }
  if (inputArtifacts.size !== 2) {
    failPromotion(`minimum support environment ${coverage.id} must bind two distinct matrix evidence inputs.`);
  }

  const checks = Array.isArray(attestation.checks) ? attestation.checks : [];
  if (checks.length === 0) {
    failPromotion(`minimum support environment ${coverage.id} has no matrix checks.`);
  }
  const checkIds = new Set();
  for (const check of checks) {
    const fields = check && typeof check === 'object' && !Array.isArray(check)
      ? Object.keys(check).sort()
      : [];
    if (!sameStringArray(fields, [...ENVIRONMENT_CHECK_FIELDS].sort())) {
      failStructural(`${coverage.id} environment check fields are not canonical.`);
      continue;
    }
    if (checkIds.has(check.id)) {
      failStructural(`${coverage.id} environment checks contain a duplicate id: ${check.id}.`);
    }
    checkIds.add(check.id);
    if (typeof check.id !== 'string' || check.id.trim().length === 0
        || typeof check.detail !== 'string' || check.detail.trim().length === 0) {
      failStructural(`${coverage.id} environment checks require id and detail.`);
    }
    if (check.passed !== true) {
      failPromotion(`minimum support environment ${coverage.id} has a failed matrix check: ${check.id}.`);
    }
  }
  const declaredEnvironment = options.requirements?.minimumSupportMatrix?.find(
    (environment) => environment.id === coverage.id
  );
  if (declaredEnvironment?.desktop && declaredEnvironment?.session && declaredEnvironment?.architecture) {
    const expectedCheckIds = [
      'os-linux',
      'checkout-clean',
      'session-bus',
      'display-server',
      'runtime-directory',
      'declared-os',
      'declared-architecture',
      'declared-session',
      'declared-desktop',
      declaredEnvironment.desktop === 'KDE Plasma' ? 'kwallet-query' : 'secret-tool',
      'installed-package-evidence',
      'installed-accessibility-evidence'
    ];
    if (!sameStringArray([...checkIds], expectedCheckIds)) {
      failStructural(`${coverage.id} environment checks do not match the canonical matrix harness.`);
    }
  }
  if (!Array.isArray(attestation.blocked)) {
    failStructural(`${coverage.id} environment blocked must be an array.`);
  } else if (attestation.blocked.length > 0) {
    failPromotion(`minimum support environment ${coverage.id} has blocked capabilities.`);
  }

  if (!Array.isArray(attestation?.artifacts) || attestation.artifacts.length === 0) {
    failPromotion(`minimum support environment ${coverage.id} has no attested artifacts.`);
    return;
  }
  const paths = new Set();
  for (const artifact of attestation.artifacts) {
    const fields = artifact && typeof artifact === 'object' && !Array.isArray(artifact)
      ? Object.keys(artifact).sort()
      : [];
    if (!sameStringArray(fields, ['path', 'sha256'])) {
      failStructural(`${coverage.id} attested artifact fields are not canonical.`);
      continue;
    }
    if (paths.has(artifact?.path)) {
      failStructural(`duplicate ${coverage.id} attested artifact path: ${artifact?.path ?? '<missing>'}.`);
      continue;
    }
    paths.add(artifact?.path);
    const resolved = resolveConfinedPath(options.repoRoot, artifact?.path);
    if (resolved.error) {
      failStructural(`${coverage.id} attested artifact ${resolved.error}: ${artifact?.path ?? '<missing>'}.`);
      continue;
    }
    if (!resolved.exists) {
      failPromotion(`${coverage.id} attested artifact does not exist: ${artifact.path}.`);
      continue;
    }
    if (!fs.statSync(resolved.path).isFile()) {
      failStructural(`${coverage.id} attested artifact must be a regular file: ${artifact.path}.`);
      continue;
    }
    if (!/^[a-f0-9]{64}$/.test(artifact.sha256 ?? '')) {
      failStructural(`${coverage.id} attested artifact has invalid sha256: ${artifact.path}.`);
    } else if (sha256(resolved.path) !== artifact.sha256) {
      failPromotion(`${coverage.id} attested artifact hash mismatch: ${artifact.path}.`);
    }
    if (inputArtifacts.get(artifact.path) !== artifact.sha256) {
      failPromotion(`${coverage.id} attested artifact is not bound to a passed evidence input: ${artifact.path}.`);
    }
  }
  if (paths.size !== inputArtifacts.size
      || [...inputArtifacts].some(([artifactPath, digest]) => !paths.has(artifactPath)
        || attestation.artifacts.find((artifact) => artifact.path === artifactPath)?.sha256 !== digest)) {
    failPromotion(`${coverage.id} attested artifact set does not match its passed evidence inputs.`);
  }
}

/**
 * @param {object} ledger
 * @param {{ allowBlocked?: boolean, currentHead: string, repoRoot: string, ledgerPath?: string, requirements?: object | null, requirementsDigest?: string | null, evidencePolicies?: object | null }} options
 */
export function validateParityLedger(ledger, options) {
  const structuralFailures = [];
  const promotionFailures = [];
  const warnings = [];
  const validatedAttestations = [];
  const productParityClaim = ledger.semantics?.productParityClaim === true;
  const requirements = options.requirements ?? null;

  const structural = (message, row = null) => {
    structuralFailures.push({ message, row: row?.id ?? null });
  };
  const promotion = (message, row = null) => {
    promotionFailures.push({ message, row: row?.id ?? null });
  };
  const warn = (message, row = null) => warnings.push({ message, row: row?.id ?? null });

  if (!HEAD_PATTERN.test(options.currentHead ?? '')) {
    structural('current HEAD must be a canonical 40-64 character lowercase git SHA.');
  }

  if (ledger.schemaVersion !== 2) structural('product parity ledger schemaVersion must be 2.');
  if (ledger.requirementsManifest !== 'docs/linux-port/product-parity-requirements.json') {
    structural('ledger must reference the canonical product parity requirements manifest.');
  }
  if (ledger.evidencePolicyManifest !== PRODUCT_EVIDENCE_POLICY_PATH) {
    structural('ledger must reference the canonical product parity evidence policy manifest.');
  }

  validateCanonicalAttester(options, structural);

  const ledgerPath = resolveConfinedPath(
    options.repoRoot,
    options.ledgerPath ?? 'docs/linux-port/parity-ledger.json'
  );
  if (ledgerPath.error) structural(`ledger path ${ledgerPath.error}.`);

  const requirementRows = Array.isArray(requirements?.requirements) ? requirements.requirements : [];
  const requirementIds = new Set();
  if (requirements === null) {
    structural('product parity requirements manifest was not loaded.');
  } else {
    if (options.requirementsDigest !== PRODUCT_REQUIREMENTS_SHA256) {
      structural('product parity requirements digest differs from the reviewed canonical contract.');
    }
    if (requirements.schemaVersion !== 1 || requirements.id !== PRODUCT_REQUIREMENTS_ID) {
      structural(`product parity requirements must use schemaVersion 1 and id ${PRODUCT_REQUIREMENTS_ID}.`);
    }
    if (!Array.isArray(requirements.requirements) || requirements.requirements.length === 0) {
      structural('product parity requirements manifest has no requirements.');
    }
    for (const requirement of requirementRows) {
      if (typeof requirement?.id !== 'string' || requirement.id.length === 0) {
        structural('product parity requirement is missing id.');
        continue;
      }
      if (requirementIds.has(requirement.id)) {
        structural(`duplicate product parity requirement id: ${requirement.id}`);
      }
      requirementIds.add(requirement.id);
      if (!/^P-[0-9]{2}$/.test(requirement.id)) {
        structural(`product parity requirement id is not canonical: ${requirement.id}`);
      }
      if (!['A', 'B'].includes(requirement.minimumEvidenceTier)) {
        structural(`product parity requirement ${requirement.id} has invalid minimumEvidenceTier.`);
      }
    }
  }

  const minimumSupportMatrix = Array.isArray(requirements?.minimumSupportMatrix)
    ? requirements.minimumSupportMatrix
    : [];
  if (requirements !== null && !Array.isArray(requirements.minimumSupportMatrix)) {
    structural('product parity minimumSupportMatrix must be an array.');
  }

  const evidencePoliciesByRequirement = validateEvidencePolicies(
    options.evidencePolicies ?? null,
    requirementRows,
    minimumSupportMatrix,
    options,
    structural
  );

  const rows = Array.isArray(ledger.rows) ? ledger.rows : [];
  if (rows.length === 0) structural('parity ledger has no rows.');
  const seenRowIds = new Set();
  const rowsByRequirement = new Map();

  for (const row of rows) {
    if (seenRowIds.has(row.id)) structural('duplicate row id', row);
    seenRowIds.add(row.id);
    for (const field of REQUIRED_ROW_FIELDS) {
      if (row[field] === undefined || row[field] === '') structural(`missing required field: ${field}`, row);
    }
    for (const field of FORBIDDEN_HEAD_FIELDS) {
      if (Object.hasOwn(row, field)) {
        structural(`${field} is forbidden in the tracked product ledger; HEAD binding belongs in generated evidence`, row);
      }
    }
    if (row.scope !== 'product-parity') structural('product ledger rows must use scope product-parity', row);
    if (row.id !== row.requirementId) structural('product ledger row id must equal requirementId', row);
    if (!requirementIds.has(row.requirementId)) {
      structural(`unknown product parity requirement id: ${row.requirementId ?? '<missing>'}`, row);
    }
    if (!['A', 'B'].includes(row.tier)) structural('product ledger tier must be A or B', row);
    if (!['ready', 'blocked'].includes(row.status)) structural('status must be ready or blocked', row);
    validateAcceptedDivergence(row.acceptedDivergence, structural, row);
    const expectedCommand = canonicalProductAttestationCommand(row.requirementId);
    if (row.command !== expectedCommand) {
      structural(`evidence command must be exactly: ${expectedCommand}`, row);
    }
    const expectedEvidencePath = `docs/linux-port/evidence/product-parity/${row.requirementId}.json`;
    if (row.evidencePath !== expectedEvidencePath) {
      structural(`evidence path must be exactly: ${expectedEvidencePath}`, row);
    }
    if (!evidencePoliciesByRequirement.has(row.requirementId)) {
      structural(`ledger row has no canonical evidence policy: ${row.requirementId}`, row);
    }

    const mapped = rowsByRequirement.get(row.requirementId) ?? [];
    mapped.push(row);
    rowsByRequirement.set(row.requirementId, mapped);

    const evidence = resolveConfinedPath(options.repoRoot, row.evidencePath);
    if (evidence.error) {
      structural(`evidence ${evidence.error}: ${row.evidencePath ?? '<missing>'}`, row);
      continue;
    }
    if (ledgerPath.path && evidence.path === ledgerPath.path) {
      structural('evidence path is the ledger itself (self-referential proof)', row);
    }
    if (!evidence.exists) {
      promotion('evidence path does not exist', row);
      if (row.status === 'blocked') warn('blocked row evidence has not been generated', row);
      continue;
    }
    if (!evidence.path.endsWith('.json')) {
      promotion('product evidence must be a generated JSON attestation', row);
      continue;
    }
    let attestation;
    try {
      attestation = JSON.parse(fs.readFileSync(evidence.path, 'utf8'));
    } catch {
      promotion('product evidence is not valid JSON', row);
      continue;
    }
    if (row.status === 'ready') {
      const structuralCount = structuralFailures.length;
      const promotionCount = promotionFailures.length;
      validateAttestation(
        attestation,
        row,
        evidencePoliciesByRequirement.get(row.requirementId),
        options,
        promotion,
        structural
      );
      if (structuralFailures.length === structuralCount && promotionFailures.length === promotionCount) {
        validatedAttestations.push({
          requirementId: row.requirementId,
          path: row.evidencePath,
          sha256: sha256(evidence.path),
          candidate: attestation.candidate
        });
      }
    }
  }

  if (validatedAttestations.length > 0) {
    const firstCandidate = JSON.stringify(validatedAttestations[0].candidate);
    if (validatedAttestations.some((entry) => JSON.stringify(entry.candidate) !== firstCandidate)) {
      promotion('validated product attestations mix different release candidates.');
    }
  }

  for (const requirement of requirementRows) {
    const candidates = rowsByRequirement.get(requirement.id) ?? [];
    if (candidates.length === 0) {
      structural(`required product capability ${requirement.id} has no ledger row.`);
      continue;
    }
    if (candidates.length > 1) {
      structural(`required product capability ${requirement.id} has ${candidates.length} ledger rows; expected exactly one.`);
      continue;
    }
    const row = candidates[0];
    const permittedTiers = requirement.minimumEvidenceTier === 'A' ? ['A'] : ['A', 'B'];
    if (!permittedTiers.includes(row.tier)) {
      structural(`required product capability ${requirement.id} does not meet Tier ${requirement.minimumEvidenceTier}.`, row);
    }
    if (row.status !== 'ready') promotion(`required product capability ${requirement.id} is blocked.`, row);
  }

  const requiredEnvironments = minimumSupportMatrix;
  const coverageRows = Array.isArray(ledger.environmentCoverage) ? ledger.environmentCoverage : [];
  const coverageById = new Map();
  for (const coverage of coverageRows) {
    if (coverageById.has(coverage.id)) structural(`duplicate environment coverage row: ${coverage.id}`);
    coverageById.set(coverage.id, coverage);
    for (const field of REQUIRED_ENVIRONMENT_COVERAGE_FIELDS) {
      if (coverage[field] === undefined || coverage[field] === '') {
        structural(`missing required environment coverage field: ${field}`, coverage);
      }
    }
    if (!requiredEnvironments.some((required) => required.id === coverage.id)) {
      structural(`unknown environment coverage row: ${coverage.id}`);
    }
    for (const field of FORBIDDEN_HEAD_FIELDS) {
      if (Object.hasOwn(coverage, field)) {
        structural(`${field} is forbidden in tracked environment coverage: ${coverage.id}`);
      }
    }
    if (!['ready', 'blocked'].includes(coverage.status)) {
      structural(`environment coverage ${coverage.id} status must be ready or blocked.`);
    }
    const expectedEnvironmentCommand = `node scripts/linux-port/run-linux-matrix-harness.mjs --environment ${coverage.id}`;
    if (coverage.command !== expectedEnvironmentCommand) {
      structural(`environment coverage command must be exactly: ${expectedEnvironmentCommand}`, coverage);
    }
    const expectedEnvironmentEvidencePath = `docs/linux-port/evidence/product-parity/environments/${coverage.id}.json`;
    if (coverage.evidencePath !== expectedEnvironmentEvidencePath) {
      structural(`environment coverage evidence path must be exactly: ${expectedEnvironmentEvidencePath}`, coverage);
    }
    const evidence = resolveConfinedPath(options.repoRoot, coverage.evidencePath);
    if (evidence.error) {
      structural(`environment coverage ${coverage.id} evidence ${evidence.error}.`);
    } else if (!evidence.exists) {
      promotion(`minimum support environment ${coverage.id} evidence path is missing.`);
    } else if (coverage.status === 'ready') {
      try {
        const attestation = JSON.parse(fs.readFileSync(evidence.path, 'utf8'));
        validateEnvironmentAttestation(attestation, coverage, options, promotion, structural);
      } catch {
        promotion(`minimum support environment ${coverage.id} evidence is not valid JSON.`);
      }
    }
    if (coverage.status !== 'ready') promotion(`minimum support environment ${coverage.id} is blocked.`);
  }
  for (const required of requiredEnvironments) {
    if (!coverageById.has(required.id)) {
      structural(`minimum support environment ${required.id} has no coverage row.`);
    }
  }

  if (!productParityClaim) promotion('product parity claim is false.');

  const structuralPassed = structuralFailures.length === 0;
  const promotionPassed = structuralPassed && promotionFailures.length === 0 && productParityClaim;
  if (productParityClaim && !promotionPassed) {
    structural('productParityClaim=true contradicts the incomplete or invalid evidence graph.');
  }
  const finalStructuralPassed = structuralFailures.length === 0;
  const failures = options.allowBlocked === true
    ? structuralFailures
    : [...structuralFailures, ...promotionFailures];

  return {
    passed: failures.length === 0,
    structuralPassed: finalStructuralPassed,
    promotionPassed: finalStructuralPassed && promotionFailures.length === 0 && productParityClaim,
    productParityClaim,
    failures,
    structuralFailures,
    promotionFailures,
    warnings,
    validatedAttestations
  };
}
