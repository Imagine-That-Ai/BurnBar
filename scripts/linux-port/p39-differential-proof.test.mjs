import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { captureP39Differential } from './capture-p39-differential.mjs';
import {
  P39_CONTRACT_PATH,
  P39_LINUX_BINARY_FILENAME,
  P39_LINUX_FILENAME,
  P39_LINUX_WORKFLOW,
  P39_MACOS_BINARY_FILENAME,
  P39_MACOS_FILENAME,
  P39_MACOS_WORKFLOW,
  P39_PROOF_FILENAME,
  P39_PROOF_ROLE,
  P39_REQUIRED_CASE_IDS,
  parseP39Json,
  sha256Bytes,
  stableStringify,
  validateP39DifferentialProof
} from './lib/p39-differential-proof.mjs';
import { readRegularSnapshot } from './lib/product-proof-closure.mjs';
import { validateFeatureProofRegistry } from './lib/product-feature-proof.mjs';

const HEAD = 'a'.repeat(40);
const ENVIRONMENT = 'ubuntu-24.04-gnome-x11-x86_64';
const RUN_ID = '12345';
const DIGEST = `sha256:${'b'.repeat(64)}`;
const MAC_RUN_ID = '54321';
const MAC_DIGEST = `sha256:${'c'.repeat(64)}`;

function write(file, bytes) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  return file;
}

function writeJson(file, value) {
  return write(file, `${JSON.stringify(value, null, 2)}\n`);
}

function digestFile(file) {
  return sha256Bytes(fs.readFileSync(file));
}

function tempInput() {
  const parent = path.join(process.cwd(), 'docs/linux-port/evidence/product-parity-inputs/P-39', ENVIRONMENT);
  fs.mkdirSync(parent, { recursive: true });
  const inputRoot = fs.mkdtempSync(path.join(parent, '.p39-test-'));
  return inputRoot;
}

function cleanup(inputRoot) {
  fs.rmSync(inputRoot, { recursive: true, force: true });
  const parent = path.dirname(inputRoot);
  try { if (fs.readdirSync(parent).length === 0) fs.rmdirSync(parent); } catch { /* test cleanup */ }
  const root = path.dirname(parent);
  try { if (fs.readdirSync(root).length === 0) fs.rmdirSync(root); } catch { /* test cleanup */ }
}

function contractDigest() {
  return digestFile(path.join(process.cwd(), P39_CONTRACT_PATH));
}

function cases() {
  return P39_REQUIRED_CASE_IDS.map((caseId, index) => ({
    caseId,
    feature: caseId,
    input: { ordinal: index, prompt: `case-${caseId}` }
  }));
}

function normalizedCases() {
  return P39_REQUIRED_CASE_IDS.map((caseId, index) => ({
    caseId,
    feature: caseId,
    normalized: {
      accepted: true,
      ordinal: index,
      result: `${caseId}-result`
    }
  }));
}

function sourceDocument({ platform, version = '1.2.3', corpusSha256, contractSha256, binaryPath, binarySha256, binarySize }) {
  const macos = platform === 'macos';
  const rows = normalizedCases();
  return {
    schemaVersion: 1,
    id: macos ? 'openburnbar-linux-p39-macos-oracle-v1' : 'openburnbar-linux-p39-linux-output-v1',
    requirementId: 'P-39',
    platform,
    environmentId: macos ? 'macos-oracle' : ENVIRONMENT,
    targetHead: HEAD,
    sourceCommit: HEAD,
    version,
    captureMode: 'live',
    candidate: {
      runId: macos ? MAC_RUN_ID : RUN_ID,
      artifactDigest: macos ? MAC_DIGEST : DIGEST
    },
    producer: {
      repository: 'Imagine-That-Ai/BurnBar',
      runId: macos ? MAC_RUN_ID : RUN_ID,
      workflow: macos ? P39_MACOS_WORKFLOW : P39_LINUX_WORKFLOW
    },
    environment: macos ? {
      architecture: 'arm64',
      clockFrozen: true,
      desktop: 'macOS',
      featureFlags: [],
      os: 'macOS',
      osVersion: '15.5',
      runtime: 'Swift 6.1',
      session: 'windowserver',
      timezone: 'UTC'
    } : {
      architecture: 'x86_64',
      clockFrozen: true,
      desktop: 'GNOME',
      featureFlags: [],
      os: 'Ubuntu 24.04',
      osVersion: '24.04',
      runtime: 'Node 22',
      session: 'x11',
      timezone: 'UTC'
    },
    contractSha256,
    corpusSha256,
    binary: { path: binaryPath, sha256: binarySha256, size: binarySize },
    cases: rows.map((row) => ({
      ...row,
      normalizedSha256: sha256Bytes(Buffer.from(stableStringify(row.normalized), 'utf8'))
    }))
  };
}

