import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {
  compareArtifacts
} from '../run-platform-differential.mjs';
import {
  readRegularSnapshot,
  SUPPORT_ENVIRONMENTS
} from './product-proof-closure.mjs';

export const P39_REQUIREMENT_ID = 'P-39';
export const P39_PROOF_FILENAME = 'p39-differential-proof.json';
export const P39_PROOF_ROLE = 'differential-proof';
export const P39_PROOF_ID = 'openburnbar-linux-p39-differential-proof-v1';
export const P39_ARTIFACT_ID = 'openburnbar-platform-evidence-v1';
export const P39_CONTRACT_SCHEMA_VERSION = 1;
export const P39_ALLOWED_VOLATILE_PATHS = Object.freeze([
  '$.payload.generatedAt',
  '$.payload.execution'
]);

const HEAD = /^[a-f0-9]{40,64}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const CANDIDATE_DIGEST = /^sha256:[a-f0-9]{64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const VERSION = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;
const ISO_UTC_MILLISECONDS = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u;
const IGNORE_PATH = /^\$(?:\.[A-Za-z0-9_$:-]+|\[(?:0|[1-9][0-9]*)\])+$/u;
const BINDING_PATHS = new Set([
  '$.schemaVersion', '$.id', '$.targetHead', '$.version', '$.candidate',
  '$.candidate.runId', '$.candidate.artifactDigest'
]);

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

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function assertCandidate(candidate, targetHead, candidateRunId, candidateArtifactDigest, label) {
  exactKeys(candidate, ['artifactDigest', 'runId'], `${label} candidate`);
  if (!RUN_ID.test(String(candidate?.runId ?? '')) || String(candidate.runId) !== String(candidateRunId)) {
    throw new Error(`${label} candidate run id is not invocation-bound`);
  }
  if (!CANDIDATE_DIGEST.test(candidate?.artifactDigest ?? '') || candidate.artifactDigest !== candidateArtifactDigest) {
    throw new Error(`${label} candidate artifact digest is not invocation-bound`);
  }
  if (!HEAD.test(targetHead)) throw new Error(`${label} target HEAD is invalid`);
}

export function validateIgnorePaths(paths) {
  if (!Array.isArray(paths)) throw new Error('P-39 ignoredPaths must be an array');
  const normalized = [...new Set(paths)];
  if (normalized.length !== paths.length) throw new Error('P-39 ignoredPaths must not contain duplicates');
  for (const value of normalized) {
    if (typeof value !== 'string' || !IGNORE_PATH.test(value) || value === '$') {
      throw new Error(`P-39 ignored path is not canonical: ${String(value)}`);
    }
    if (BINDING_PATHS.has(value) || value.startsWith('$.candidate.')) {
      throw new Error(`P-39 may not ignore candidate binding path: ${value}`);
    }
    if (!P39_ALLOWED_VOLATILE_PATHS.includes(value)) {
      throw new Error(`P-39 ignored path is not an approved platform-only divergence: ${value}`);
    }
  }
  return [...normalized].sort();
}

export function validateBoundArtifact(document, {
  targetHead,
  version,
  candidateRunId,
  candidateArtifactDigest
}) {
  exactKeys(document, ['candidate', 'id', 'payload', 'schemaVersion', 'targetHead', 'version'], 'P-39 platform artifact');
  if (document.schemaVersion !== P39_CONTRACT_SCHEMA_VERSION
      || document.id !== P39_ARTIFACT_ID
      || document.targetHead !== targetHead
      || document.version !== version
      || !HEAD.test(document.targetHead ?? '')
      || !VERSION.test(document.version ?? '')) {
    throw new Error('P-39 platform artifact is not bound to the requested product head and version');
  }
  assertCandidate(document.candidate, targetHead, candidateRunId, candidateArtifactDigest, 'P-39 platform artifact');
  if (document.payload === undefined) throw new Error('P-39 platform artifact payload is required');
  return document;
}

function sourceRecord(snapshot, repoRoot) {
  const relative = path.relative(repoRoot, snapshot.absolute).split(path.sep).join('/');
  return { path: relative, sha256: snapshot.sha256, size: snapshot.size };
}

function validateSourceRecord(repoRoot, record, label) {
  exactKeys(record, ['path', 'sha256', 'size'], label);
  if (!SHA256.test(record.sha256 ?? '') || !Number.isSafeInteger(record.size) || record.size <= 0) {
    throw new Error(`${label} has invalid hash or size`);
  }
  const snapshot = readRegularSnapshot(repoRoot, record.path, label);
  if (snapshot.sha256 !== record.sha256 || snapshot.size !== record.size) {
    throw new Error(`${label} bytes changed after capture`);
  }
  return snapshot;
}

function assertEvidencePath(record, environmentId, label) {
  const root = `docs/linux-port/evidence/product-parity-inputs/${P39_REQUIREMENT_ID}/${environmentId}/`;
  if (!record.path.startsWith(root)) {
    throw new Error(`${label} must remain under the P-39 environment evidence root`);
  }
}

function parseReport(snapshot, label) {
  const report = parseJson(snapshot.bytes, label);
  exactKeys(report, ['differences', 'ignoredPaths', 'linux', 'macos', 'schemaVersion', 'status'], label);
  exactKeys(report.macos, ['sha256'], `${label} macOS summary`);
  exactKeys(report.linux, ['sha256'], `${label} Linux summary`);
  if (report.schemaVersion !== 1 || report.status !== 'exact_match'
      || !Array.isArray(report.differences) || report.differences.length !== 0
      || !SHA256.test(report.macos.sha256 ?? '') || !SHA256.test(report.linux.sha256 ?? '')) {
    throw new Error(`${label} is not a passed exact-match report`);
  }
  return report;
}

function isCanonicalGeneratedAt(value) {
  return typeof value === 'string'
    && ISO_UTC_MILLISECONDS.test(value)
    && new Date(value).toISOString() === value;
}

export function validateP39DifferentialProof({
  repoRoot,
  snapshot,
  targetHead,
  environmentId,
  version,
  candidateRunId,
  candidateArtifactDigest
}) {
  const document = parseJson(snapshot.bytes, 'P-39 differential proof');
  exactKeys(document, [
    'candidate', 'contract', 'environmentId', 'generatedAt', 'id', 'linux', 'macos',
    'report', 'requirementId', 'schemaVersion', 'status', 'targetHead', 'version'
  ], 'P-39 differential proof');
  exactKeys(document.contract, ['ignoredPaths', 'schemaVersion'], 'P-39 differential contract');
  exactKeys(document.macos, ['path', 'sha256', 'size'], 'P-39 macOS source');
  exactKeys(document.linux, ['path', 'sha256', 'size'], 'P-39 Linux source');
  exactKeys(document.report, ['path', 'sha256', 'size'], 'P-39 report source');
  if (document.schemaVersion !== 1 || document.id !== P39_PROOF_ID
      || document.requirementId !== P39_REQUIREMENT_ID || document.status !== 'passed'
      || document.environmentId !== environmentId || !SUPPORT_ENVIRONMENTS.includes(environmentId)
      || document.targetHead !== targetHead || !HEAD.test(targetHead ?? '')
      || document.version !== version || !VERSION.test(version ?? '')
      || !isCanonicalGeneratedAt(document.generatedAt)) {
    throw new Error('P-39 differential proof is not invocation-bound');
  }
  assertCandidate(document.candidate, targetHead, candidateRunId, candidateArtifactDigest, 'P-39 differential proof');
  if (document.contract.schemaVersion !== P39_CONTRACT_SCHEMA_VERSION) {
    throw new Error('P-39 differential contract schemaVersion is unsupported');
  }
  const ignoredPaths = validateIgnorePaths(document.contract.ignoredPaths);
  assertEvidencePath(document.macos, environmentId, 'P-39 macOS source');
  assertEvidencePath(document.linux, environmentId, 'P-39 Linux source');
  assertEvidencePath(document.report, environmentId, 'P-39 differential report');
  const macos = validateSourceRecord(repoRoot, document.macos, 'P-39 macOS source');
  const linux = validateSourceRecord(repoRoot, document.linux, 'P-39 Linux source');
  const macosArtifact = validateBoundArtifact(parseJson(macos.bytes, 'P-39 macOS source'), {
    targetHead, version, candidateRunId, candidateArtifactDigest
  });
  const linuxArtifact = validateBoundArtifact(parseJson(linux.bytes, 'P-39 Linux source'), {
    targetHead, version, candidateRunId, candidateArtifactDigest
  });
  const reportSnapshot = validateSourceRecord(repoRoot, document.report, 'P-39 differential report');
  const report = parseReport(reportSnapshot, 'P-39 differential report');
  const expected = compareArtifacts(macosArtifact, linuxArtifact, { ignore: ignoredPaths });
  if (JSON.stringify(report) !== JSON.stringify(expected)) {
    throw new Error('P-39 differential report is stale, substituted, or uses different normalization');
  }
  return document;
}

export function canonicalProofPath(inputRoot) {
  return path.join(inputRoot, P39_PROOF_FILENAME);
}

export function removeStaleP39Proof(inputRoot) {
  fs.rmSync(canonicalProofPath(inputRoot), { force: true });
}

export function proofReport({ macos, linux, ignoredPaths }) {
  return compareArtifacts(macos, linux, { ignore: ignoredPaths });
}
