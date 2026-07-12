import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { verifyGitHubArtifactProvenance } from './github-artifact-provenance.mjs';

export const REQUIREMENTS_PATH = 'docs/linux-port/product-parity-requirements.json';
export const POLICIES_PATH = 'docs/linux-port/product-parity-evidence-policies.json';
export const LEDGER_PATH = 'docs/linux-port/parity-ledger.json';
export const POLICY_MANIFEST_ID = 'openburnbar-linux-product-parity-evidence-policies-v1';
export const REQUIREMENTS_MANIFEST_SHA256 = '1ea8f51cd0a38fc73f616230398ccf87815a065485f6f6b53d5cb55a83e53a62';
export const CANONICAL_REQUIREMENT_IDS = Array.from(
  { length: 40 },
  (_, index) => `P-${String(index + 1).padStart(2, '0')}`
);
export const CANONICAL_ENVIRONMENT_IDS = [
  'ubuntu-24.04-gnome-x11-x86_64',
  'ubuntu-24.04-gnome-x11-aarch64',
  'ubuntu-24.04-gnome-wayland-x86_64',
  'ubuntu-24.04-gnome-wayland-aarch64',
  'fedora-kde-wayland-x86_64',
  'fedora-kde-wayland-aarch64',
  'arch-sway-wayland-x86_64'
];

const RECEIPT_FIELDS = [
  'schemaVersion',
  'requirementId',
  'checkId',
  'environmentId',
  'targetHead',
  'status',
  'candidate',
  'subject',
  'producer',
  'artifacts'
];
const ARTIFACT_FIELDS = ['path', 'sha256'];
const CANDIDATE_FIELDS = ['runId', 'artifactDigest', 'productProofClosureSha256'];
const SUBJECT_FIELDS = [
  'releaseClosureSha256',
  'packageManifestSha256',
  'installedEnvironmentSha256',
  'runtimeManifestSha256'
];
const PRODUCER_FIELDS = [
  'id',
  'version',
  'command',
  'sourceTree',
  'repository',
  'workflow',
  'sourceRef'
];
const REGISTERED_PRODUCER_FIELDS = [
  'id',
  'version',
  'commandTemplate',
  'sourcePaths',
  'repository',
  'signerWorkflow'
];
const POLICY_FIELDS = [
  'requirementId',
  'policyVersion',
  'requiredCheckIds',
  'requiredEnvironmentIds',
  'allowedArtifactRoots',
  'minArtifactCount',
  'registeredProducer',
  'requiredSubjectFields'
];
const MANIFEST_FIELDS = ['schemaVersion', 'id', 'requirementsManifest', 'policies'];
const SHA256_PATTERN = /^[a-f0-9]{64}$/u;
const HEAD_PATTERN = /^[a-f0-9]{40,64}$/u;
const REQUIREMENT_PATTERN = /^P-[0-9]{2}$/u;
const CANONICAL_ID_PATTERN = /^[a-z0-9]+(?:[._-][a-z0-9]+)*$/u;
const REPOSITORY = 'Imagine-That-Ai/BurnBar';
const SIGNER_WORKFLOW = 'github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-product-parity.yml';
const EVIDENCE_UNTRACKED_ROOTS = [
  'docs/linux-port/evidence/validator-receipts',
  'docs/linux-port/evidence/product-parity-inputs',
  'docs/linux-port/evidence/product-parity'
];

function assertExactKeys(value, keys, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    throw new Error(`${label} fields must be exactly: ${expected.join(', ')}`);
  }
}

function assertUniqueStrings(values, label, pattern = null) {
  if (!Array.isArray(values) || values.length === 0) throw new Error(`${label} must be a nonempty array`);
  const seen = new Set();
  for (const value of values) {
    if (typeof value !== 'string' || value.length === 0 || value.trim() !== value) {
      throw new Error(`${label} contains an invalid string`);
    }
    if (pattern && !pattern.test(value)) throw new Error(`${label} contains a non-canonical id: ${value}`);
    if (seen.has(value)) throw new Error(`${label} contains a duplicate: ${value}`);
    seen.add(value);
  }
}

