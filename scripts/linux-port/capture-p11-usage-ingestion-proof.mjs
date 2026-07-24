#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { artifactRecord, atomicWriteJson, parseJson } from './lib/installed-ui-proof.mjs';
import {
  P11_PROOF_FILENAME,
  P11_PROOF_ROLE,
  assertP11Binding,
  buildP11Proof,
  validateP11InstalledSession,
  validateP11Proof
} from './lib/p11-usage-ingestion-proof.mjs';
import { readRegularSnapshot, SUPPORT_ENVIRONMENTS } from './lib/product-proof-closure.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

function currentHead(repoRoot) {
  const result = spawnSync('git', ['rev-parse', '--verify', 'HEAD'], { cwd: repoRoot, encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`unable to resolve checkout HEAD: ${(result.stderr || '').trim()}`);
  return result.stdout.trim();
}

function contained(repoRoot, candidate, label) {
  const root = fs.realpathSync(repoRoot);
  const absolute = fs.realpathSync(candidate);
  const relative = path.relative(root, absolute);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) throw new Error(`${label} must remain inside the repository`);
  return { root, absolute };
}

export function captureP11UsageIngestionProof({
  inputRoot, sessionReport, environmentId, targetHead, candidateRunId,
  candidateArtifactDigest, packageVersion, manifestSha256, manifestSignatureSha256,
  repoRoot = DEFAULT_REPO_ROOT, resolveHead = currentHead, now = () => new Date()
}) {
  const binding = { repoRoot, environmentId, targetHead, candidateRunId: String(candidateRunId), candidateArtifactDigest, packageVersion, manifestSha256, manifestSignatureSha256 };
  assertP11Binding(binding);
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId)) throw new Error('P-11 environment is unsupported');
  const rootInfo = contained(repoRoot, inputRoot, 'P-11 input root');
  const reportInfo = contained(repoRoot, sessionReport, 'P-11 session report');
  binding.repoRoot = rootInfo.root;
  if (resolveHead(rootInfo.root) !== targetHead) throw new Error('P-11 target HEAD does not match checkout HEAD');
  const sessionRecord = artifactRecord(rootInfo.root, reportInfo.absolute, 'P-11', environmentId, 'P-11 session report');
  const sessionSnapshot = readRegularSnapshot(rootInfo.root, sessionRecord.path, 'P-11 session report');
  const validated = validateP11InstalledSession(parseJson(sessionSnapshot.bytes, 'P-11 session report'), binding, { repoRoot: rootInfo.root });
  const collectedAt = now().toISOString();
  const proof = buildP11Proof({ session: validated.document, sessionRecord, collectedAt });
  const output = path.join(rootInfo.absolute, 'feature-artifacts', P11_PROOF_FILENAME);
  const registration = path.join(rootInfo.absolute, 'feature-proof-registration.json');
  fs.rmSync(output, { force: true });
  fs.rmSync(registration, { force: true });
  atomicWriteJson(output, proof);
  const proofRecord = artifactRecord(rootInfo.root, output, 'P-11', environmentId, 'P-11 emitted proof');
  validateP11Proof({ repoRoot: rootInfo.root, snapshot: readRegularSnapshot(rootInfo.root, proofRecord.path, 'P-11 emitted proof'), ...binding });
  atomicWriteJson(registration, {
    schemaVersion: 1,
    requirementId: 'P-11',
    environmentId,
    artifacts: [{ role: P11_PROOF_ROLE, path: `feature-artifacts/${P11_PROOF_FILENAME}` }]
  });
  return { output, registration, document: proof };
}

function args(argv) {
  const flags = ['--input-root', '--session-report', '--environment', '--target-head', '--candidate-run-id', '--candidate-artifact-digest', '--package-version', '--manifest-sha256', '--manifest-signature-sha256'];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (!flags.includes(argv[index]) || values.has(argv[index]) || argv[index + 1] === undefined) throw new Error(`invalid argument: ${argv[index] ?? '<missing>'}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const flag of flags) if (!values.has(flag)) throw new Error(`${flag} is required`);
  return {
    inputRoot: values.get('--input-root'), sessionReport: values.get('--session-report'), environmentId: values.get('--environment'),
    targetHead: values.get('--target-head'), candidateRunId: values.get('--candidate-run-id'), candidateArtifactDigest: values.get('--candidate-artifact-digest'),
    packageVersion: values.get('--package-version'), manifestSha256: values.get('--manifest-sha256'), manifestSignatureSha256: values.get('--manifest-signature-sha256')
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = captureP11UsageIngestionProof(args(process.argv.slice(2)));
    process.stdout.write(`${JSON.stringify({ output: result.output, registration: result.registration }, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`P-11 usage-ingestion capture failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
