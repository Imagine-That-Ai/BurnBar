import {
  RELEASE_ARCHITECTURES,
  REQUIREMENT_RELEASE_CLOSURE_SCHEMA_VERSION,
  SUPPORT_ENVIRONMENTS,
  assertExactStringSet,
  environmentPackage,
  readRegularSnapshot
} from '../lib/product-proof-closure.mjs';

const SHA256 = /^[a-f0-9]{64}$/u;

function parseJson(snapshot, label) {
  try {
    return JSON.parse(snapshot.bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function requirementRoot(context) {
  return `docs/linux-port/evidence/product-parity-inputs/${context.requirementId}`;
}

function validateArtifact(context, record, label) {
  if (record === null || typeof record !== 'object' || Array.isArray(record)
      || !SHA256.test(record.sha256 ?? '') || typeof record.path !== 'string') {
    throw new Error(`${label} must contain a canonical path and SHA-256`);
  }
  const root = requirementRoot(context);
  if (record.path !== root && !record.path.startsWith(`${root}/`)) {
    throw new Error(`${label} is outside the requirement evidence root`);
  }
  const snapshot = readRegularSnapshot(context.repoRoot, record.path, label);
  if (snapshot.sha256 !== record.sha256) throw new Error(`${label} SHA-256 does not match its bytes`);
  return { path: record.path, sha256: record.sha256, snapshot };
}

export function validateRequirementContext(context, requiredProofRoles) {
  const closure = context.releaseClosure?.document;
  if (context.schemaVersion !== 1 || closure?.schemaVersion !== REQUIREMENT_RELEASE_CLOSURE_SCHEMA_VERSION
      || closure.targetHead !== context.targetHead || closure.sourceCommit !== context.targetHead
      || closure.status !== 'passed' || closure.requirementId !== context.requirementId
      || closure.environmentId !== context.environmentId || !Array.isArray(closure.blockers)
      || closure.blockers.length !== 0) {
    throw new Error('requirement release closure is not passed and invocation-bound');
  }
  assertExactStringSet(closure.architectures, RELEASE_ARCHITECTURES, 'release architectures');
  assertExactStringSet(closure.supportEnvironments, SUPPORT_ENVIRONMENTS, 'release support environments');
  const { architecture: expectedArchitecture, format: expectedFormat } = environmentPackage(context.environmentId);
  if (closure.selectedPackage?.architecture !== expectedArchitecture
      || closure.selectedPackage?.format !== expectedFormat) {
    throw new Error('requirement release closure selected the wrong native package');
  }
  const manifest = parseJson(
    readRegularSnapshot(context.repoRoot, context.subjects.packageManifest.path, 'installed manifest subject'),
    'installed manifest subject'
  );
  if (manifest.gitCommit !== context.targetHead || manifest.packageArchitecture !== expectedArchitecture
      || manifest.packageFormat !== expectedFormat || manifest.packageVersion !== closure.version) {
    throw new Error('installed manifest does not match the requirement release closure');
  }
  const runtime = parseJson(
    readRegularSnapshot(context.repoRoot, context.subjects.runtimes[0]?.path, 'runtime subject'),
    'runtime subject'
  );
  const environment = parseJson(
    readRegularSnapshot(context.repoRoot, context.subjects.environment.path, 'environment subject'),
    'environment subject'
  );
  if (environment.environmentId !== context.environmentId || environment.targetHead !== context.targetHead
      || environment.architecture !== expectedArchitecture || environment.passed !== true) {
    throw new Error('live environment subject does not match the requirement closure');
  }
  if (runtime.shellVersion !== closure.version || runtime.daemonVersion !== closure.version) {
    throw new Error('live runtime versions do not match the release closure');
  }
  const artifacts = [
    context.subjects.release,
    context.subjects.packageManifest,
    ...context.subjects.packages,
    ...context.subjects.runtimes,
    ...context.subjects.installation,
    context.subjects.environment
  ];
  const manifestSignature = validateArtifact(
    context,
    closure.packageManifestSignature,
    'installed manifest signature subject'
  );
  artifacts.push({ path: manifestSignature.path, sha256: manifestSignature.sha256 });
  if (!Array.isArray(closure.proofs)) throw new Error('requirement release closure has no proofs');
  const proofs = new Map();
  for (const [index, proof] of closure.proofs.entries()) {
    if (typeof proof?.role !== 'string' || proof.role.length === 0) throw new Error(`proof ${index} has no role`);
    const artifact = validateArtifact(context, proof, `${proof.role} proof`);
    const rows = proofs.get(proof.role) ?? [];
    rows.push({ ...proof, snapshot: artifact.snapshot });
    proofs.set(proof.role, rows);
    artifacts.push({ path: artifact.path, sha256: artifact.sha256 });
  }
  for (const role of requiredProofRoles) {
    if (!proofs.has(role)) throw new Error(`requirement release closure is missing ${role} proof`);
  }
  const unique = new Map();
  for (const artifact of artifacts) {
    const existing = unique.get(artifact.path);
    if (existing && existing.sha256 !== artifact.sha256) throw new Error(`artifact path has conflicting hashes: ${artifact.path}`);
    unique.set(artifact.path, { path: artifact.path, sha256: artifact.sha256 });
  }
  return { closure, manifest, runtime, environment, proofs, artifacts: [...unique.values()] };
}

export function requirePassedJsonProof(rows, role) {
  if (!Array.isArray(rows) || rows.length !== 1) throw new Error(`${role} proof must occur exactly once`);
  const document = parseJson(rows[0].snapshot, `${role} proof`);
  const passed = document.passed === true
    || (document.status === 'passed' && (document.failedCount ?? 0) === 0)
    || (document.promotionPassed === true && document.productParityClaim === true);
  if (!passed || (Array.isArray(document.blockers) && document.blockers.length > 0)) {
    throw new Error(`${role} proof is not passed`);
  }
  return document;
}

export function result(context, artifacts) {
  return {
    schemaVersion: 1,
    requirementId: context.requirementId,
    checkId: context.checkId,
    environmentId: context.environmentId,
    targetHead: context.targetHead,
    status: 'passed',
    artifacts
  };
}
