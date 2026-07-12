import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import Ajv2020 from 'ajv/dist/2020.js';
import { RELEASE_PROOF_ROLES } from '../prepare-product-requirement-input.mjs';
import {
  SUPPORT_ENVIRONMENTS,
  readRegularSnapshot,
  validateAggregateDocument,
  validateRecord
} from './product-proof-closure.mjs';
import {
  MAX_FEATURE_PROOF_ARTIFACT_BYTES,
  MAX_FEATURE_PROOF_CONTRACT_BYTES
} from './product-feature-proof.mjs';

export const PARITY_PREFLIGHT_SCHEMA_PATH = 'schemas/linux-parity-certification-preflight.schema.json';
export const PARITY_PREFLIGHT_ROLE = 'feature.parity-certification-preflight';
export const PARITY_PREFLIGHT_FILENAME = 'parity-certification-preflight.json';
export const REQUIREMENT_IDS = Object.freeze(
  Array.from({ length: 40 }, (_, index) => `P-${String(index + 1).padStart(2, '0')}`)
);

const REQUIREMENTS_PATH = 'docs/linux-port/product-parity-requirements.json';
const POLICIES_PATH = 'docs/linux-port/product-parity-evidence-policies.json';
const REGISTRY_PATH = 'docs/linux-port/product-feature-proof-registry.json';
const VALIDATOR_ROOT = 'scripts/linux-port/product-validators';
const FIXTURE_PATTERN = /\b(?:fixture|placeholder|stub|todo)\b/iu;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;
const HEAD = /^[a-f0-9]{40,64}$/u;

