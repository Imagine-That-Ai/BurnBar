import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
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
import {
  validatePolicyManifest,
  validateRequirementsManifest
} from './product-requirement-attestation.mjs';

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
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;
const HEAD = /^[a-f0-9]{40,64}$/u;
const COMMIT_SNAPSHOT_CACHE = new Map();

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

function currentHead(repoRoot) {
  const result = spawnSync('git', ['rev-parse', '--verify', 'HEAD'], {
    cwd: repoRoot,
    encoding: 'utf8'
  });
  if (result.status !== 0) throw new Error(`git HEAD lookup failed: ${(result.stderr || result.stdout).trim()}`);
  return result.stdout.trim();
}

function commitSnapshot(repoRoot, targetHead, relativePath, label, optional = false) {
  const cacheKey = `${repoRoot}\0${targetHead}\0${relativePath}`;
  if (COMMIT_SNAPSHOT_CACHE.has(cacheKey)) return COMMIT_SNAPSHOT_CACHE.get(cacheKey);
  const tree = spawnSync('git', ['ls-tree', '-z', targetHead, '--', relativePath], {
    cwd: repoRoot,
    encoding: 'buffer'
  });
  if (tree.status !== 0) throw new Error(`git tree lookup failed for ${label}`);
  if (tree.stdout.length === 0) {
    if (optional) {
      COMMIT_SNAPSHOT_CACHE.set(cacheKey, null);
      return null;
    }
    throw new Error(`${label} is missing from target commit ${targetHead}`);
  }
  const entry = tree.stdout.toString('utf8').replace(/\0$/u, '');
  const match = /^(100644|100755) blob [a-f0-9]+\t(.+)$/u.exec(entry);
  if (!match || match[2] !== relativePath) {
    if (optional) return null;
    throw new Error(`${label} must be a regular target-commit blob`);
  }
  const shown = spawnSync('git', ['show', `${targetHead}:${relativePath}`], {
    cwd: repoRoot,
    encoding: 'buffer',
    maxBuffer: 64 * 1024 * 1024
  });
  if (shown.status !== 0) throw new Error(`git blob read failed for ${label}`);
  const snapshot = {
    path: relativePath,
    bytes: shown.stdout,
    sha256: cryptoHash(shown.stdout),
    size: shown.stdout.length
  };
  if (COMMIT_SNAPSHOT_CACHE.size > 4096) COMMIT_SNAPSHOT_CACHE.clear();
  COMMIT_SNAPSHOT_CACHE.set(cacheKey, snapshot);
  return snapshot;
}

