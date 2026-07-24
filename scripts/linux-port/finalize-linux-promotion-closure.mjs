#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  atomicWriteJson,
  readRegularSnapshot,
  validateAggregateDocument
} from './lib/product-proof-closure.mjs';

const DEFAULT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const REQUIREMENTS = Array.from({ length: 40 }, (_, index) => `P-${String(index + 1).padStart(2, '0')}`);
const ENVIRONMENTS = [
  'ubuntu-24.04-gnome-x11-x86_64',
  'ubuntu-24.04-gnome-x11-aarch64',
  'ubuntu-24.04-gnome-wayland-x86_64',
  'ubuntu-24.04-gnome-wayland-aarch64',
  'fedora-kde-wayland-x86_64',
  'fedora-kde-wayland-aarch64',
  'arch-sway-wayland-x86_64'
];

function assertExactKeys(value, expected, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be an object`);
  const actual = Object.keys(value).sort();
  const canonical = [...expected].sort();
  if (actual.length !== canonical.length || actual.some((field, index) => field !== canonical[index])) {
    throw new Error(`${label} fields are not canonical`);
  }
}

function assertCandidate(value, expected, label) {
  assertExactKeys(value, ['runId', 'artifactDigest', 'productProofClosureSha256'], label);
  if (value.runId !== expected.runId || value.artifactDigest !== expected.artifactDigest
      || value.productProofClosureSha256 !== expected.productProofClosureSha256) {
    throw new Error(`${label} does not match the selected release candidate`);
  }
}

function sameStrings(actual, expected) {
  return Array.isArray(actual) && actual.length === expected.length
    && [...actual].sort().every((value, index) => value === [...expected].sort()[index]);
}

function parseJson(snapshot, label) {
  try {
    return JSON.parse(snapshot.bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function copySnapshot(snapshot, destination, closureRoot) {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  const descriptor = fs.openSync(destination, 'wx', 0o600);
  try {
    fs.writeFileSync(descriptor, snapshot.bytes);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  return {
    path: path.relative(closureRoot, destination).split(path.sep).join('/'),
    sha256: snapshot.sha256,
    size: snapshot.size
  };
}

export function finalizeLinuxPromotionClosure({
  repoRoot = DEFAULT_ROOT,
  candidateRoot,
  parityReportPath,
  candidateRunId,
  candidateArtifactDigest,
  targetHead
}) {
  if (!/^[1-9][0-9]*$/u.test(String(candidateRunId))
      || !/^sha256:[a-f0-9]{64}$/u.test(candidateArtifactDigest ?? '')
      || !/^[a-f0-9]{40}$/u.test(targetHead ?? '')) {
    throw new Error('promotion requires a canonical candidate run id, artifact digest, and target HEAD');
  }
  const repository = fs.realpathSync(repoRoot);
  const candidate = fs.realpathSync(candidateRoot);
  const output = path.join(candidate, 'promotion-closure.json');
  const promotionDir = path.join(candidate, 'promotion');
  fs.rmSync(output, { force: true });
  fs.rmSync(promotionDir, { recursive: true, force: true });
  const productProof = readRegularSnapshot(candidate, 'product-proof-closure.json', 'candidate product proof closure');
  const productDocument = validateAggregateDocument(parseJson(productProof, 'candidate product proof closure'));
  if (productDocument.targetHead !== targetHead) throw new Error('candidate product proof closure target does not match promotion HEAD');
  const expectedCandidate = {
    runId: String(candidateRunId),
    artifactDigest: candidateArtifactDigest,
    productProofClosureSha256: productProof.sha256
  };
  const requestedParityAbsolute = path.isAbsolute(parityReportPath)
    ? path.resolve(parityReportPath)
    : path.resolve(repository, parityReportPath);
  const parityAbsolute = fs.realpathSync(requestedParityAbsolute);
  const parityRelative = path.relative(repository, parityAbsolute).split(path.sep).join('/');
  const paritySnapshot = readRegularSnapshot(repository, parityRelative, 'parity ledger validation');
  const parity = parseJson(paritySnapshot, 'parity ledger validation');
  if (parity.targetHead !== targetHead || parity.allowBlocked !== false || parity.passed !== true
      || parity.structuralPassed !== true || parity.promotionPassed !== true
      || parity.productParityClaim !== true || !Array.isArray(parity.failures) || parity.failures.length !== 0
      || !Array.isArray(parity.structuralFailures) || parity.structuralFailures.length !== 0
      || !Array.isArray(parity.promotionFailures) || parity.promotionFailures.length !== 0
      || !Array.isArray(parity.validatedAttestations) || parity.validatedAttestations.length !== REQUIREMENTS.length) {
    throw new Error('parity ledger validation is not a strict passed promotion report');
  }
  const summaries = new Map();
  for (const summary of parity.validatedAttestations) {
    assertExactKeys(summary, ['requirementId', 'path', 'sha256', 'candidate'], 'validated attestation summary');
    if (!REQUIREMENTS.includes(summary.requirementId) || summaries.has(summary.requirementId)
        || summary.path !== `docs/linux-port/evidence/product-parity/${summary.requirementId}.json`
        || !/^[a-f0-9]{64}$/u.test(summary.sha256 ?? '')) {
      throw new Error('parity ledger validation contains a noncanonical attestation summary');
    }
    assertCandidate(summary.candidate, expectedCandidate, `${summary.requirementId} validated candidate`);
    summaries.set(summary.requirementId, summary);
  }
  const parityRecord = copySnapshot(
    paritySnapshot,
    path.join(promotionDir, 'parity-ledger-validation.json'),
    candidate
  );
  const attestations = [];
  for (const requirementId of REQUIREMENTS) {
    const relative = `docs/linux-port/evidence/product-parity/${requirementId}.json`;
    let snapshot;
    try {
      snapshot = readRegularSnapshot(repository, relative, `${requirementId} product attestation`);
    } catch (error) {
      throw new Error(`${requirementId} product attestation could not be read: ${error.message}`);
    }
    const document = parseJson(snapshot, `${requirementId} product attestation`);
    const summary = summaries.get(requirementId);
    if (document.schemaVersion !== 1 || document.requirementId !== requirementId
        || document.rowId !== requirementId || document.targetHead !== targetHead
        || document.status !== 'passed' || !Array.isArray(document.validatorReceipts)
        || document.validatorReceipts.length !== ENVIRONMENTS.length
        || !sameStrings(document.environments, ENVIRONMENTS)
        || summary?.sha256 !== snapshot.sha256) {
      throw new Error(`${requirementId} product attestation is not a complete passed seven-environment row`);
    }
    assertCandidate(document.candidate, expectedCandidate, `${requirementId} product attestation candidate`);
    const receiptEnvironments = [];
    for (const receipt of document.validatorReceipts) {
      receiptEnvironments.push(receipt.environmentId);
      assertCandidate(receipt.candidate, expectedCandidate, `${requirementId} validator receipt candidate`);
    }
    if (!sameStrings(receiptEnvironments, ENVIRONMENTS)) {
      throw new Error(`${requirementId} product attestation receipt environments are incomplete`);
    }
    attestations.push({
      requirementId,
      ...copySnapshot(snapshot, path.join(promotionDir, 'product-parity', `${requirementId}.json`), candidate)
    });
  }
  const closure = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    stage: 'promotion',
    targetHead,
    sourceCommit: targetHead,
    status: 'passed',
    version: productDocument.version,
    candidate: {
      runId: expectedCandidate.runId,
      artifactDigest: expectedCandidate.artifactDigest,
      productProofClosure: {
        path: 'product-proof-closure.json',
        sha256: productProof.sha256,
        size: productProof.size
      }
    },
    parity: parityRecord,
    requirementAttestations: attestations,
    blockers: []
  };
  atomicWriteJson(output, closure);
  return { closure, output };
}

function parseArguments(argv) {
  const allowed = new Set([
    '--candidate-root', '--parity-report', '--candidate-run-id', '--candidate-artifact-digest', '--target-head'
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag) || value === undefined || values.has(flag)) throw new Error(`invalid argument: ${flag ?? '<missing>'}`);
    values.set(flag, value);
  }
  for (const flag of allowed) if (!values.has(flag)) throw new Error(`${flag} is required`);
  return {
    candidateRoot: values.get('--candidate-root'),
    parityReportPath: values.get('--parity-report'),
    candidateRunId: values.get('--candidate-run-id'),
    candidateArtifactDigest: values.get('--candidate-artifact-digest'),
    targetHead: values.get('--target-head')
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = finalizeLinuxPromotionClosure(parseArguments(process.argv.slice(2)));
    process.stdout.write(`${JSON.stringify({ output: result.output, status: result.closure.status }, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`Linux promotion closure finalization failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