function stageFixture({ mutateMac = null, mutateLinux = null, version = '1.2.3' } = {}) {
  const inputRoot = tempInput();
  const contractSha256 = contractDigest();
  const corpus = {
    schemaVersion: 1,
    id: 'openburnbar-linux-p39-differential-corpus-v1',
    targetHead: HEAD,
    version,
    cases: cases()
  };
  const corpusFile = writeJson(path.join(inputRoot, 'p39-corpus.json'), corpus);
  const corpusSha256 = digestFile(corpusFile);
  const macBinary = write(path.join(inputRoot, P39_MACOS_BINARY_FILENAME), Buffer.from('macOS candidate binary\n'));
  const linuxBinary = write(path.join(inputRoot, P39_LINUX_BINARY_FILENAME), Buffer.from('Linux candidate binary\n'));
  const macosFile = path.join(inputRoot, P39_MACOS_FILENAME);
  const linuxFile = path.join(inputRoot, P39_LINUX_FILENAME);
  const macos = sourceDocument({
    platform: 'macos', version, corpusSha256, contractSha256,
    binaryPath: P39_MACOS_BINARY_FILENAME, binarySha256: digestFile(macBinary), binarySize: fs.statSync(macBinary).size
  });
  const linux = sourceDocument({
    platform: 'linux', version, corpusSha256, contractSha256,
    binaryPath: P39_LINUX_BINARY_FILENAME, binarySha256: digestFile(linuxBinary), binarySize: fs.statSync(linuxBinary).size
  });
  mutateMac?.(macos);
  mutateLinux?.(linux);
  writeJson(macosFile, macos);
  writeJson(linuxFile, linux);
  return { inputRoot, macosFile, linuxFile, corpusFile, macos, linux };
}

function capture(subject) {
  const result = captureP39Differential({
    repoRoot: process.cwd(),
    inputRoot: subject.inputRoot,
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST,
    gitHead: () => HEAD
  });
  return { ...subject, result };
}

function proofSnapshot(subject) {
  return readRegularSnapshot(subject.inputRoot, `feature-artifacts/${P39_PROOF_FILENAME}`, 'P-39 proof');
}

test('P-39 capture emits a live candidate-bound proof and exact registration', () => {
  const subject = stageFixture();
  try {
    const captured = capture(subject);
    assert.equal(captured.result.document.status, 'passed');
    assert.equal(captured.result.document.comparison.caseCount, P39_REQUIRED_CASE_IDS.length);
    assert.equal(captured.result.document.comparison.mismatchCount, 0);
    const registration = JSON.parse(fs.readFileSync(captured.result.registration, 'utf8'));
    assert.deepEqual(registration.artifacts, [{
      role: P39_PROOF_ROLE,
      path: `feature-artifacts/${P39_PROOF_FILENAME}`
    }]);
    validateP39DifferentialProof({
      repoRoot: process.cwd(), snapshot: proofSnapshot(subject), targetHead: HEAD,
      environmentId: ENVIRONMENT, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST,
      releaseVersion: '1.2.3'
    });
  } finally {
    cleanup(subject.inputRoot);
  }
});