function cryptoHash(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
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

function certificationRows(registry) {
  return Array.isArray(registry.certification) ? registry.certification : [];
}

function executionKey(testPath, testName) {
  return `${testPath}\0${testName}`;
}

function ownershipExecutions(registry) {
  const entries = new Map();
  for (const ownership of certificationRows(registry)) {
    for (const component of ['validator', 'capture', 'materializer']) {
      const value = ownership?.[component];
      const testName = component === 'validator' ? value?.mutationTestName : value?.testName;
      if (typeof value?.testPath !== 'string' || typeof testName !== 'string') continue;
      entries.set(executionKey(value.testPath, testName), {
        testPath: value.testPath,
        testName
      });
    }
  }
  return [...entries.values()].sort((left, right) =>
    executionKey(left.testPath, left.testName).localeCompare(executionKey(right.testPath, right.testName))
  );
}

function validateExecutionInventory(registry, testExecutions, blockers) {
  const expected = new Set(ownershipExecutions(registry).map((entry) =>
    executionKey(entry.testPath, entry.testName)
  ));
  const counts = new Map();
  for (const entry of testExecutions) {
    const key = executionKey(entry?.testPath, entry?.testName);
    counts.set(key, (counts.get(key) ?? 0) + 1);
    if (!expected.has(key)) {
      addBlocker(blockers, 'unexpected-test-execution', entry?.testPath ?? '<missing>',
        'test execution is not owned by the candidate registry');
    }
  }
  for (const entry of ownershipExecutions(registry)) {
    const count = counts.get(executionKey(entry.testPath, entry.testName)) ?? 0;
    if (count !== 1) {
      addBlocker(blockers, count === 0 ? 'missing-test-execution' : 'duplicate-test-execution',
        entry.testPath, `${entry.testName} occurs ${count} times`);
    }
  }
}

function requireTargetWorktree(repoRoot, targetHead) {
  if (currentHead(repoRoot) !== targetHead) throw new Error('test execution requires the exact target HEAD');
  for (const args of [['diff', '--quiet', targetHead, '--'], ['diff', '--cached', '--quiet', targetHead, '--']]) {
    const result = spawnSync('git', args, { cwd: repoRoot });
    if (result.status !== 0) throw new Error('test execution requires target-controlled tracked bytes');
  }
}

export function collectCertificationTestExecutions(repoRoot, targetHead) {
  const repository = fs.realpathSync(repoRoot);
  requireTargetWorktree(repository, targetHead);
  const registrySnapshot = commitSnapshot(repository, targetHead, REGISTRY_PATH, 'feature proof registry');
  const registry = parseJson(registrySnapshot, 'feature proof registry');
  const executions = [];
  const byPath = Map.groupBy(ownershipExecutions(registry), (entry) => entry.testPath);
  const childEnvironment = { ...process.env, OPENBURNBAR_PARITY_PREFLIGHT_OWNERSHIP_TEST: '1' };
  delete childEnvironment.NODE_TEST_CONTEXT;
  for (const [testPath, entries] of byPath) {
    const testSnapshot = commitSnapshot(repository, targetHead, testPath, `${testPath} ownership test`);
    const result = spawnSync(process.execPath, ['--test', testPath], {
      cwd: repository,
      encoding: 'utf8',
      maxBuffer: 16 * 1024 * 1024,
      env: childEnvironment
    });
    const output = `${result.stdout ?? ''}${result.stderr ?? ''}`;
    for (const entry of entries) {
      const escapedName = entry.testName.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
      const namedTestPassed = new RegExp(`^ok [0-9]+ - ${escapedName}$`, 'mu').test(output);
      const passed = result.status === 0 && namedTestPassed && /# fail 0/u.test(output);
      executions.push({
        testPath,
        testName: entry.testName,
        testSha256: testSnapshot.sha256,
        status: passed ? 'passed' : 'failed',
        exitCode: Number.isInteger(result.status) ? result.status : 1,
        outputSha256: cryptoHash(Buffer.from(output))
      });
    }
  }
  return executions.sort((left, right) =>
    executionKey(left.testPath, left.testName).localeCompare(executionKey(right.testPath, right.testName))
  );
}

function ownedSource(repoRoot, targetHead, relativePath, label) {
  if (typeof relativePath !== 'string') return null;
  return commitSnapshot(repoRoot, targetHead, relativePath, label, true);
}

function executionReady(testExecutions, targetHead, testPath, testName, testSnapshot) {
  if (!testSnapshot) return false;
  const rows = testExecutions.filter((entry) =>
    entry?.testPath === testPath && entry?.testName === testName
  );
  return rows.length === 1
    && rows[0].status === 'passed'
    && rows[0].exitCode === 0
    && rows[0].testSha256 === testSnapshot.sha256
    && HEAD.test(targetHead);
}

function componentOwnershipStatus({
  repoRoot, targetHead, ownership, component, testExecutions, expectedProducerPath
}) {
  if (!ownership || typeof ownership !== 'object') {
    return {
      status: 'missing', producerPath: null, workflowPath: null, testPath: null, testName: null
    };
  }
  const producer = ownedSource(repoRoot, targetHead, ownership.producerPath, `${component} producer`);
  const workflow = ownedSource(repoRoot, targetHead, ownership.workflowPath, `${component} workflow`);
  const test = ownedSource(repoRoot, targetHead, ownership.testPath, `${component} test`);
  const workflowSource = workflow?.bytes.toString('utf8') ?? '';
  const wired = producer && workflow && test
    && ownership.producerPath === expectedProducerPath
    && workflowSource.includes(path.posix.basename(ownership.producerPath))
    && executionReady(testExecutions, targetHead, ownership.testPath, ownership.testName, test);
  return {
    status: wired ? 'ready' : 'invalid',
    producerPath: ownership.producerPath ?? null,
    workflowPath: ownership.workflowPath ?? null,
    testPath: ownership.testPath ?? null,
    testName: ownership.testName ?? null
  };
}

export function buildParityCertificationPreflight({
  repoRoot,
  inputRoot,
  environmentId,
  targetHead,
  candidateRunId,
  candidateArtifactDigest,
  testExecutions = []
}) {
  const repository = fs.realpathSync(repoRoot);
  const root = fs.realpathSync(inputRoot);
  const proofPath = reportSourcePath(root, repository);
  if (!HEAD.test(targetHead ?? '') || !RUN_ID.test(String(candidateRunId ?? ''))
      || !DIGEST.test(candidateArtifactDigest ?? '')) {
    throw new Error('canonical target HEAD, candidate run ID, and artifact digest are required');
  }
  const requirementSnapshot = commitSnapshot(repository, targetHead, REQUIREMENTS_PATH, 'parity requirements manifest');
  const policySnapshot = commitSnapshot(repository, targetHead, POLICIES_PATH, 'parity evidence policy manifest');
  const registrySourceSnapshot = commitSnapshot(repository, targetHead, REGISTRY_PATH, 'feature proof registry');
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
  const observedOwnership = certificationRows(registry);
  validateExecutionInventory(registry, testExecutions, blockers);
  let canonicalRequirements = null;
  let canonicalPolicies = false;
  try {
    canonicalRequirements = validateRequirementsManifest(requirementsManifest);
  } catch (error) {
    addBlocker(blockers, 'invalid-requirements-manifest', 'inventory', error.message);
  }
  if (canonicalRequirements) {
    try {
      validatePolicyManifest(policyManifest, canonicalRequirements);
      canonicalPolicies = true;
    } catch (error) {
      addBlocker(blockers, 'invalid-policy-manifest', 'inventory', error.message);
    }
  }
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
  for (const ownership of observedOwnership) {
    if (!REQUIREMENT_IDS.includes(ownership?.requirementId)) {
      addBlocker(blockers, 'unknown-ownership', String(ownership?.requirementId ?? '<missing>'), 'certification registry contains an unknown requirement');
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
      ? canonicalPolicies ? 'ready' : 'invalid'
      : policyRows.length === 0 ? 'missing' : 'duplicate';
    const validatorPath = `${VALIDATOR_ROOT}/${requirementId}.mjs`;
    const ownershipRows = observedOwnership.filter((entry) => entry?.requirementId === requirementId);
    const ownership = ownershipRows.length === 1 ? ownershipRows[0] : null;
    const validatorSnapshot = ownedSource(repository, targetHead, validatorPath, `${requirementId} validator`);
    const validatorTest = ownedSource(
      repository, targetHead, ownership?.validator?.testPath, `${requirementId} validator mutation test`
    );
    const validatorOwned = ownership
      && ownership.validator?.sourcePath === validatorPath
      && validatorSnapshot
      && validatorTest
      && executionReady(
        testExecutions,
        targetHead,
        ownership.validator.testPath,
        ownership.validator.mutationTestName,
        validatorTest
      );
    const validator = {
      status: ownershipRows.length > 1 ? 'duplicate'
        : !validatorSnapshot || ownershipRows.length === 0 ? 'missing'
          : validatorOwned ? 'ready' : 'invalid',
      path: validatorSnapshot ? validatorPath : null,
      sha256: validatorSnapshot?.sha256 ?? null,
      testPath: ownership?.validator?.testPath ?? null,
      testName: ownership?.validator?.mutationTestName ?? null,
      testSha256: validatorTest?.sha256 ?? null
    };
    const contracts = observedContracts.filter((entry) => entry?.requirementId === requirementId);
    const releaseRoles = RELEASE_PROOF_ROLES[requirementId] ? [...RELEASE_PROOF_ROLES[requirementId]].sort() : [];
    let capture;
    const captureOwner = ownershipRows.length === 1
      ? componentOwnershipStatus({
        repoRoot: repository,
        targetHead,
        ownership: ownership.capture,
        component: `${requirementId} capture`,
        testExecutions,
        expectedProducerPath: releaseRoles.length > 0
          ? 'scripts/linux-port/finalize-product-proof-closure.mjs'
          : requirementId === 'P-02'
            ? 'scripts/linux-port/capture-parity-certification-preflight.mjs'
            : ownership.capture?.producerPath
      })
      : {
        status: ownershipRows.length > 1 ? 'duplicate' : 'missing',
        producerPath: null,
        workflowPath: null,
        testPath: null,
        testName: null
      };
    if (releaseRoles.length > 0) {
      capture = {
        ...captureOwner,
        status: contracts.length > 0 ? 'duplicate' : captureOwner.status,
        kind: 'release',
        roles: releaseRoles
      };
    } else if (contracts.length === 0) {
      capture = { ...captureOwner, status: 'missing', kind: 'none', roles: [] };
    } else if (contracts.length > 1) {
      capture = { ...captureOwner, status: 'duplicate', kind: 'feature', roles: [] };
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
      capture = {
        ...captureOwner,
        status: valid && captureOwner.status === 'ready' ? 'ready' : 'invalid',
        kind: 'feature',
        roles: [...roles].sort()
      };
    }
    const materializerOwner = ownershipRows.length === 1
      ? componentOwnershipStatus({
        repoRoot: repository,
        targetHead,
        ownership: ownership.materializer,
        component: `${requirementId} materializer`,
        testExecutions,
        expectedProducerPath: ownership.materializer?.producerPath
      })
      : { status: 'invalid', producerPath: null, workflowPath: null, testPath: null, testName: null };
    const materializer = capture.status === 'ready' && materializerOwner.status === 'ready'
      ? { ...materializerOwner, kind: capture.kind }
      : { ...materializerOwner, status: 'unsupported', kind: 'none' };
    let rowBlockers = [];
    if (requirementRows.length !== 1) rowBlockers.push(requirementRows.length === 0 ? 'missing-requirement' : 'duplicate-requirement');
    if (policyState !== 'ready') rowBlockers.push(`${policyState}-policy`);
    const validatorCode = componentCode('validator', validator.status);
    if (validatorCode) rowBlockers.push(validatorCode);
    if (capture.status !== 'ready') rowBlockers.push(`${capture.status}-capture`);
    if (materializer.status !== 'ready') rowBlockers.push('unsupported-materializer');
    rowBlockers = [...new Set(rowBlockers)];
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
      row.materializer = {
        ...row.materializer,
        status: 'unsupported',
        kind: 'none'
      };
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
    sourceCommit: targetHead,
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
    testExecutions,
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
    candidateArtifactDigest: expected.candidate.artifactDigest,
    testExecutions: document.testExecutions
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
