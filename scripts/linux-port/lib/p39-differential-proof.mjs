import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import {
  SUPPORT_ENVIRONMENTS,
  atomicWriteJson,
  readRegularSnapshot
} from './product-proof-closure.mjs';

export const P39_REQUIREMENT_ID = 'P-39';
export const P39_PROOF_ROLE = 'feature.cross-platform-differential-proof';
export const P39_PROOF_FILENAME = 'p39-cross-platform-differential-proof.json';
export const P39_REGISTRATION_FILENAME = 'feature-proof-registration.json';
export const P39_CONTRACT_PATH = 'docs/linux-port/p39-differential-contract.json';
export const P39_CORPUS_FILENAME = 'p39-corpus.json';
export const P39_MACOS_FILENAME = 'p39-macos-oracle.json';
export const P39_LINUX_FILENAME = 'p39-linux-output.json';
export const P39_MACOS_BINARY_FILENAME = 'p39-macos-binary.bin';
export const P39_LINUX_BINARY_FILENAME = 'p39-linux-binary.bin';

export const P39_MACOS_WORKFLOW =
  'github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-pr-gate.yml';
export const P39_LINUX_WORKFLOW =
  'github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-product-parity.yml';

export const P39_REQUIRED_CASE_IDS = Object.freeze([
  'provider-parser',
  'quota-reconciliation',
  'route-inventory',
  'settings-contract',
  'chat-session-events',
  'memory-decisions',
  'daemon-rpc',
  'user-visible-outcomes'
]);

const HEAD = /^[a-f0-9]{40,64}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const CANDIDATE_DIGEST = /^sha256:[a-f0-9]{64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const SEMVER = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/u;
const CANONICAL_RELATIVE_PATH = /^[A-Za-z0-9._/-]+$/u;
const FORBIDDEN_EVIDENCE = /(?:fixture|synthetic|mock|fake|stub)/iu;

const ENVIRONMENT_CONTRACTS = Object.freeze({
  'ubuntu-24.04-gnome-x11-x86_64': {
    os: 'Ubuntu 24.04', desktop: 'GNOME', session: 'x11', architecture: 'x86_64'
  },
  'ubuntu-24.04-gnome-x11-aarch64': {
    os: 'Ubuntu 24.04', desktop: 'GNOME', session: 'x11', architecture: 'aarch64'
  },
  'ubuntu-24.04-gnome-wayland-x86_64': {
    os: 'Ubuntu 24.04', desktop: 'GNOME', session: 'wayland', architecture: 'x86_64'
  },
  'ubuntu-24.04-gnome-wayland-aarch64': {
    os: 'Ubuntu 24.04', desktop: 'GNOME', session: 'wayland', architecture: 'aarch64'
  },
  'fedora-kde-wayland-x86_64': {
    os: 'Fedora', desktop: 'KDE Plasma', session: 'wayland', architecture: 'x86_64'
  },
  'fedora-kde-wayland-aarch64': {
    os: 'Fedora', desktop: 'KDE Plasma', session: 'wayland', architecture: 'aarch64'
  },
  'arch-sway-wayland-x86_64': {
    os: 'Arch Linux', desktop: 'Sway/wlroots', session: 'wayland', architecture: 'x86_64'
  }
});

function exactKeys(value, expected, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new Error(`${label} fields must be exactly: ${wanted.join(', ')}`);
  }
}