function parseJson(snapshot, label) {
  try {
    return JSON.parse(snapshot.bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function sourceRecord(snapshot) {
  return { path: snapshot.path, sha256: snapshot.sha256 };
}

function sameStringSet(actual, expected) {
  return Array.isArray(actual)
    && actual.length === expected.length
    && new Set(actual).size === expected.length
    && expected.every((entry) => actual.includes(entry));
}

function currentHead(repoRoot) {
  const result = spawnSync('git', ['rev-parse', '--verify', 'HEAD'], {
    cwd: repoRoot,
    encoding: 'utf8'
  });
  if (result.status !== 0) throw new Error(`git HEAD lookup failed: ${(result.stderr || result.stdout).trim()}`);
  return result.stdout.trim();
}

function validatorComponent(repoRoot, requirementId) {
  const validatorPath = `${VALIDATOR_ROOT}/${requirementId}.mjs`;
  const absolute = path.join(repoRoot, validatorPath);
  let stat;
  try {
    stat = fs.lstatSync(absolute);
  } catch (error) {
    if (error.code === 'ENOENT') return { status: 'missing', path: null, sha256: null };
    throw error;
  }
  if (!stat.isFile() || stat.isSymbolicLink()) {
    return { status: 'invalid', path: validatorPath, sha256: null };
  }
  let snapshot;
  try {
    snapshot = readRegularSnapshot(repoRoot, validatorPath, `${requirementId} validator`);
  } catch {
    return { status: 'invalid', path: validatorPath, sha256: null };
  }
  const bytes = snapshot.bytes;
  const sha256 = snapshot.sha256;
  const source = bytes.toString('utf8');
  if (!/export\s+async\s+function\s+validateProductRequirement\s*\(/u.test(source)) {
    return { status: 'invalid', path: validatorPath, sha256 };
  }
  if (FIXTURE_PATTERN.test(source)
      || !/validateRequirementContext\s*\(/u.test(source)
      || !/\bresult\s*\(/u.test(source)) {
    return { status: 'fixture', path: validatorPath, sha256 };
  }
  return { status: 'ready', path: validatorPath, sha256 };
}

function policyStatus(policy, requirementId, area) {
  if (!policy) return 'missing';
  const checkId = `${requirementId.toLowerCase()}.${area}`;
  const producer = policy.registeredProducer;
  const validatorPath = `${VALIDATOR_ROOT}/${requirementId}.mjs`;
  const expectedCommand = [
    'node scripts/linux-port/run-product-requirement-validator.mjs',
    `--requirement ${requirementId}`,
    '--environment {environment}',
    `--release-closure docs/linux-port/evidence/product-parity-inputs/${requirementId}/{environment}/release-closure.json`,
    `--output docs/linux-port/evidence/validator-receipts/${requirementId}/{checkId}/{environment}.json`
  ].join(' ');
  return policy.requirementId === requirementId
    && policy.requiredCheckIds?.length === 1
    && policy.requiredCheckIds[0] === checkId
    && sameStringSet(policy.requiredEnvironmentIds, SUPPORT_ENVIRONMENTS)
    && producer?.id === 'openburnbar-linux-product-validator'
    && producer.version === 1
    && producer.commandTemplate === expectedCommand
    && sameStringSet(producer.sourcePaths, [
      'scripts/linux-port/run-product-requirement-validator.mjs',
      validatorPath
    ])
    ? 'ready'
    : 'invalid';
}

function addBlocker(blockers, code, subject, detail) {
  blockers.push({ code, subject, detail });
}

function componentCode(prefix, status) {
  if (status === 'ready') return null;
  return `${status}-${prefix}`;
}

function reportSourcePath(inputRoot, repoRoot) {
  const absolute = path.join(inputRoot, 'feature-artifacts', PARITY_PREFLIGHT_FILENAME);
  return path.relative(repoRoot, absolute).split(path.sep).join('/');
}

export function buildParityCertificationPreflight({
  repoRoot,
  inputRoot,
  environmentId,
  targetHead,
  candidateRunId,
  candidateArtifactDigest
}) {
  const repository = fs.realpathSync(repoRoot);
  const root = fs.realpathSync(inputRoot);
  const proofPath = reportSourcePath(root, repository);
  if (!HEAD.test(targetHead ?? '') || !RUN_ID.test(String(candidateRunId ?? ''))
      || !DIGEST.test(candidateArtifactDigest ?? '')) {
    throw new Error('canonical target HEAD, candidate run ID, and artifact digest are required');
  }
  const requirementSnapshot = readRegularSnapshot(repository, REQUIREMENTS_PATH, 'parity requirements manifest');
  const policySnapshot = readRegularSnapshot(repository, POLICIES_PATH, 'parity evidence policy manifest');
  const registrySourceSnapshot = readRegularSnapshot(repository, REGISTRY_PATH, 'feature proof registry');
  const requirementsManifest = parseJson(requirementSnapshot, 'parity requirements manifest');
  const policyManifest = parseJson(policySnapshot, 'parity evidence policy manifest');
  const aggregateSnapshot = readRegularSnapshot(root, '.linux-release/product-proof-closure.json', 'aggregate product proof closure');
  const aggregate = validateAggregateDocument(parseJson(aggregateSnapshot, 'aggregate product proof closure'));
  const candidateRegistrySnapshot = validateRecord(
    path.dirname(aggregateSnapshot.absolute),
    aggregate.featureProofRegistry,
    'candidate feature proof registry'
  );
  const registry = parseJson(candidateRegistrySnapshot, 'candidate feature proof registry');
  const blockers = [];
  const observedHead = currentHead(repository);
  if (observedHead !== targetHead) {
    addBlocker(blockers, 'stale-target-head', 'candidate', `repository HEAD ${observedHead} does not match ${targetHead}`);
  }
  if (aggregate.targetHead !== targetHead || aggregate.sourceCommit !== targetHead) {
    addBlocker(blockers, 'stale-candidate', 'candidate', 'aggregate product proof closure is not bound to target HEAD');
  }
  if (candidateRegistrySnapshot.sha256 !== registrySourceSnapshot.sha256
      || !candidateRegistrySnapshot.bytes.equals(registrySourceSnapshot.bytes)) {
    addBlocker(blockers, 'stale-candidate-registry', 'candidate', 'candidate registry differs from the target source tree');
  }
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId)) {
    addBlocker(blockers, 'unsupported-environment', environmentId, 'environment is outside the canonical support matrix');
  }

  const observedRequirements = Array.isArray(requirementsManifest.requirements)
    ? requirementsManifest.requirements : [];
  const observedEnvironments = Array.isArray(requirementsManifest.minimumSupportMatrix)
    ? requirementsManifest.minimumSupportMatrix : [];
  const observedPolicies = Array.isArray(policyManifest.policies) ? policyManifest.policies : [];
  const observedContracts = Array.isArray(registry.requirements) ? registry.requirements : [];
  for (const row of observedRequirements) {
    if (!REQUIREMENT_IDS.includes(row?.id)) {
      addBlocker(blockers, 'unknown-requirement', String(row?.id ?? '<missing>'), 'requirements manifest contains an unknown row');
    }
  }
  for (const row of observedEnvironments) {
    if (!SUPPORT_ENVIRONMENTS.includes(row?.id)) {
      addBlocker(blockers, 'unknown-environment', String(row?.id ?? '<missing>'), 'requirements manifest contains an unknown environment');
    }
  }
  for (const policy of observedPolicies) {
    if (!REQUIREMENT_IDS.includes(policy?.requirementId)) {
      addBlocker(blockers, 'unknown-policy', String(policy?.requirementId ?? '<missing>'), 'policy manifest contains an unknown requirement');
    }
  }
  for (const contract of observedContracts) {
    if (!REQUIREMENT_IDS.includes(contract?.requirementId)) {
      addBlocker(blockers, 'unknown-capture', String(contract?.requirementId ?? '<missing>'), 'feature registry contains an unknown requirement');
    }
  }

  const environments = SUPPORT_ENVIRONMENTS.map((id) => {
    const presentCount = observedEnvironments.filter((row) => row?.id === id).length;
    const status = presentCount === 1 ? 'ready' : presentCount === 0 ? 'missing' : 'duplicate';
    if (status !== 'ready') addBlocker(blockers, `${status}-environment`, id, `environment occurs ${presentCount} times`);
    return { environmentId: id, presentCount, status };
  });

  const rows = REQUIREMENT_IDS.map((requirementId) => {
    const requirementRows = observedRequirements.filter((entry) => entry?.id === requirementId);
    const area = typeof requirementRows[0]?.area === 'string' && requirementRows[0].area.length > 0
      ? requirementRows[0].area : 'missing';
    const policyRows = observedPolicies.filter((entry) => entry?.requirementId === requirementId);
    const policyState = policyRows.length === 1
      ? policyStatus(policyRows[0], requirementId, area)
      : policyRows.length === 0 ? 'missing' : 'duplicate';
    const validator = validatorComponent(repository, requirementId);
    const validatorPath = `${VALIDATOR_ROOT}/${requirementId}.mjs`;
    const registeredValidatorCount = policyRows.length === 1
      && Array.isArray(policyRows[0]?.registeredProducer?.sourcePaths)
      ? policyRows[0].registeredProducer.sourcePaths.filter((sourcePath) => sourcePath === validatorPath).length
      : 0;
    if (validator.status === 'ready' && registeredValidatorCount > 1) validator.status = 'duplicate';
    const contracts = observedContracts.filter((entry) => entry?.requirementId === requirementId);
    const releaseRoles = RELEASE_PROOF_ROLES[requirementId] ? [...RELEASE_PROOF_ROLES[requirementId]].sort() : [];
    let capture;
    if (releaseRoles.length > 0) {
      capture = contracts.length === 0
        ? { status: 'ready', kind: 'release', roles: releaseRoles }
        : { status: 'duplicate', kind: 'release', roles: releaseRoles };
    } else if (contracts.length === 0) {
      capture = { status: 'missing', kind: 'none', roles: [] };
    } else if (contracts.length > 1) {
      capture = { status: 'duplicate', kind: 'feature', roles: [] };
    } else {
      const roles = Array.isArray(contracts[0].artifacts)
        ? contracts[0].artifacts.map((artifact) => artifact?.role).filter((role) => typeof role === 'string') : [];
      const unique = new Set(roles);
      const artifacts = Array.isArray(contracts[0].artifacts) ? contracts[0].artifacts : [];
      const totalBytes = artifacts.reduce((sum, artifact) => sum + (Number.isInteger(artifact?.maxBytes) ? artifact.maxBytes : 0), 0);
      const valid = roles.length > 0 && unique.size === roles.length
        && artifacts.every((artifact) =>
          /^feature\.[a-z0-9]+(?:[._-][a-z0-9]+)*$/u.test(artifact?.role ?? '')
          && /^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/u.test(artifact?.mediaType ?? '')
          && Number.isInteger(artifact?.maxBytes) && artifact.maxBytes > 0
          && artifact.maxBytes <= MAX_FEATURE_PROOF_ARTIFACT_BYTES
        )
        && totalBytes <= MAX_FEATURE_PROOF_CONTRACT_BYTES
        && (requirementId !== 'P-02' || (roles.length === 1 && roles[0] === PARITY_PREFLIGHT_ROLE));
      capture = { status: valid ? 'ready' : 'invalid', kind: 'feature', roles: [...roles].sort() };
    }
    const materializer = capture.status === 'ready'
      ? { status: 'ready', kind: capture.kind }
      : { status: 'unsupported', kind: 'none' };
    const rowBlockers = [];
    if (requirementRows.length !== 1) rowBlockers.push(requirementRows.length === 0 ? 'missing-requirement' : 'duplicate-requirement');
    if (policyState !== 'ready') rowBlockers.push(`${policyState}-policy`);
    const validatorCode = componentCode('validator', validator.status);
    if (validatorCode) rowBlockers.push(validatorCode);
    if (capture.status !== 'ready') rowBlockers.push(`${capture.status}-capture`);
    if (materializer.status !== 'ready') rowBlockers.push('unsupported-materializer');
    for (const code of rowBlockers) addBlocker(blockers, code, requirementId, `${requirementId} ${code.replaceAll('-', ' ')}`);
    return {
      requirementId,
      area,
      presentCount: requirementRows.length,
      policy: {
        status: policyState,
        presentCount: policyRows.length,
        requiredEnvironmentIds: Array.isArray(policyRows[0]?.requiredEnvironmentIds)
          ? policyRows[0].requiredEnvironmentIds : []
      },
      validator,
      capture,
      materializer,
      ready: rowBlockers.length === 0,
      blockers: rowBlockers.sort()
    };
  });

  const validatorHashes = new Map();
  const featureRoles = new Map();
  for (const row of rows) {
    if (row.validator.status === 'ready') {
      const owners = validatorHashes.get(row.validator.sha256) ?? [];
      owners.push(row);
      validatorHashes.set(row.validator.sha256, owners);
    }
    if (row.capture.status === 'ready' && row.capture.kind === 'feature') {
      for (const role of row.capture.roles) {
        const owners = featureRoles.get(role) ?? [];
        owners.push(row);
        featureRoles.set(role, owners);
      }
    }
  }
  for (const owners of validatorHashes.values()) {
    if (owners.length < 2) continue;
    for (const row of owners) {
      row.validator.status = 'reused';
      row.ready = false;
      row.blockers.push('reused-validator');
      addBlocker(blockers, 'reused-validator', row.requirementId, 'validator bytes are reused by another requirement');
    }
  }
  for (const owners of featureRoles.values()) {
    if (owners.length < 2) continue;
    for (const row of owners) {
      row.capture.status = 'reused';
      row.materializer = { status: 'unsupported', kind: 'none' };
      row.ready = false;
      row.blockers.push('reused-capture', 'unsupported-materializer');
      addBlocker(blockers, 'reused-capture', row.requirementId, 'feature capture role is reused by another requirement');
      addBlocker(blockers, 'unsupported-materializer', row.requirementId, 'reused capture cannot materialize parity evidence');
    }
  }

  const sources = {
    requirementsManifest: sourceRecord(requirementSnapshot),
    policyManifest: sourceRecord(policySnapshot),
    featureRegistry: sourceRecord(candidateRegistrySnapshot)
  };
  for (const source of Object.values(sources)) {
    if (source.path === proofPath) addBlocker(blockers, 'self-referential-proof', source.path, 'proof cites itself as an inventory source');
  }
  for (const row of rows) {
    if (row.validator.path === proofPath) {
      row.ready = false;
      row.blockers.push('self-referential-proof');
      addBlocker(blockers, 'self-referential-proof', row.requirementId, 'proof is used as its own validator source');
    }
    row.blockers = [...new Set(row.blockers)].sort();
  }
  blockers.sort((left, right) =>
    `${left.subject}:${left.code}:${left.detail}`.localeCompare(`${right.subject}:${right.code}:${right.detail}`)
  );
  const summary = {
    requirementCount: rows.filter((row) => row.presentCount === 1).length,
    policyCount: rows.filter((row) => row.policy.status === 'ready').length,
    environmentCount: environments.filter((row) => row.status === 'ready').length,
    validatorCount: rows.filter((row) => row.validator.status === 'ready').length,
    captureCount: rows.filter((row) => row.capture.status === 'ready').length,
    materializerCount: rows.filter((row) => row.materializer.status === 'ready').length,
    readyCount: rows.filter((row) => row.ready).length,
    blockerCount: blockers.length
  };
  return {
    schemaVersion: 1,
    targetHead,
    sourceCommit: observedHead,
    status: blockers.length === 0 ? 'passed' : 'blocked',
    requirementId: 'P-02',
    environmentId,
    proofPath,
    candidate: {
      runId: String(candidateRunId),
      artifactDigest: candidateArtifactDigest,
      productProofClosureSha256: aggregateSnapshot.sha256
    },
    sources,
    environments,
    requirements: rows,
    summary,
    blockers
  };
}

export function validateParityCertificationPreflightSchema(repoRoot, document) {
  const schema = parseJson(
    readRegularSnapshot(repoRoot, PARITY_PREFLIGHT_SCHEMA_PATH, 'parity preflight schema'),
    'parity preflight schema'
  );
  const validate = new Ajv2020({ allErrors: true, strict: true }).compile(schema);
  if (!validate(document)) {
    const detail = validate.errors?.map((error) => `${error.instancePath || '/'} ${error.message}`).join('; ');
    throw new Error(`parity certification preflight does not satisfy its schema: ${detail}`);
  }
}

export function validateParityCertificationPreflight(document, expected) {
  validateParityCertificationPreflightSchema(expected.repoRoot, document);
  const citedPaths = [
    ...Object.values(document.sources).map((source) => source.path),
    ...document.requirements.map((row) => row.validator.path).filter(Boolean)
  ];
  if (document.proofPath === expected.materializedProofPath || citedPaths.includes(document.proofPath)) {
    throw new Error('parity certification preflight proof is self-referential');
  }
  const rebuilt = buildParityCertificationPreflight({
    repoRoot: expected.repoRoot,
    inputRoot: path.dirname(path.dirname(path.join(expected.repoRoot, document.proofPath))),
    environmentId: expected.environmentId,
    targetHead: expected.targetHead,
    candidateRunId: expected.candidate.runId,
    candidateArtifactDigest: expected.candidate.artifactDigest
  });
  if (JSON.stringify(document) !== JSON.stringify(rebuilt)) {
    throw new Error('parity certification preflight is stale, substituted, or not bound to current inventory');
  }
  if (document.candidate.productProofClosureSha256 !== expected.candidate.productProofClosureSha256) {
    throw new Error('parity certification preflight is bound to a stale candidate aggregate');
  }
  return document;
}

export function parseParityCertificationPreflight(snapshot) {
  return parseJson(snapshot, 'parity certification preflight proof');
}