test('P-39 capture refuses missing, fixture, stale, and mismatched evidence', () => {
  const casesToReject = [
    ['missing macOS oracle', (subject) => fs.rmSync(subject.macosFile), /P-39 macOS oracle input is missing/u],
    ['fixture capture mode', (subject) => {
      const value = JSON.parse(fs.readFileSync(subject.macosFile, 'utf8'));
      value.captureMode = 'fixture';
      writeJson(subject.macosFile, value);
    }, /fixture-backed/u],
    ['stale checkout', null, /checkout is not the requested target HEAD/u],
    ['normalized output mismatch', (subject) => {
      const value = JSON.parse(fs.readFileSync(subject.linuxFile, 'utf8'));
      value.cases[0].normalized.result = 'mutated';
      value.cases[0].normalizedSha256 = sha256Bytes(Buffer.from(stableStringify(value.cases[0].normalized), 'utf8'));
      writeJson(subject.linuxFile, value);
    }, /normalized differential mismatch/u]
  ];
  for (const [name, mutate, pattern] of casesToReject) {
    const subject = stageFixture();
    try {
      mutate?.(subject);
      assert.throws(() => captureP39Differential({
        repoRoot: process.cwd(), inputRoot: subject.inputRoot, environmentId: ENVIRONMENT,
        targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST,
        gitHead: name === 'stale checkout' ? () => 'd'.repeat(40) : () => HEAD
      }), pattern, name);
      assert.equal(fs.existsSync(path.join(subject.inputRoot, 'feature-artifacts', P39_PROOF_FILENAME)), false);
    } finally {
      cleanup(subject.inputRoot);
    }
  }
});

test('P-39 validator rejects source mutation, candidate substitution, and platform drift', () => {
  const subject = capture(stageFixture());
  try {
    const snapshot = proofSnapshot(subject);
    const validate = () => validateP39DifferentialProof({
      repoRoot: process.cwd(), snapshot: proofSnapshot(subject), targetHead: HEAD,
      environmentId: ENVIRONMENT, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST,
      releaseVersion: '1.2.3'
    });
    assert.throws(() => validateP39DifferentialProof({
      repoRoot: process.cwd(), snapshot, targetHead: HEAD, environmentId: ENVIRONMENT,
      candidateRunId: RUN_ID, candidateArtifactDigest: `sha256:${'f'.repeat(64)}`,
      releaseVersion: '1.2.3'
    }), /candidate does not match/u);

    const proof = parseP39Json(snapshot.bytes, 'P-39 proof');
    const mutated = structuredClone(proof);
    mutated.sources.macosBinary.sha256 = 'f'.repeat(64);
    assert.throws(() => validateP39DifferentialProof({
      repoRoot: process.cwd(), snapshot: { ...snapshot, bytes: Buffer.from(`${JSON.stringify(mutated)}\n`) },
      targetHead: HEAD, environmentId: ENVIRONMENT, candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST, releaseVersion: '1.2.3'
    }), /stale or substituted/u);

    const linux = JSON.parse(fs.readFileSync(subject.linuxFile, 'utf8'));
    linux.environment.featureFlags = ['linux-only'];
    writeJson(subject.linuxFile, linux);
    const flagProof = structuredClone(proof);
    flagProof.sources.linux.sha256 = digestFile(subject.linuxFile);
    flagProof.sources.linux.size = fs.statSync(subject.linuxFile).size;
    assert.throws(() => validateP39DifferentialProof({
      repoRoot: process.cwd(),
      snapshot: { ...snapshot, bytes: Buffer.from(`${JSON.stringify(flagProof)}\n`) },
      targetHead: HEAD, environmentId: ENVIRONMENT, candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST, releaseVersion: '1.2.3'
    }), /feature flags differ/u);
  } finally {
    cleanup(subject.inputRoot);
  }
});

test('P-39 registry and workflow ownership are present', async () => {
  const registrySnapshot = readRegularSnapshot(process.cwd(), 'docs/linux-port/product-feature-proof-registry.json', 'P-39 registry');
  const registry = validateFeatureProofRegistry(process.cwd(), registrySnapshot);
  const contract = registry.contracts.get('P-39');
  assert.deepEqual(contract.artifacts.map((artifact) => artifact.role), [P39_PROOF_ROLE]);
  assert.equal(registry.document.certification.some((row) => row.requirementId === 'P-39'), true);
});