function isInside(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function assertCanonicalRelativePath(relativePath, label) {
  if (typeof relativePath !== 'string' || relativePath.length === 0 || relativePath.trim() !== relativePath) {
    throw new Error(`${label} must be a nonempty repository-relative path`);
  }
  if (relativePath.includes('\\') || path.posix.isAbsolute(relativePath)) {
    throw new Error(`${label} must be a canonical repository-relative POSIX path: ${relativePath}`);
  }
  const normalized = path.posix.normalize(relativePath);
  if (normalized !== relativePath || normalized === '.' || normalized === '..' || normalized.startsWith('../')) {
    throw new Error(`${label} escapes the repository or is not canonical: ${relativePath}`);
  }
  return normalized;
}

function assertNoSymlinkComponents(repoRoot, absolutePath, label, allowMissingLeaf = false) {
  const relative = path.relative(repoRoot, absolutePath);
  if (!isInside(repoRoot, absolutePath)) throw new Error(`${label} escapes the repository`);
  let current = repoRoot;
  for (const component of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    if (!fs.existsSync(current)) {
      if (allowMissingLeaf) return;
      throw new Error(`${label} does not exist: ${path.relative(repoRoot, current)}`);
    }
    if (fs.lstatSync(current).isSymbolicLink()) throw new Error(`${label} traverses a symlink: ${path.relative(repoRoot, current)}`);
  }
}

export function resolveRepositoryFile(repoRoot, relativePath, label) {
  const canonical = assertCanonicalRelativePath(relativePath, label);
  const absolute = path.resolve(repoRoot, canonical);
  assertNoSymlinkComponents(repoRoot, absolute, label);
  const stat = fs.statSync(absolute);
  if (!stat.isFile()) throw new Error(`${label} must be a regular file: ${canonical}`);
  const realRoot = fs.realpathSync(repoRoot);
  const realFile = fs.realpathSync(absolute);
  if (!isInside(realRoot, realFile)) throw new Error(`${label} escapes the repository through a symlink: ${canonical}`);
  return { path: canonical, absolute: realFile };
}

function sha256File(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function readRepositoryBytes(repoRoot, relativePath, label) {
  const resolved = resolveRepositoryFile(repoRoot, relativePath, label);
  const noFollow = fs.constants.O_NOFOLLOW ?? 0;
  const handle = fs.openSync(resolved.absolute, fs.constants.O_RDONLY | noFollow);
  try {
    const stat = fs.fstatSync(handle);
    if (!stat.isFile()) throw new Error(`${label} must be a regular file: ${resolved.path}`);
    const bytes = fs.readFileSync(handle);
    return {
      ...resolved,
      bytes,
      sha256: crypto.createHash('sha256').update(bytes).digest('hex')
    };
  } finally {
    fs.closeSync(handle);
  }
}

function readJsonFile(repoRoot, relativePath, label) {
  const resolved = readRepositoryBytes(repoRoot, relativePath, label);
  let value;
  try {
    value = JSON.parse(resolved.bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
  return { ...resolved, value };
}

function runGit(repoRoot, args) {
  const result = spawnSync('git', args, { cwd: repoRoot, encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error(`git ${args.join(' ')} failed: ${(result.stderr || result.stdout || 'unknown error').trim()}`);
  }
  return result.stdout.trim();
}

export function requireCleanGitHead(repoRoot, allowedUntrackedRoots = []) {
  const topLevel = fs.realpathSync(runGit(repoRoot, ['rev-parse', '--show-toplevel']));
  if (topLevel !== fs.realpathSync(repoRoot)) throw new Error('repository root does not match the real git top level');
  const targetHead = runGit(repoRoot, ['rev-parse', '--verify', 'HEAD']);
  if (!HEAD_PATTERN.test(targetHead)) throw new Error(`git HEAD is not a canonical commit id: ${targetHead}`);
  const tracked = spawnSync('git', ['diff', '--quiet', 'HEAD', '--'], { cwd: repoRoot, encoding: 'utf8' });
  if (tracked.status !== 0) {
    throw new Error('git tracked worktree and index must be clean before attestation generation');
  }
  const allowed = allowedUntrackedRoots.map((entry) => assertCanonicalRelativePath(entry, 'allowed untracked root'));
  const untracked = runGit(repoRoot, ['ls-files', '--others', '--exclude-standard', '-z'])
    .split('\0')
    .filter(Boolean);
  const unexpected = untracked.filter((entry) => !allowed.some((root) => entry === root || entry.startsWith(`${root}/`)));
  if (unexpected.length > 0) {
    throw new Error(`git worktree has unexpected untracked files:\n${unexpected.join('\n')}`);
  }
  return targetHead;
}

export function validateRequirementsManifest(value) {
  if (value?.schemaVersion !== 1 || value?.id !== 'openburnbar-linux-macos-parity-v1') {
    throw new Error('requirements manifest has the wrong schemaVersion or id');
  }
  if (!Array.isArray(value.requirements) || value.requirements.length !== 40) {
    throw new Error('requirements manifest must contain exactly 40 requirements');
  }
  assertUniqueStrings(value.requirements.map((entry) => entry?.id), 'requirement ids', REQUIREMENT_PATTERN);
  assertUniqueStrings(value.minimumSupportMatrix?.map((entry) => entry?.id), 'environment ids', CANONICAL_ID_PATTERN);
  const requirementIds = value.requirements.map((entry) => entry.id);
  const environmentIds = value.minimumSupportMatrix.map((entry) => entry.id);
  if (requirementIds.some((id, index) => id !== CANONICAL_REQUIREMENT_IDS[index])) {
    throw new Error('requirements manifest ids must be exactly P-01 through P-40 in order');
  }
  if (environmentIds.length !== CANONICAL_ENVIRONMENT_IDS.length
      || environmentIds.some((id, index) => id !== CANONICAL_ENVIRONMENT_IDS[index])) {
    throw new Error('requirements manifest environments must equal the canonical minimum support matrix');
  }
  const areasByRequirement = new Map();
  for (const requirement of value.requirements) {
    if (typeof requirement.area !== 'string' || !CANONICAL_ID_PATTERN.test(requirement.area)) {
      throw new Error(`requirement ${requirement.id} has a non-canonical area id`);
    }
    areasByRequirement.set(requirement.id, requirement.area);
  }
  return {
    requirementIds,
    environmentIds,
    areasByRequirement
  };
}

export function canonicalValidatorReceiptPath(requirementId, checkId, environmentId) {
  return `docs/linux-port/evidence/validator-receipts/${requirementId}/${checkId}/${environmentId}.json`;
}

export function canonicalValidatorReleaseClosurePath(requirementId, environmentId) {
  return `docs/linux-port/evidence/product-parity-inputs/${requirementId}/${environmentId}/release-closure.json`;
}

export function canonicalValidatorCommand(requirementId, checkId, environmentId) {
  const receipt = `docs/linux-port/evidence/validator-receipts/${requirementId}/${checkId}/${environmentId}.json`;
  return [
    'node scripts/linux-port/run-product-requirement-validator.mjs',
    `--requirement ${requirementId}`,
    `--environment ${environmentId}`,
    `--release-closure ${canonicalValidatorReleaseClosurePath(requirementId, environmentId)}`,
    `--output ${receipt}`
  ].join(' ');
}

function canonicalValidatorCommandTemplate(requirementId) {
  return canonicalValidatorCommand(requirementId, '{checkId}', '{environment}');
}

export function validatePolicyManifest(value, requirements) {
  assertExactKeys(value, MANIFEST_FIELDS, 'policy manifest');
  if (value.schemaVersion !== 1 || value.id !== POLICY_MANIFEST_ID || value.requirementsManifest !== REQUIREMENTS_PATH) {
    throw new Error('policy manifest has the wrong schemaVersion, id, or requirementsManifest');
  }
  if (!Array.isArray(value.policies) || value.policies.length !== requirements.requirementIds.length) {
    throw new Error('policy manifest must have exactly one policy per requirement');
  }
  const canonicalRequirements = new Set(requirements.requirementIds);
  const canonicalEnvironments = new Set(requirements.environmentIds);
  const seen = new Set();
  for (const policy of value.policies) {
    assertExactKeys(policy, POLICY_FIELDS, `policy ${policy?.requirementId ?? '<unknown>'}`);
    if (!REQUIREMENT_PATTERN.test(policy.requirementId ?? '') || !canonicalRequirements.has(policy.requirementId)) {
      throw new Error(`policy has unknown or non-canonical requirementId: ${policy.requirementId ?? '<missing>'}`);
    }
    if (seen.has(policy.requirementId)) throw new Error(`duplicate policy for ${policy.requirementId}`);
    seen.add(policy.requirementId);
    if (!Number.isInteger(policy.policyVersion) || policy.policyVersion < 1) {
      throw new Error(`policyVersion must be a positive integer for ${policy.requirementId}`);
    }
    assertUniqueStrings(policy.requiredCheckIds, `${policy.requirementId} requiredCheckIds`, CANONICAL_ID_PATTERN);
    assertUniqueStrings(policy.requiredEnvironmentIds, `${policy.requirementId} requiredEnvironmentIds`, CANONICAL_ID_PATTERN);
    for (const environmentId of policy.requiredEnvironmentIds) {
      if (!canonicalEnvironments.has(environmentId)) throw new Error(`${policy.requirementId} has unknown environment: ${environmentId}`);
    }
    const expectedCheckId = `${policy.requirementId.toLowerCase()}.${requirements.areasByRequirement.get(policy.requirementId)}`;
    if (policy.requiredCheckIds.length !== 1 || policy.requiredCheckIds[0] !== expectedCheckId) {
      throw new Error(`${policy.requirementId} requiredCheckIds must be exactly ${expectedCheckId}`);
    }
    if (
      policy.requiredEnvironmentIds.length !== requirements.environmentIds.length ||
      policy.requiredEnvironmentIds.some((id, index) => id !== requirements.environmentIds[index])
    ) {
      throw new Error(`${policy.requirementId} requiredEnvironmentIds must equal the canonical minimum support matrix`);
    }
    assertUniqueStrings(policy.allowedArtifactRoots, `${policy.requirementId} allowedArtifactRoots`);
    for (const root of policy.allowedArtifactRoots) assertCanonicalRelativePath(root, `${policy.requirementId} artifact root`);
    const expectedRoot = `docs/linux-port/evidence/product-parity-inputs/${policy.requirementId}`;
    if (policy.allowedArtifactRoots.length !== 1 || policy.allowedArtifactRoots[0] !== expectedRoot) {
      throw new Error(`${policy.requirementId} allowedArtifactRoots must be exactly ${expectedRoot}`);
    }
    if (!Number.isInteger(policy.minArtifactCount) || policy.minArtifactCount < 1) {
      throw new Error(`minArtifactCount must be a positive integer for ${policy.requirementId}`);
    }
    assertExactKeys(policy.registeredProducer, REGISTERED_PRODUCER_FIELDS, `${policy.requirementId} registeredProducer`);
    const producer = policy.registeredProducer;
    if (producer.id !== 'openburnbar-linux-product-validator'
        || producer.version !== 1
        || producer.commandTemplate !== canonicalValidatorCommandTemplate(policy.requirementId)
        || producer.repository !== REPOSITORY
        || producer.signerWorkflow !== SIGNER_WORKFLOW) {
      throw new Error(`${policy.requirementId} registeredProducer does not match the canonical validator contract`);
    }
    const expectedSourcePaths = [
      'scripts/linux-port/run-product-requirement-validator.mjs',
      `scripts/linux-port/product-validators/${policy.requirementId}.mjs`
    ];
    if (!Array.isArray(producer.sourcePaths)
        || producer.sourcePaths.length !== expectedSourcePaths.length
        || producer.sourcePaths.some((sourcePath, index) => sourcePath !== expectedSourcePaths[index])) {
      throw new Error(`${policy.requirementId} registeredProducer sourcePaths are not canonical`);
    }
    if (!Array.isArray(policy.requiredSubjectFields)
        || policy.requiredSubjectFields.length !== SUBJECT_FIELDS.length
        || policy.requiredSubjectFields.some((field, index) => field !== SUBJECT_FIELDS[index])) {
      throw new Error(`${policy.requirementId} requiredSubjectFields must bind the complete installed release subject`);
    }
  }
  for (const id of canonicalRequirements) if (!seen.has(id)) throw new Error(`missing policy for ${id}`);
  return value;
}

function validateLedgerRow(ledger, requirementId) {
  if (
    ledger?.schemaVersion !== 2 ||
    ledger?.requirementsManifest !== REQUIREMENTS_PATH ||
    ledger?.evidencePolicyManifest !== POLICIES_PATH ||
    !Array.isArray(ledger.rows)
  ) {
    throw new Error('product parity ledger has the wrong schema, requirements manifest, or evidence policy manifest');
  }
  const rows = ledger.rows.filter((row) => row?.requirementId === requirementId);
  if (rows.length !== 1 || rows[0].id !== requirementId) {
    throw new Error(`ledger must contain exactly one canonical row for ${requirementId}`);
  }
  const expected = `docs/linux-port/evidence/product-parity/${requirementId}.json`;
  if (rows[0].evidencePath !== expected) throw new Error(`${requirementId} ledger evidencePath must be exactly ${expected}`);
  const expectedCommand = `node scripts/linux-port/attest-product-requirement.mjs --requirement ${requirementId}`;
  if (rows[0].command !== expectedCommand) throw new Error(`${requirementId} ledger command must be exactly ${expectedCommand}`);
  return rows[0];
}

function artifactIsAllowed(artifactPath, roots) {
  return roots.some((root) => artifactPath === root || artifactPath.startsWith(`${root}/`));
}

function validateArtifactRecord(record, context, repoRoot, policy) {
  assertExactKeys(record, ARTIFACT_FIELDS, `${context} artifact`);
  const resolved = readRepositoryBytes(repoRoot, record.path, `${context} artifact`);
  if (!artifactIsAllowed(resolved.path, policy.allowedArtifactRoots)) {
    throw new Error(`${context} artifact is outside allowedArtifactRoots: ${resolved.path}`);
  }
  if (!SHA256_PATTERN.test(record.sha256 ?? '')) throw new Error(`${context} artifact has invalid sha256: ${resolved.path}`);
  const actual = resolved.sha256;
  if (actual !== record.sha256) throw new Error(`${context} artifact hash mismatch: ${resolved.path}`);
  return { path: resolved.path, sha256: actual };
}

function validateReceipt(receiptInput, repoRoot, requirementId, targetHead, policy, provenanceVerifier) {
  const source = readJsonFile(repoRoot, receiptInput, `validator receipt ${receiptInput}`);
  const receipt = source.value;
  assertExactKeys(receipt, RECEIPT_FIELDS, `validator receipt ${source.path}`);
  if (receipt.schemaVersion !== 2) throw new Error(`validator receipt ${source.path} schemaVersion must be 2`);
  if (receipt.requirementId !== requirementId) throw new Error(`validator receipt ${source.path} names the wrong requirement`);
  if (!policy.requiredCheckIds.includes(receipt.checkId)) throw new Error(`validator receipt ${source.path} has unknown checkId: ${receipt.checkId}`);
  if (!policy.requiredEnvironmentIds.includes(receipt.environmentId)) {
    throw new Error(`validator receipt ${source.path} has wrong environmentId: ${receipt.environmentId}`);
  }
  if (receipt.targetHead !== targetHead) throw new Error(`validator receipt ${source.path} does not match current HEAD`);
  if (receipt.status !== 'passed') throw new Error(`validator receipt ${source.path} status must be passed`);
  assertExactKeys(receipt.candidate, CANDIDATE_FIELDS, `validator receipt ${source.path} candidate`);
  if (!/^[1-9][0-9]*$/u.test(receipt.candidate.runId ?? '')
      || !/^sha256:[a-f0-9]{64}$/u.test(receipt.candidate.artifactDigest ?? '')
      || !SHA256_PATTERN.test(receipt.candidate.productProofClosureSha256 ?? '')) {
    throw new Error(`validator receipt ${source.path} candidate binding is invalid`);
  }
  assertExactKeys(receipt.subject, SUBJECT_FIELDS, `validator receipt ${source.path} subject`);
  for (const field of policy.requiredSubjectFields) {
    if (!SHA256_PATTERN.test(receipt.subject[field] ?? '')) {
      throw new Error(`validator receipt ${source.path} subject.${field} must be a SHA-256 digest`);
    }
  }
  assertExactKeys(receipt.producer, PRODUCER_FIELDS, `validator receipt ${source.path} producer`);
  const expectedCommand = canonicalValidatorCommand(requirementId, receipt.checkId, receipt.environmentId);
  if (receipt.producer.id !== policy.registeredProducer.id
      || receipt.producer.version !== policy.registeredProducer.version
      || receipt.producer.command !== expectedCommand
      || receipt.producer.sourceTree !== targetHead
      || receipt.producer.repository !== policy.registeredProducer.repository
      || receipt.producer.workflow !== policy.registeredProducer.signerWorkflow
      || !/^refs\/(heads|tags)\/[A-Za-z0-9._/-]+$/u.test(receipt.producer.sourceRef ?? '')) {
    throw new Error(`validator receipt ${source.path} producer binding is invalid`);
  }
  if (!Array.isArray(receipt.artifacts) || receipt.artifacts.length === 0) {
    throw new Error(`validator receipt ${source.path} must attest at least one artifact`);
  }
  const artifacts = [];
  const seen = new Set();
  for (const record of receipt.artifacts) {
    const artifact = validateArtifactRecord(record, `validator receipt ${source.path}`, repoRoot, policy);
    if (seen.has(artifact.path)) throw new Error(`validator receipt ${source.path} duplicates artifact: ${artifact.path}`);
    seen.add(artifact.path);
    artifacts.push(artifact);
  }
  const artifactDigests = new Set(artifacts.map((artifact) => artifact.sha256));
  if (!artifactDigests.has(receipt.candidate.productProofClosureSha256)) {
    throw new Error(`validator receipt ${source.path} candidate product proof is not bound to an artifact`);
  }
  for (const field of policy.requiredSubjectFields) {
    if (!artifactDigests.has(receipt.subject[field])) {
      throw new Error(`validator receipt ${source.path} subject.${field} is not bound to an artifact`);
    }
  }
  const bundleInput = `${source.path}.sigstore.jsonl`;
  const bundle = readRepositoryBytes(repoRoot, bundleInput, `validator receipt provenance ${bundleInput}`);
  const provenance = provenanceVerifier({
    receiptPath: source.absolute,
    bundlePath: bundle.absolute,
    repository: policy.registeredProducer.repository,
    signerWorkflow: policy.registeredProducer.signerWorkflow,
    sourceDigest: targetHead,
    sourceRef: receipt.producer.sourceRef
  });
  if (provenance?.receiptSha256 !== source.sha256 || provenance?.verifiedAttestationCount < 1) {
    throw new Error(`validator receipt ${source.path} provenance did not verify the exact receipt bytes`);
  }
  return {
    path: source.path,
    sha256: source.sha256,
    checkId: receipt.checkId,
    environmentId: receipt.environmentId,
    candidate: receipt.candidate,
    subject: receipt.subject,
    producer: receipt.producer,
    provenance: {
      bundlePath: bundle.path,
      bundleSha256: bundle.sha256
    },
    artifacts: artifacts.sort((left, right) => left.path.localeCompare(right.path))
  };
}

function ensureOutputParent(repoRoot, outputRelative) {
  const output = path.resolve(repoRoot, assertCanonicalRelativePath(outputRelative, 'output path'));
  if (!isInside(repoRoot, output)) throw new Error('output path escapes the repository');
  const parent = path.dirname(output);
  assertNoSymlinkComponents(repoRoot, parent, 'output directory', true);
  fs.mkdirSync(parent, { recursive: true });
  assertNoSymlinkComponents(repoRoot, parent, 'output directory');
  return output;
}

export function removeStaleProductRequirementOutput(repoRoot, requirementId) {
  if (!REQUIREMENT_PATTERN.test(requirementId ?? '')) return;
  const relative = `docs/linux-port/evidence/product-parity/${requirementId}.json`;
  const absolute = path.resolve(repoRoot, relative);
  try {
    assertNoSymlinkComponents(repoRoot, path.dirname(absolute), 'output directory', true);
    if (fs.existsSync(absolute)) {
      fs.rmSync(absolute, { force: true });
    } else {
      // existsSync follows links, so a broken stale output symlink needs an lstat check.
      try {
        if (fs.lstatSync(absolute).isSymbolicLink()) fs.unlinkSync(absolute);
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
    }
  } catch (error) {
    throw new Error(`failed to remove stale output ${relative}: ${error.message}`);
  }
}

function atomicWriteJson(repoRoot, outputRelative, value) {
  const output = ensureOutputParent(repoRoot, outputRelative);
  const temporary = `${output}.tmp-${process.pid}-${crypto.randomBytes(8).toString('hex')}`;
  try {
    const handle = fs.openSync(temporary, 'wx', 0o600);
    try {
      fs.writeFileSync(handle, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
      fs.fsyncSync(handle);
    } finally {
      fs.closeSync(handle);
    }
    fs.renameSync(temporary, output);
    const directory = fs.openSync(path.dirname(output), 'r');
    try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

/**
 * Generate a fail-closed product requirement attestation.
 * @param {{repoRoot:string, requirementId:string, validatorReceiptPaths?:string[], artifactPaths?:string[]}} options
 */
export function attestProductRequirement(options) {
  const { repoRoot, requirementId } = options;
  removeStaleProductRequirementOutput(repoRoot, requirementId);
  try {
    if (!REQUIREMENT_PATTERN.test(requirementId ?? '')) throw new Error(`invalid requirement id: ${requirementId ?? '<missing>'}`);
    const providedReceiptPaths = options.validatorReceiptPaths ?? [];
    const providedArtifactPaths = options.artifactPaths ?? [];
    if (providedReceiptPaths.length > 0) assertUniqueStrings(providedReceiptPaths, 'validator receipt paths');
    if (providedArtifactPaths.length > 0) assertUniqueStrings(providedArtifactPaths, 'explicit artifact paths');

    const requirementsFile = readJsonFile(repoRoot, REQUIREMENTS_PATH, 'requirements manifest');
    if (requirementsFile.sha256 !== REQUIREMENTS_MANIFEST_SHA256) {
      throw new Error('requirements manifest digest differs from the reviewed canonical contract');
    }
    const requirements = validateRequirementsManifest(requirementsFile.value);
    if (!requirements.requirementIds.includes(requirementId)) throw new Error(`unknown requirement id: ${requirementId}`);
    const policyFile = readJsonFile(repoRoot, POLICIES_PATH, 'policy manifest');
    const policyManifest = validatePolicyManifest(policyFile.value, requirements);
    const policy = policyManifest.policies.find((entry) => entry.requirementId === requirementId);
    const ledger = readJsonFile(repoRoot, LEDGER_PATH, 'product parity ledger').value;
    const row = validateLedgerRow(ledger, requirementId);
    const expectedOutput = `docs/linux-port/evidence/product-parity/${requirementId}.json`;
    if (row.evidencePath !== expectedOutput) throw new Error('ledger output path does not match canonical output path');

    const targetHead = requireCleanGitHead(repoRoot, EVIDENCE_UNTRACKED_ROOTS);
    const provenanceVerifier = options.provenanceVerifier ?? verifyGitHubArtifactProvenance;
    const canonicalReceiptPaths = policy.requiredCheckIds.flatMap((checkId) =>
      policy.requiredEnvironmentIds.map((environmentId) =>
        canonicalValidatorReceiptPath(requirementId, checkId, environmentId)
      )
    );
    const receiptPaths = providedReceiptPaths.length > 0 ? providedReceiptPaths : canonicalReceiptPaths;
    if (receiptPaths.length !== canonicalReceiptPaths.length
        || [...receiptPaths].sort().some((receiptPath, index) => receiptPath !== [...canonicalReceiptPaths].sort()[index])) {
      throw new Error('validator receipt paths must match the canonical policy matrix paths exactly');
    }
    const receipts = receiptPaths.map((receiptPath) =>
      validateReceipt(receiptPath, repoRoot, requirementId, targetHead, policy, provenanceVerifier)
    );
    const receiptPathSet = new Set(receipts.map((receipt) => receipt.path));
    if (receiptPathSet.size !== receipts.length) throw new Error('duplicate validator receipt path');

    const expectedPairs = new Set();
    for (const checkId of policy.requiredCheckIds) {
      for (const environmentId of policy.requiredEnvironmentIds) expectedPairs.add(`${checkId}\u0000${environmentId}`);
    }
    const actualPairs = new Set();
    const candidate = receipts[0]?.candidate;
    for (const receipt of receipts) {
      const key = `${receipt.checkId}\u0000${receipt.environmentId}`;
      if (actualPairs.has(key)) throw new Error(`duplicate validator receipt for ${receipt.checkId}/${receipt.environmentId}`);
      actualPairs.add(key);
      if (JSON.stringify(receipt.candidate) !== JSON.stringify(candidate)) {
        throw new Error('validator receipt matrix mixes different release candidates');
      }
    }
    const missing = [...expectedPairs].filter((key) => !actualPairs.has(key));
    const extra = [...actualPairs].filter((key) => !expectedPairs.has(key));
    if (missing.length > 0 || extra.length > 0) {
      const display = (key) => key.replace('\u0000', '/');
      throw new Error(`validator receipt matrix mismatch; missing=[${missing.map(display).join(', ')}] extra=[${extra.map(display).join(', ')}]`);
    }

    const artifactsByPath = new Map();
    for (const receipt of receipts) {
      for (const artifact of receipt.artifacts) {
        const prior = artifactsByPath.get(artifact.path);
        if (prior && prior.sha256 !== artifact.sha256) throw new Error(`conflicting artifact hashes for ${artifact.path}`);
        artifactsByPath.set(artifact.path, artifact);
      }
    }
    const artifactPaths = providedArtifactPaths.length > 0
      ? providedArtifactPaths
      : [...artifactsByPath.keys()];
    const explicitArtifacts = artifactPaths.map((artifactPath) => {
      const resolved = readRepositoryBytes(repoRoot, artifactPath, `explicit artifact ${artifactPath}`);
      if (!artifactIsAllowed(resolved.path, policy.allowedArtifactRoots)) {
        throw new Error(`explicit artifact is outside allowedArtifactRoots: ${resolved.path}`);
      }
      return { path: resolved.path, sha256: resolved.sha256 };
    });
    const explicitSet = new Set(explicitArtifacts.map((artifact) => artifact.path));
    if (explicitSet.size !== explicitArtifacts.length) throw new Error('duplicate explicit artifact path');
    const receiptSet = new Set(artifactsByPath.keys());
    const missingArtifacts = [...receiptSet].filter((item) => !explicitSet.has(item));
    const extraArtifacts = [...explicitSet].filter((item) => !receiptSet.has(item));
    if (missingArtifacts.length > 0 || extraArtifacts.length > 0) {
      throw new Error(`explicit artifact set does not match receipt artifacts; missing=[${missingArtifacts.join(', ')}] extra=[${extraArtifacts.join(', ')}]`);
    }
    for (const artifact of explicitArtifacts) {
      if (artifactsByPath.get(artifact.path)?.sha256 !== artifact.sha256) throw new Error(`explicit artifact hash mismatch: ${artifact.path}`);
    }
    if (explicitArtifacts.length < policy.minArtifactCount) {
      throw new Error(`${requirementId} requires at least ${policy.minArtifactCount} distinct artifacts`);
    }

    const attestation = {
      schemaVersion: 1,
      rowId: row.id,
      requirementId,
      targetHead,
      status: 'passed',
      candidate,
      policy: {
        manifest: POLICIES_PATH,
        manifestId: policyManifest.id,
        policyVersion: policy.policyVersion
      },
      checks: [...policy.requiredCheckIds],
      environments: [...policy.requiredEnvironmentIds],
      validatorReceipts: receipts
        .map(({ artifacts: _artifacts, ...receipt }) => receipt)
        .sort((left, right) => left.checkId.localeCompare(right.checkId) || left.environmentId.localeCompare(right.environmentId)),
      artifacts: explicitArtifacts.sort((left, right) => left.path.localeCompare(right.path))
    };
    requireCleanGitHead(repoRoot, EVIDENCE_UNTRACKED_ROOTS);
    for (const artifact of explicitArtifacts) {
      const reread = readRepositoryBytes(repoRoot, artifact.path, `final artifact ${artifact.path}`);
      if (reread.sha256 !== artifact.sha256) throw new Error(`artifact changed before attestation write: ${artifact.path}`);
    }
    for (const receipt of receipts) {
      const reread = readRepositoryBytes(repoRoot, receipt.path, `final validator receipt ${receipt.path}`);
      if (reread.sha256 !== receipt.sha256) throw new Error(`validator receipt changed before attestation write: ${receipt.path}`);
      const bundle = readRepositoryBytes(repoRoot, receipt.provenance.bundlePath, `final validator provenance ${receipt.path}`);
      if (bundle.sha256 !== receipt.provenance.bundleSha256) {
        throw new Error(`validator receipt provenance changed before attestation write: ${receipt.provenance.bundlePath}`);
      }
    }
    atomicWriteJson(repoRoot, expectedOutput, attestation);
    return { attestation, outputPath: expectedOutput };
  } catch (error) {
    removeStaleProductRequirementOutput(repoRoot, requirementId);
    throw error;
  }
}
