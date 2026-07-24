#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  DIGEST_PATTERN,
  HEAD_PATTERN,
  RUN_ID_PATTERN,
  SHA256_PATTERN,
  VERSION_PATTERN,
  artifactRecord,
  atomicWriteJson,
  parseJson,
  validateCollectedAt
} from './lib/installed-ui-proof.mjs';
import {
  P10_PROOF_FILENAME,
  P10_PROOF_ROLE,
  buildP10Proof,
  validateP10InstalledSession,
  validateP10Proof
} from './lib/p10-dashboard-layout-proof.mjs';
import { readRegularSnapshot, SUPPORT_ENVIRONMENTS } from './lib/product-proof-closure.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

function currentHead(repoRoot) {
  const result = spawnSync('git', ['rev-parse', '--verify', 'HEAD'], { cwd: repoRoot, encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`unable to resolve checkout HEAD: ${(result.stderr || '').trim()}`);
  return result.stdout.trim();
}

function insideRepo(repoRoot, candidate, label) {
  const root = fs.realpathSync(repoRoot);
  const absolute = fs.realpathSync(candidate);
  const relative = path.relative(root, absolute);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} must remain inside the repository`);
  }
  return { root, absolute };
}

export function captureP10DashboardLayoutProof({
  inputRoot,
  sessionReport,
  environmentId,
  targetHead,
  candidateRunId,
  candidateArtifactDigest,
  packageVersion,
  manifestSha256,
  manifestSignatureSha256,
  repoRoot = DEFAULT_REPO_ROOT,
  resolveHead = currentHead,
  now = () => new Date()
}) {
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId) || !HEAD_PATTERN.test(targetHead)
      || !RUN_ID_PATTERN.test(String(candidateRunId)) || !DIGEST_PATTERN.test(candidateArtifactDigest)
      || !VERSION_PATTERN.test(packageVersion ?? '') || !SHA256_PATTERN.test(manifestSha256 ?? '')
      || !SHA256_PATTERN.test(manifestSignatureSha256 ?? '')) {
    throw new Error('P-10 invocation binding is invalid');
  }
  const rootInfo = insideRepo(repoRoot, inputRoot, 'P-10 input root');
  const reportInfo = insideRepo(repoRoot, sessionReport, 'P-10 session report');
  if (resolveHead(rootInfo.root) !== targetHead) throw new Error('P-10 target HEAD does not match checkout HEAD');
  const reportRecord = artifactRecord(rootInfo.root, reportInfo.absolute, 'P-10', environmentId, 'P-10 session report');
  const reportSnapshot = readRegularSnapshot(rootInfo.root, reportRecord.path, 'P-10 session report');
  const binding = {
    repoRoot: rootInfo.root, environmentId, targetHead, candidateRunId: String(candidateRunId),
    candidateArtifactDigest, packageVersion, manifestSha256, manifestSignatureSha256
  };
  const validated = validateP10InstalledSession(parseJson(reportSnapshot.bytes, 'P-10 session report'), binding, { repoRoot: rootInfo.root });
  const collectedAt = now().toISOString();
  validateCollectedAt(collectedAt, validated.endedAt);

  const proof = buildP10Proof({ session: validated.document, sessionRecord: reportRecord, collectedAt });
  const output = path.join(rootInfo.absolute, 'feature-artifacts', P10_PROOF_FILENAME);
  const registration = path.join(rootInfo.absolute, 'feature-proof-registration.json');
  fs.rmSync(output, { force: true });
  fs.rmSync(registration, { force: true });
  atomicWriteJson(output, proof);
  const proofRecord = artifactRecord(rootInfo.root, output, 'P-10', environmentId, 'P-10 emitted proof');
  validateP10Proof({
    repoRoot: rootInfo.root,
    snapshot: readRegularSnapshot(rootInfo.root, proofRecord.path, 'P-10 emitted proof'),
    ...binding
  });
  atomicWriteJson(registration, {
    schemaVersion: 1,
    requirementId: 'P-10',
    environmentId,
    artifacts: [{ role: P10_PROOF_ROLE, path: `feature-artifacts/${P10_PROOF_FILENAME}` }]
  });
  return { output, registration, document: proof };
}

function parseArguments(argv) {
  const allowed = new Set([
    '--input-root', '--session-report', '--environment', '--target-head',
    '--candidate-run-id', '--candidate-artifact-digest', '--package-version',
    '--manifest-sha256', '--manifest-signature-sha256'
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
    inputRoot: values.get('--input-root'), sessionReport: values.get('--session-report'),
    environmentId: values.get('--environment'), targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'), candidateArtifactDigest: values.get('--candidate-artifact-digest'),
    packageVersion: values.get('--package-version'), manifestSha256: values.get('--manifest-sha256'),
    manifestSignatureSha256: values.get('--manifest-signature-sha256')
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = captureP10DashboardLayoutProof(parseArguments(process.argv.slice(2)));
    process.stdout.write(`${JSON.stringify({ output: result.output, registration: result.registration }, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`P-10 dashboard-layout capture failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