function parseJson(bytes, label) {
  try {
    return JSON.parse(Buffer.from(bytes).toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function string(value, label) {
  if (typeof value !== 'string' || value.length === 0 || value.trim() !== value) {
    throw new Error(`${label} must be a nonempty string`);
  }
  return value;
}

function sortedUnique(values, label, { allowEmpty = false } = {}) {
  if (!Array.isArray(values) || (!allowEmpty && values.length === 0)
      || values.some((value) => typeof value !== 'string' || value.length === 0)) {
    throw new Error(`${label} must be a nonempty string array`);
  }
  const sorted = [...values].sort();
  if (new Set(values).size !== values.length || sorted.some((value, index) => value !== values[index])) {
    throw new Error(`${label} must be unique and sorted`);
  }
  return sorted;
}

function assertExactStrings(actual, expected, label) {
  if (!Array.isArray(actual) || actual.length !== expected.length
      || actual.some((value, index) => value !== expected[index])) {
    throw new Error(`${label} must contain exactly: ${expected.join(', ')}`);
  }
}

function canonicalPath(value, label) {
  string(value, label);
  if (!CANONICAL_RELATIVE_PATH.test(value) || value.includes('\\')
      || path.posix.isAbsolute(value) || path.posix.normalize(value) !== value
      || value === '.' || value === '..' || value.startsWith('../')) {
    throw new Error(`${label} must be a canonical relative POSIX path`);
  }
  return value;
}

export function stableStringify(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map((entry) => stableStringify(entry)).join(',')}]`;
  return `{${Object.keys(value).sort().map((key) =>
    `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(',')}}`;
}

export function sha256Bytes(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function normalizedDigest(value) {
  return sha256Bytes(Buffer.from(stableStringify(value), 'utf8'));
}

function assertCandidate(candidate, label, expected = null) {
  exactKeys(candidate, ['artifactDigest', 'runId'], `${label} candidate`);
  if (!RUN_ID.test(String(candidate.runId ?? '')) || !CANDIDATE_DIGEST.test(candidate.artifactDigest ?? '')) {
    throw new Error(`${label} candidate binding is invalid`);
  }
  if (expected && (String(candidate.runId) !== String(expected.runId)
      || candidate.artifactDigest !== expected.artifactDigest)) {
    throw new Error(`${label} candidate does not match the selected release candidate`);
  }
}

function validateContract(document) {
  exactKeys(document, [
    'corpusSchemaVersion', 'id', 'normalization', 'outputSchemaVersion',
    'requiredCaseIds', 'requiredFeatures', 'schemaVersion'
  ], 'P-39 differential contract');
  if (document.schemaVersion !== 1
      || document.id !== 'openburnbar-linux-p39-differential-contract-v1'
      || document.corpusSchemaVersion !== 1 || document.outputSchemaVersion !== 1) {
    throw new Error('P-39 differential contract has the wrong identity or schema');
  }
  assertExactStrings(document.requiredCaseIds, P39_REQUIRED_CASE_IDS, 'P-39 required case ids');
  assertExactStrings(document.requiredFeatures, P39_REQUIRED_CASE_IDS, 'P-39 required features');
  exactKeys(document.normalization, ['algorithm', 'expectedDivergencePaths', 'platformOnlyMetadata'], 'P-39 normalization contract');
  if (document.normalization.algorithm !== 'sorted-json-v1') {
    throw new Error('P-39 uses an unknown normalization algorithm');
  }
  sortedUnique(document.normalization.platformOnlyMetadata, 'P-39 platform-only metadata');
  if (!Array.isArray(document.normalization.expectedDivergencePaths)
      || document.normalization.expectedDivergencePaths.length !== 0) {
    throw new Error('P-39 has unreviewed expected divergences');
  }
  return document;
}

function sourceRecord(repository, snapshot) {
  const relative = path.relative(repository, snapshot.absolute).split(path.sep).join('/');
  canonicalPath(relative, 'P-39 source path');
  return { path: relative, sha256: snapshot.sha256, size: snapshot.size };
}

function readSourceRecord(repository, record, label) {
  exactKeys(record, ['path', 'sha256', 'size'], label);
  canonicalPath(record.path, `${label} path`);
  if (!SHA256.test(record.sha256 ?? '') || !Number.isSafeInteger(record.size) || record.size <= 0) {
    throw new Error(`${label} has an invalid digest or size`);
  }
  const snapshot = readRegularSnapshot(repository, record.path, label);
  if (snapshot.sha256 !== record.sha256 || snapshot.size !== record.size) {
    throw new Error(`${label} is stale or substituted`);
  }
  return snapshot;
}

function assertNoSymlinkComponents(root, candidate, label) {
  let current = root;
  const relative = path.relative(root, candidate);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} escapes its repository`);
  }
  for (const component of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink()) throw new Error(`${label} traverses a symlink`);
  }
}

function validateEnvironment(environment, platform, environmentId) {
  exactKeys(environment, [
    'architecture', 'clockFrozen', 'desktop', 'featureFlags', 'os',
    'osVersion', 'runtime', 'session', 'timezone'
  ], `${platform} environment`);
  string(environment.architecture, `${platform} architecture`);
  string(environment.os, `${platform} OS`);
  string(environment.osVersion, `${platform} OS version`);
  string(environment.desktop, `${platform} desktop`);
  string(environment.session, `${platform} session`);
  string(environment.runtime, `${platform} runtime`);
  if (environment.timezone !== 'UTC' || environment.clockFrozen !== true) {
    throw new Error(`${platform} evidence must use a frozen UTC clock`);
  }
  sortedUnique(environment.featureFlags, `${platform} feature flags`, { allowEmpty: true });
  if (platform === 'macos') {
    if (environment.os !== 'macOS' || environment.desktop !== 'macOS'
        || environment.session !== 'windowserver') {
      throw new Error('macOS oracle environment is not a macOS WindowServer session');
    }
    return;
  }
  const expected = ENVIRONMENT_CONTRACTS[environmentId];
  if (!expected || environment.os !== expected.os || environment.desktop !== expected.desktop
      || environment.session !== expected.session || environment.architecture !== expected.architecture) {
    throw new Error('Linux differential environment does not match the support row');
  }
}

function validateBinaryDescriptor(binary, platform) {
  exactKeys(binary, ['path', 'sha256', 'size'], `${platform} binary`);
  canonicalPath(binary.path, `${platform} binary path`);
  if (FORBIDDEN_EVIDENCE.test(binary.path) || !SHA256.test(binary.sha256 ?? '')
      || !Number.isSafeInteger(binary.size) || binary.size <= 0) {
    throw new Error(`${platform} binary descriptor is not an attested non-fixture artifact`);
  }
}

function validateProducer(producer, platform) {
  exactKeys(producer, ['repository', 'runId', 'workflow'], `${platform} producer`);
  if (producer.repository !== 'Imagine-That-Ai/BurnBar' || !RUN_ID.test(String(producer.runId ?? ''))
      || FORBIDDEN_EVIDENCE.test(JSON.stringify(producer))) {
    throw new Error(`${platform} producer identity is not trusted`);
  }
  const expectedWorkflow = platform === 'macos' ? P39_MACOS_WORKFLOW : P39_LINUX_WORKFLOW;
  if (producer.workflow !== expectedWorkflow) {
    throw new Error(`${platform} producer workflow is not the canonical differential workflow`);
  }
}

function validateCases(cases, platform, contract, corpus) {
  if (!Array.isArray(cases) || cases.length !== contract.requiredCaseIds.length) {
    throw new Error(`${platform} output must cover every canonical differential case exactly once`);
  }
  const corpusById = new Map(corpus.cases.map((entry) => [entry.caseId, entry]));
  for (const [index, row] of cases.entries()) {
    exactKeys(row, ['caseId', 'feature', 'normalized', 'normalizedSha256'], `${platform} differential case ${index}`);
    if (row.caseId !== contract.requiredCaseIds[index] || row.feature !== contract.requiredFeatures[index]) {
      throw new Error(`${platform} differential cases are not in the canonical order`);
    }
    if (!corpusById.has(row.caseId)) {
      throw new Error(`${platform} output contains a case absent from the attested corpus`);
    }
    if (row.normalized === undefined || !SHA256.test(row.normalizedSha256 ?? '')
        || row.normalizedSha256 !== normalizedDigest(row.normalized)) {
      throw new Error(`${platform} normalized output hash is invalid`);
    }
  }
  return cases;
}

function validateCorpus(document, targetHead, version, contract) {
  exactKeys(document, ['cases', 'id', 'schemaVersion', 'targetHead', 'version'], 'P-39 differential corpus');
  if (document.schemaVersion !== contract.corpusSchemaVersion
      || document.id !== 'openburnbar-linux-p39-differential-corpus-v1'
      || document.targetHead !== targetHead || document.version !== version) {
    throw new Error('P-39 corpus is stale or bound to a different product candidate');
  }
  if (!Array.isArray(document.cases) || document.cases.length !== contract.requiredCaseIds.length) {
    throw new Error('P-39 corpus does not contain the complete case set');
  }
  for (const [index, row] of document.cases.entries()) {
    exactKeys(row, ['caseId', 'feature', 'input'], `P-39 corpus case ${index}`);
    if (row.caseId !== contract.requiredCaseIds[index] || row.feature !== contract.requiredFeatures[index]) {
      throw new Error('P-39 corpus cases are not canonical');
    }
  }
  return document;
}

function validateOutput(document, platform, {
  targetHead,
  environmentId,
  version,
  contract,
  contractSha256,
  corpusSha256,
  candidate
}) {
  exactKeys(document, [
    'binary', 'candidate', 'cases', 'captureMode', 'contractSha256', 'corpusSha256',
    'environment', 'environmentId', 'id', 'platform', 'producer', 'requirementId',
    'schemaVersion', 'sourceCommit', 'targetHead', 'version'
  ], `${platform} differential output`);
  const expectedId = platform === 'macos'
    ? 'openburnbar-linux-p39-macos-oracle-v1'
    : 'openburnbar-linux-p39-linux-output-v1';
  const expectedEnvironment = platform === 'macos' ? 'macos-oracle' : environmentId;
  if (document.schemaVersion !== contract.outputSchemaVersion || document.id !== expectedId
      || document.requirementId !== P39_REQUIREMENT_ID || document.platform !== platform
      || document.environmentId !== expectedEnvironment || document.targetHead !== targetHead
      || document.sourceCommit !== targetHead || document.version !== version
      || document.captureMode !== 'live' || document.contractSha256 !== contractSha256
      || document.corpusSha256 !== corpusSha256) {
    throw new Error(`${platform} differential output is stale, fixture-backed, or not candidate-bound`);
  }
  assertCandidate(document.candidate, `${platform} differential output`, platform === 'linux' ? candidate : null);
  validateProducer(document.producer, platform);
  if (String(document.producer.runId) !== String(document.candidate.runId)) {
    throw new Error(`${platform} producer run id does not match its candidate`);
  }
  validateEnvironment(document.environment, platform, environmentId);
  validateBinaryDescriptor(document.binary, platform);
  validateCases(document.cases, platform, contract, {
    cases: contract.requiredCaseIds.map((caseId, index) => ({ caseId, feature: contract.requiredFeatures[index] }))
  });
  return document;
}

function compareOutputs(macos, linux, contract) {
  const mismatches = [];
  for (const [index, macCase] of macos.cases.entries()) {
    const linuxCase = linux.cases[index];
    if (stableStringify(macCase.normalized) !== stableStringify(linuxCase.normalized)) {
      mismatches.push(macCase.caseId);
    }
  }
  if (mismatches.length > 0) {
    throw new Error(`P-39 normalized differential mismatch: ${mismatches.join(', ')}`);
  }
  const normalizedCases = macos.cases.map((row) => ({
    caseId: row.caseId,
    feature: row.feature,
    normalized: row.normalized
  }));
  return {
    algorithm: contract.normalization.algorithm,
    caseCount: normalizedCases.length,
    expectedDivergencePaths: contract.normalization.expectedDivergencePaths,
    featureIds: contract.requiredFeatures,
    mismatchCount: 0,
    normalizedOutputSha256: normalizedDigest(normalizedCases),
    status: 'passed'
  };
}

function validateComparison(comparison, expected) {
  exactKeys(comparison, [
    'algorithm', 'caseCount', 'expectedDivergencePaths', 'featureIds',
    'mismatchCount', 'normalizedOutputSha256', 'status'
  ], 'P-39 comparison');
  if (JSON.stringify(comparison) !== JSON.stringify(expected)) {
    throw new Error('P-39 comparison summary is stale or substituted');
  }
}

function sourceWithinRequirement(record, environmentId, label) {
  const prefix = `docs/linux-port/evidence/product-parity-inputs/P-39/${environmentId}/`;
  if (!record.path.startsWith(prefix) || FORBIDDEN_EVIDENCE.test(record.path)) {
    throw new Error(`${label} is outside the candidate P-39 evidence root`);
  }
}

function loadContract(repository) {
  const snapshot = readRegularSnapshot(repository, P39_CONTRACT_PATH, 'P-39 differential contract');
  const document = validateContract(parseJson(snapshot.bytes, 'P-39 differential contract'));
  return { snapshot, document };
}

function removeStaleOutputs(inputRoot) {
  fs.rmSync(path.join(inputRoot, 'feature-artifacts', P39_PROOF_FILENAME), { force: true });
  fs.rmSync(path.join(inputRoot, P39_REGISTRATION_FILENAME), { force: true });
}

export function canonicalP39ProofPath(inputRoot) {
  return path.join(inputRoot, 'feature-artifacts', P39_PROOF_FILENAME);
}

export function parseP39Json(bytes, label) {
  return parseJson(bytes, label);
}

export function validateP39DifferentialProof({
  repoRoot,
  snapshot,
  targetHead,
  environmentId,
  candidateRunId,
  candidateArtifactDigest,
  releaseVersion = null
}) {
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId)) {
    throw new Error('P-39 environment is outside the support matrix');
  }
  const repository = fs.realpathSync(repoRoot);
  const document = parseJson(snapshot.bytes, 'P-39 differential proof');
  exactKeys(document, [
    'candidate', 'comparison', 'contract', 'corpus', 'environmentId', 'generatedAt',
    'id', 'requirementId', 'schemaVersion', 'sources', 'status',
    'targetHead', 'version'
  ], 'P-39 differential proof');
  if (document.schemaVersion !== 1 || document.id !== 'openburnbar-linux-p39-differential-proof-v1'
      || document.requirementId !== P39_REQUIREMENT_ID || document.environmentId !== environmentId
      || document.targetHead !== targetHead || document.status !== 'passed'
      || !HEAD.test(targetHead ?? '') || !SEMVER.test(document.version ?? '')
      || !Number.isFinite(Date.parse(document.generatedAt ?? ''))) {
    throw new Error('P-39 differential proof is not invocation-bound');
  }
  if (releaseVersion !== null && document.version !== releaseVersion) {
    throw new Error('P-39 differential proof version does not match the release closure');
  }
  assertCandidate(document.candidate, 'P-39 differential proof', {
    runId: String(candidateRunId), artifactDigest: candidateArtifactDigest
  });
  const contract = loadContract(repository);
  exactKeys(document.contract, ['path', 'sha256', 'size'], 'P-39 contract source');
  if (document.contract.path !== contract.snapshot.path || document.contract.sha256 !== contract.snapshot.sha256
      || document.contract.size !== contract.snapshot.size) {
    throw new Error('P-39 contract source is stale or substituted');
  }
  exactKeys(document.corpus, ['path', 'sha256', 'size'], 'P-39 corpus source');
  exactKeys(document.sources, ['linux', 'linuxBinary', 'macos', 'macosBinary'], 'P-39 source records');
  const sourceRows = [document.corpus, document.sources.linux, document.sources.linuxBinary,
    document.sources.macos, document.sources.macosBinary];
  const sourcePaths = new Set();
  const snapshots = new Map();
  for (const [index, record] of sourceRows.entries()) {
    const label = `P-39 source ${index}`;
    sourceWithinRequirement(record, environmentId, label);
    if (sourcePaths.has(record.path)) throw new Error(`P-39 source path is duplicated: ${record.path}`);
    sourcePaths.add(record.path);
    const current = readSourceRecord(repository, record, label);
    snapshots.set(record.path, current);
  }
  const corpusSnapshot = snapshots.get(document.corpus.path);
  const corpus = validateCorpus(parseJson(corpusSnapshot.bytes, 'P-39 differential corpus'), targetHead, document.version, contract.document);
  const macosSnapshot = snapshots.get(document.sources.macos.path);
  const linuxSnapshot = snapshots.get(document.sources.linux.path);
  const macos = parseJson(macosSnapshot.bytes, 'P-39 macOS oracle');
  const linux = parseJson(linuxSnapshot.bytes, 'P-39 Linux output');
  const candidate = { runId: String(candidateRunId), artifactDigest: candidateArtifactDigest };
  validateOutput(macos, 'macos', {
    targetHead, environmentId, version: document.version, contract: contract.document,
    contractSha256: contract.snapshot.sha256, corpusSha256: corpusSnapshot.sha256, candidate
  });
  validateOutput(linux, 'linux', {
    targetHead, environmentId, version: document.version, contract: contract.document,
    contractSha256: contract.snapshot.sha256, corpusSha256: corpusSnapshot.sha256, candidate
  });
  if (JSON.stringify(macos.environment.featureFlags) !== JSON.stringify(linux.environment.featureFlags)) {
    throw new Error('P-39 feature flags differ between macOS and Linux');
  }
  const macosBinary = snapshots.get(document.sources.macosBinary.path);
  const linuxBinary = snapshots.get(document.sources.linuxBinary.path);
  for (const [platform, output, sourcePath, binarySnapshot] of [
    ['macos', macos, document.sources.macos.path, macosBinary],
    ['linux', linux, document.sources.linux.path, linuxBinary]
  ]) {
    const expectedPath = path.posix.normalize(path.posix.join(path.posix.dirname(sourcePath), output.binary.path));
    const actualPath = platform === 'macos' ? document.sources.macosBinary.path : document.sources.linuxBinary.path;
    if (expectedPath !== actualPath || output.binary.sha256 !== binarySnapshot.sha256
        || output.binary.size !== binarySnapshot.size) {
      throw new Error(`P-39 ${platform} binary is stale or substituted`);
    }
  }
  const expectedComparison = compareOutputs(macos, linux, contract.document);
  validateComparison(document.comparison, expectedComparison);
  return document;
}

export function captureP39Differential({
  repoRoot,
  inputRoot,
  environmentId,
  targetHead,
  candidateRunId,
  candidateArtifactDigest,
  gitHead = null
}) {
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId)) throw new Error('unknown P-39 support environment');
  const repository = fs.realpathSync(repoRoot);
  assertNoSymlinkComponents(repository, path.resolve(repository, inputRoot), 'P-39 input root');
  const evidenceRoot = fs.realpathSync(inputRoot);
  const relativeRoot = path.relative(repository, evidenceRoot);
  if (relativeRoot === '..' || relativeRoot.startsWith(`..${path.sep}`) || path.isAbsolute(relativeRoot)) {
    throw new Error('P-39 input root must be inside the repository');
  }
  removeStaleOutputs(evidenceRoot);
  const currentHead = gitHead
    ? String(gitHead())
    : String(spawnSync('git', ['rev-parse', 'HEAD'], { cwd: repository, encoding: 'utf8' }).stdout).trim();
  if (currentHead !== targetHead) throw new Error('P-39 capture checkout is not the requested target HEAD');
  const contract = loadContract(repository);
  const readInput = (file, label) => readRegularSnapshot(evidenceRoot, file, label);
  const corpusSnapshot = readInput(P39_CORPUS_FILENAME, 'P-39 corpus input');
  const macosSnapshot = readInput(P39_MACOS_FILENAME, 'P-39 macOS oracle input');
  const linuxSnapshot = readInput(P39_LINUX_FILENAME, 'P-39 Linux output input');
  const macos = parseJson(macosSnapshot.bytes, 'P-39 macOS oracle input');
  const linux = parseJson(linuxSnapshot.bytes, 'P-39 Linux output input');
  const corpus = validateCorpus(parseJson(corpusSnapshot.bytes, 'P-39 corpus input'), targetHead, macos.version, contract.document);
  if (linux.version !== macos.version) throw new Error('P-39 macOS and Linux versions differ');
  const candidate = { runId: String(candidateRunId), artifactDigest: candidateArtifactDigest };
  validateOutput(macos, 'macos', {
    targetHead, environmentId, version: corpus.version, contract: contract.document,
    contractSha256: contract.snapshot.sha256, corpusSha256: corpusSnapshot.sha256, candidate: null
  });
  validateOutput(linux, 'linux', {
    targetHead, environmentId, version: corpus.version, contract: contract.document,
    contractSha256: contract.snapshot.sha256, corpusSha256: corpusSnapshot.sha256, candidate
  });
  if (JSON.stringify(macos.environment.featureFlags) !== JSON.stringify(linux.environment.featureFlags)) {
    throw new Error('P-39 feature flags differ between macOS and Linux');
  }
  const macosBinarySnapshot = readInput(macos.binary.path, 'P-39 macOS binary');
  const linuxBinarySnapshot = readInput(linux.binary.path, 'P-39 Linux binary');
  if (macos.binary.sha256 !== macosBinarySnapshot.sha256 || macos.binary.size !== macosBinarySnapshot.size
      || linux.binary.sha256 !== linuxBinarySnapshot.sha256 || linux.binary.size !== linuxBinarySnapshot.size) {
    throw new Error('P-39 binary descriptor does not match the supplied bytes');
  }
  const comparison = compareOutputs(macos, linux, contract.document);
  const output = canonicalP39ProofPath(evidenceRoot);
  const document = {
    schemaVersion: 1,
    id: 'openburnbar-linux-p39-differential-proof-v1',
    generatedAt: new Date().toISOString(),
    requirementId: P39_REQUIREMENT_ID,
    environmentId,
    targetHead,
    version: corpus.version,
    candidate,
    contract: sourceRecord(repository, contract.snapshot),
    corpus: sourceRecord(repository, corpusSnapshot),
    sources: {
      linux: sourceRecord(repository, linuxSnapshot),
      linuxBinary: sourceRecord(repository, linuxBinarySnapshot),
      macos: sourceRecord(repository, macosSnapshot),
      macosBinary: sourceRecord(repository, macosBinarySnapshot)
    },
    comparison,
    status: 'passed'
  };
  atomicWriteJson(output, document);
  atomicWriteJson(path.join(evidenceRoot, P39_REGISTRATION_FILENAME), {
    schemaVersion: 1,
    requirementId: P39_REQUIREMENT_ID,
    environmentId,
    artifacts: [{ role: P39_PROOF_ROLE, path: `feature-artifacts/${P39_PROOF_FILENAME}` }]
  });
  const proofSnapshot = readRegularSnapshot(evidenceRoot, `feature-artifacts/${P39_PROOF_FILENAME}`, 'P-39 proof');
  validateP39DifferentialProof({
    repoRoot: repository,
    snapshot: proofSnapshot,
    targetHead,
    environmentId,
    candidateRunId,
    candidateArtifactDigest,
    releaseVersion: corpus.version
  });
  return { output, registration: path.join(evidenceRoot, P39_REGISTRATION_FILENAME), document };
}

export function sourceContractPath() {
  return P39_CONTRACT_PATH;
}
