import fs from 'node:fs';
import path from 'node:path';
import Ajv2020 from 'ajv/dist/2020.js';
import {
  atomicWriteBytes,
  atomicWriteJson,
  readRegularSnapshot,
  validateAggregateDocument,
  validateRecord
} from './product-proof-closure.mjs';

export const FEATURE_PROOF_REGISTRY_PATH = 'docs/linux-port/product-feature-proof-registry.json';
export const FEATURE_PROOF_REGISTRY_SCHEMA_PATH = 'schemas/linux-product-feature-proof-registry.schema.json';
export const FEATURE_PROOF_REGISTRATION_SCHEMA_PATH = 'schemas/linux-product-feature-proof-registration.schema.json';
export const FEATURE_PROOF_CLOSURE_SCHEMA_PATH = 'schemas/linux-product-feature-proof-closure.schema.json';
export const FEATURE_PROOF_REGISTRATION_PATH = 'feature-proof-registration.json';
export const FEATURE_PROOF_CLOSURE_PATH = 'feature-proof-closure.json';
export const RELEASE_ONLY_REQUIREMENTS = Object.freeze(['P-01', 'P-03', 'P-04', 'P-37']);

const CANDIDATE_DIGEST = /^sha256:[a-f0-9]{64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;

function parseJson(snapshot, label) {
  try {
    return JSON.parse(snapshot.bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function validateSchema(repoRoot, schemaPath, document, label) {
  const schemaSnapshot = readRegularSnapshot(repoRoot, schemaPath, `${label} schema`);
  const schema = parseJson(schemaSnapshot, `${label} schema`);
  const validate = new Ajv2020({ allErrors: true, strict: true }).compile(schema);
  if (!validate(document)) {
    const detail = validate.errors?.map((error) => `${error.instancePath || '/'} ${error.message}`).join('; ');
    throw new Error(`${label} does not satisfy its canonical schema: ${detail ?? 'unknown error'}`);
  }
}

function requireInside(root, candidate, label) {
  const relative = path.relative(root, candidate);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} must be inside ${root}`);
  }
}

function repositoryRelative(repoRoot, file) {
  const relative = path.relative(repoRoot, file);
  requireInside(repoRoot, file, 'feature proof subject');
  return relative.split(path.sep).join('/');
}

function recordFromSnapshot(repoRoot, snapshot) {
  return {
    path: repositoryRelative(repoRoot, snapshot.absolute),
    sha256: snapshot.sha256,
    size: snapshot.size
  };
}

export function validateFeatureProofRegistry(repoRoot, snapshot) {
  const document = parseJson(snapshot, 'product feature proof registry');
  validateSchema(repoRoot, FEATURE_PROOF_REGISTRY_SCHEMA_PATH, document, 'product feature proof registry');
  const requirements = parseJson(
    readRegularSnapshot(repoRoot, 'docs/linux-port/product-parity-requirements.json', 'product parity requirements'),
    'product parity requirements'
  );
  const canonicalRequirementIds = Array.from(
    { length: 40 },
    (_, index) => `P-${String(index + 1).padStart(2, '0')}`
  );
  const requirementIds = (requirements.requirements ?? []).map((entry) => entry?.id);
  if (requirementIds.length !== canonicalRequirementIds.length
      || requirementIds.some((id, index) => id !== canonicalRequirementIds[index])) {
    throw new Error('product parity requirements must contain exactly P-01 through P-40 in order');
  }
  const canonicalIds = new Set(canonicalRequirementIds);
  const seenRequirements = new Set();
  let previousRequirement = '';
  for (const contract of document.requirements) {
    if (!canonicalIds.has(contract.requirementId)) {
      throw new Error(`feature proof registry contains unknown requirement ${contract.requirementId}`);
    }
    if (RELEASE_ONLY_REQUIREMENTS.includes(contract.requirementId)) {
      throw new Error(`${contract.requirementId} is release-owned and may not register feature proofs`);
    }
    if (seenRequirements.has(contract.requirementId)) {
      throw new Error(`feature proof registry repeats requirement ${contract.requirementId}`);
    }
    if (previousRequirement && contract.requirementId.localeCompare(previousRequirement) <= 0) {
      throw new Error('feature proof registry requirements must be sorted by requirementId');
    }
    previousRequirement = contract.requirementId;
    seenRequirements.add(contract.requirementId);
    const seenRoles = new Set();
    let previousRole = '';
    for (const artifact of contract.artifacts) {
      if (seenRoles.has(artifact.role)) {
        throw new Error(`${contract.requirementId} repeats feature proof role ${artifact.role}`);
      }
      if (previousRole && artifact.role.localeCompare(previousRole) <= 0) {
        throw new Error(`${contract.requirementId} feature proof roles must be sorted`);
      }
      previousRole = artifact.role;
      seenRoles.add(artifact.role);
    }
  }
  return { document, contracts: new Map(document.requirements.map((entry) => [entry.requirementId, entry])) };
}

export function snapshotFeatureProofRegistry(repoRoot, outputDir) {
  const source = readRegularSnapshot(repoRoot, FEATURE_PROOF_REGISTRY_PATH, 'product feature proof registry');
  validateFeatureProofRegistry(repoRoot, source);
  const destination = path.join(outputDir, 'sidecars/product-feature-proof-registry.json');
  atomicWriteBytes(destination, source.bytes);
  return readRegularSnapshot(outputDir, 'sidecars/product-feature-proof-registry.json', 'snapshotted product feature proof registry');
}

function candidateBinding(candidateRunId, candidateArtifactDigest, aggregateSnapshot) {
  if (!RUN_ID.test(String(candidateRunId ?? '')) || !CANDIDATE_DIGEST.test(candidateArtifactDigest ?? '')) {
    throw new Error('candidate run id and artifact digest are required');
  }
  return {
    runId: String(candidateRunId),
    artifactDigest: candidateArtifactDigest,
    productProofClosureSha256: aggregateSnapshot.sha256
  };
}

function assertExactRoles(registration, contract) {
  const expected = [...contract.artifacts].sort((left, right) => left.role.localeCompare(right.role));
  const actual = [...registration.artifacts].sort((left, right) => left.role.localeCompare(right.role));
  if (actual.length !== expected.length) {
    throw new Error(`${contract.requirementId} feature registration must contain exactly ${expected.length} artifacts`);
  }
  for (let index = 0; index < expected.length; index += 1) {
    if (actual[index].role !== expected[index].role) {
      throw new Error(`${contract.requirementId} feature registration roles must be exactly: ${expected.map((entry) => entry.role).join(', ')}`);
    }
  }
  return actual;
}

export function finalizeProductFeatureProofClosure({
  repoRoot,
  inputRoot,
  requirementId,
  environmentId,
  targetHead,
  candidateRunId,
  candidateArtifactDigest
}) {
  const repository = fs.realpathSync(repoRoot);
  const root = fs.realpathSync(inputRoot);
  requireInside(repository, root, 'feature proof input root');
  const output = path.join(root, FEATURE_PROOF_CLOSURE_PATH);
  fs.rmSync(output, { force: true });
  const aggregateSnapshot = readRegularSnapshot(root, '.linux-release/product-proof-closure.json', 'aggregate product proof closure');
  const aggregate = validateAggregateDocument(parseJson(aggregateSnapshot, 'aggregate product proof closure'));
  if (aggregate.targetHead !== targetHead || aggregate.sourceCommit !== targetHead) {
    throw new Error('aggregate product proof closure is not bound to the requested HEAD');
  }
  if (aggregate.supportEnvironments.includes(environmentId) === false) {
    throw new Error(`unknown support environment: ${environmentId}`);
  }
  const aggregateRoot = path.dirname(aggregateSnapshot.absolute);
  const registrySnapshot = validateRecord(aggregateRoot, aggregate.featureProofRegistry, 'aggregate feature proof registry');
  const registry = validateFeatureProofRegistry(repository, registrySnapshot);
  const contract = registry.contracts.get(requirementId);
  const registrationPath = path.join(root, FEATURE_PROOF_REGISTRATION_PATH);
  if (!contract) {
    if (fs.existsSync(registrationPath)) {
      throw new Error(`no feature proof contract is registered for ${requirementId}`);
    }
    return { registered: false, closure: null, output: null };
  }
  const registrationSnapshot = readRegularSnapshot(root, FEATURE_PROOF_REGISTRATION_PATH, 'feature proof registration');
  const registration = parseJson(registrationSnapshot, 'feature proof registration');
  validateSchema(repository, FEATURE_PROOF_REGISTRATION_SCHEMA_PATH, registration, 'feature proof registration');
  if (registration.requirementId !== requirementId || registration.environmentId !== environmentId) {
    throw new Error('feature proof registration is not bound to the requested requirement and environment');
  }
  const registrations = assertExactRoles(registration, contract);
  const contractByRole = new Map(contract.artifacts.map((entry) => [entry.role, entry]));
  const seenPaths = new Set();
  const seenHashes = new Set();
  const proofs = registrations.map((entry) => {
    const snapshot = readRegularSnapshot(root, entry.path, `${entry.role} feature proof`);
    if (seenPaths.has(snapshot.path)) throw new Error(`feature proof registration repeats path ${snapshot.path}`);
    seenPaths.add(snapshot.path);
    const artifactContract = contractByRole.get(entry.role);
    if (snapshot.size === 0) throw new Error(`${entry.role} feature proof must not be empty`);
    if (snapshot.size > artifactContract.maxBytes) {
      throw new Error(`${entry.role} feature proof exceeds its ${artifactContract.maxBytes}-byte limit`);
    }
    if (seenHashes.has(snapshot.sha256)) throw new Error(`feature proof registration reuses bytes for ${entry.role}`);
    seenHashes.add(snapshot.sha256);
    return {
      role: entry.role,
      mediaType: artifactContract.mediaType,
      ...recordFromSnapshot(repository, snapshot)
    };
  });
  const closure = {
    schemaVersion: 1,
    targetHead,
    sourceCommit: aggregate.sourceCommit,
    status: 'collected',
    requirementId,
    environmentId,
    version: aggregate.version,
    candidate: candidateBinding(candidateRunId, candidateArtifactDigest, aggregateSnapshot),
    registry: recordFromSnapshot(repository, registrySnapshot),
    proofs,
    blockers: []
  };
  validateSchema(repository, FEATURE_PROOF_CLOSURE_SCHEMA_PATH, closure, 'product feature proof closure');
  atomicWriteJson(output, closure);
  return { registered: true, closure, output };
}

export function validateProductFeatureProofClosure({
  repoRoot,
  inputRoot,
  aggregate,
  aggregateSnapshot,
  requirementId,
  environmentId,
  candidateRunId,
  candidateArtifactDigest
}) {
  const repository = fs.realpathSync(repoRoot);
  const root = fs.realpathSync(inputRoot);
  const aggregateRoot = path.dirname(aggregateSnapshot.absolute);
  const registrySnapshot = validateRecord(aggregateRoot, aggregate.featureProofRegistry, 'aggregate feature proof registry');
  const registry = validateFeatureProofRegistry(repository, registrySnapshot);
  const contract = registry.contracts.get(requirementId);
  if (!contract) return null;
  if (!fs.existsSync(path.join(root, FEATURE_PROOF_CLOSURE_PATH))) {
    throw new Error(`product feature proof closure is required for registered requirement ${requirementId}`);
  }
  const closureSnapshot = readRegularSnapshot(root, FEATURE_PROOF_CLOSURE_PATH, 'product feature proof closure');
  const closure = parseJson(closureSnapshot, 'product feature proof closure');
  validateSchema(repository, FEATURE_PROOF_CLOSURE_SCHEMA_PATH, closure, 'product feature proof closure');
  const expectedCandidate = candidateBinding(candidateRunId, candidateArtifactDigest, aggregateSnapshot);
  if (closure.requirementId !== requirementId || closure.environmentId !== environmentId
      || closure.targetHead !== aggregate.targetHead || closure.sourceCommit !== aggregate.sourceCommit
      || closure.version !== aggregate.version || closure.status !== 'collected'
      || closure.blockers.length !== 0
      || JSON.stringify(closure.candidate) !== JSON.stringify(expectedCandidate)) {
    throw new Error('product feature proof closure is not bound to the exact candidate, product, and environment');
  }
  const closureRegistry = validateRecord(repository, closure.registry, 'feature proof closure registry');
  if (closure.registry.path !== repositoryRelative(repository, registrySnapshot.absolute)
      || closureRegistry.sha256 !== registrySnapshot.sha256 || closureRegistry.size !== registrySnapshot.size) {
    throw new Error('product feature proof closure registry does not match the candidate registry');
  }
  const actualRoles = assertExactRoles({ artifacts: closure.proofs }, contract);
  const contractByRole = new Map(contract.artifacts.map((entry) => [entry.role, entry]));
  const seenPaths = new Set();
  const seenHashes = new Set();
  const proofs = actualRoles.map((proof) => {
    const snapshot = validateRecord(repository, proof, `${proof.role} feature proof`);
    requireInside(root, snapshot.absolute, `${proof.role} feature proof`);
    if (seenPaths.has(snapshot.absolute)) throw new Error(`product feature proof closure repeats subject path ${proof.path}`);
    seenPaths.add(snapshot.absolute);
    const expected = contractByRole.get(proof.role);
    if (snapshot.size === 0) throw new Error(`${proof.role} feature proof must not be empty`);
    if (proof.mediaType !== expected.mediaType || snapshot.size > expected.maxBytes) {
      throw new Error(`${proof.role} feature proof violates its registered media type or size contract`);
    }
    if (seenHashes.has(snapshot.sha256)) throw new Error(`product feature proof closure reuses bytes for ${proof.role}`);
    seenHashes.add(snapshot.sha256);
    return { proof, snapshot };
  });
  return { closure, closureSnapshot, registrySnapshot, proofs };
}
