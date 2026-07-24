#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { artifactRecord, atomicWriteJson } from './lib/installed-ui-proof.mjs';
import {
  P14_PROOF_FILENAME,
  P14_PROOF_ROLE,
  buildP14Proof,
  validateP14InstalledSession,
  validateP14Proof
} from './lib/p14-chat-proof.mjs';
import { readRegularSnapshot } from './lib/product-proof-closure.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

export function captureP14ChatProof(options) {
  const root = fs.realpathSync(options.repoRoot ?? ROOT);
  const input = fs.realpathSync(options.inputRoot);
  const report = fs.realpathSync(options.sessionReport);
  const resolveHead = options.resolveHead ?? ((repoRoot) => {
    const result = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: repoRoot, encoding: 'utf8' });
    if (result.error || result.status !== 0) throw new Error('P-14 could not resolve repository HEAD');
    return result.stdout.trim();
  });
  if (resolveHead(root) !== options.targetHead) throw new Error('P-14 HEAD mismatch');
  const source = artifactRecord(root, report, 'P-14', options.environmentId, 'P-14 session');
  const binding = { ...options, repoRoot: root, candidateRunId: String(options.candidateRunId) };
  const session = validateP14InstalledSession(JSON.parse(fs.readFileSync(report, 'utf8')), binding, { repoRoot: root });
  const collectedAt = (options.now ?? (() => new Date()))().toISOString();
  const proof = buildP14Proof({ session: session.document, source, collectedAt });
  const output = path.join(input, 'feature-artifacts', P14_PROOF_FILENAME);
  const registration = path.join(input, 'feature-proof-registration.json');
  fs.rmSync(output, { force: true });
  fs.rmSync(registration, { force: true });
  atomicWriteJson(output, proof);
  const proofRecord = artifactRecord(root, output, 'P-14', options.environmentId, 'P-14 proof');
  validateP14Proof({ repoRoot: root, snapshot: readRegularSnapshot(root, proofRecord.path, 'P-14 proof'), ...binding });
  atomicWriteJson(registration, {
    schemaVersion: 1,
    requirementId: 'P-14',
    environmentId: options.environmentId,
    artifacts: [{ role: P14_PROOF_ROLE, path: `feature-artifacts/${P14_PROOF_FILENAME}` }]
  });
  return { output, registration };
}

export function parseP14CaptureArguments(argv) {
  const flags = ['--input-root', '--session-report', '--environment', '--target-head', '--candidate-run-id',
    '--candidate-artifact-digest', '--package-version', '--manifest-sha256', '--manifest-signature-sha256'];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    if (!flags.includes(flag) || values.has(flag) || argv[index + 1] === undefined) throw new Error(`invalid argument: ${flag ?? '<missing>'}`);
    values.set(flag, argv[index + 1]);
  }
  for (const flag of flags) if (!values.has(flag)) throw new Error(`${flag} is required`);
  return { inputRoot: values.get('--input-root'), sessionReport: values.get('--session-report'),
    environmentId: values.get('--environment'), targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'), candidateArtifactDigest: values.get('--candidate-artifact-digest'),
    packageVersion: values.get('--package-version'), manifestSha256: values.get('--manifest-sha256'),
    manifestSignatureSha256: values.get('--manifest-signature-sha256') };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.stdout.write(`${JSON.stringify(captureP14ChatProof(parseP14CaptureArguments(process.argv.slice(2))))}\n`); }
  catch (error) { process.stderr.write(`P-14 capture failed: ${error.message}\n`); process.exitCode = 1; }
}
