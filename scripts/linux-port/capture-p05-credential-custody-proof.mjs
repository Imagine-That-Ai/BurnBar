#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  P05_PROOF_FILENAME,
  P05_PROOF_ROLE,
  P05_SESSION_FILENAME,
  canonicalP05SourceEvidence,
  sha256P05,
  validateP05CredentialCustodyProof,
  validateP05InstalledCustodySession
} from './lib/p05-credential-custody-proof.mjs';
import { readRegularSnapshot, SUPPORT_ENVIRONMENTS } from './lib/product-proof-closure.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const HEAD = /^[a-f0-9]{40,64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;

function atomicWrite(file, bytes) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(temporary, bytes, { mode: 0o600, flag: 'wx' });
  fs.renameSync(temporary, file);
}

function assertInside(repository, absolutePath, label) {
  const relative = path.relative(repository, absolutePath);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} must be inside the repository`);
  }
  let current = repository;
  for (const component of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    if (fs.lstatSync(current).isSymbolicLink()) throw new Error(`${label} traverses a symlink`);
  }
}

function currentHead(repoRoot) {
  const result = spawnSync('git', ['rev-parse', '--verify', 'HEAD'], { cwd: repoRoot, encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`unable to resolve checkout HEAD: ${(result.stderr || '').trim()}`);
  return result.stdout.trim();
}

export function captureP05CredentialCustodyProof({
  inputRoot, sessionReport, environmentId, targetHead, candidateRunId,
  candidateArtifactDigest, repoRoot = DEFAULT_REPO_ROOT, resolveHead = currentHead
}) {
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId)) throw new Error(`unknown support environment: ${environmentId}`);
  if (!HEAD.test(targetHead) || !RUN_ID.test(String(candidateRunId)) || !DIGEST.test(candidateArtifactDigest)) {
    throw new Error('P-05 candidate binding is invalid');
  }
  const repository = fs.realpathSync(repoRoot);
  const lexicalRoot = path.resolve(inputRoot);
  const lexicalSession = path.resolve(sessionReport);
  assertInside(repository, lexicalRoot, 'P-05 input root');
  assertInside(repository, lexicalSession, 'P-05 session report');
  const root = fs.realpathSync(lexicalRoot);
  if (path.dirname(lexicalSession) !== root || path.basename(lexicalSession) !== P05_SESSION_FILENAME) {
    throw new Error(`P-05 session report must be ${P05_SESSION_FILENAME} at the input root`);
  }
  if (resolveHead(repository) !== targetHead) throw new Error('P-05 target head does not match checkout HEAD');
  const sessionSnapshot = readRegularSnapshot(root, P05_SESSION_FILENAME, 'P-05 installed custody session');
  let observed;
  try { observed = JSON.parse(sessionSnapshot.bytes.toString('utf8')); } catch (error) { throw new Error(`P-05 session is not JSON: ${error.message}`); }
  validateP05InstalledCustodySession(observed, { environmentId, targetHead, candidateRunId, candidateArtifactDigest });
  const document = {
    schemaVersion: 1,
    requirementId: 'P-05',
    environmentId,
    targetHead,
    candidate: structuredClone(observed.candidate),
    capture: structuredClone(observed.capture),
    source: {
      method: 'installed-native-custody-session',
      path: path.relative(repository, lexicalSession).split(path.sep).join('/'),
      sha256: sessionSnapshot.sha256
    },
    sourceEvidence: canonicalP05SourceEvidence(repository),
    observed,
    passed: true
  };
  const output = path.join(root, 'feature-artifacts', P05_PROOF_FILENAME);
  const registration = path.join(root, 'feature-proof-registration.json');
  fs.rmSync(output, { force: true });
  fs.rmSync(registration, { force: true });
  atomicWrite(output, Buffer.from(`${JSON.stringify(document, null, 2)}\n`));
  const snapshot = readRegularSnapshot(root, `feature-artifacts/${P05_PROOF_FILENAME}`, 'P-05 custody proof');
  validateP05CredentialCustodyProof({
    repoRoot: repository, snapshot, environmentId, targetHead,
    candidateRunId, candidateArtifactDigest, sourceSnapshot: sessionSnapshot
  });
  atomicWrite(registration, Buffer.from(`${JSON.stringify({
    schemaVersion: 1,
    requirementId: 'P-05',
    environmentId,
    artifacts: [{ role: P05_PROOF_ROLE, path: `feature-artifacts/${P05_PROOF_FILENAME}` }]
  }, null, 2)}\n`));
  return { document, output, registration, sha256: sha256P05(snapshot.bytes) };
}

function parseArguments(argv) {
  const allowed = new Set(['--input-root', '--session-report', '--environment', '--target-head', '--candidate-run-id', '--candidate-artifact-digest']);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (!allowed.has(argv[index]) || argv[index + 1] === undefined || values.has(argv[index])) throw new Error(`invalid argument: ${argv[index] ?? '<missing>'}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const flag of allowed) if (!values.has(flag)) throw new Error(`${flag} is required`);
  return {
    inputRoot: values.get('--input-root'), sessionReport: values.get('--session-report'),
    environmentId: values.get('--environment'), targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'), candidateArtifactDigest: values.get('--candidate-artifact-digest')
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = captureP05CredentialCustodyProof(parseArguments(process.argv.slice(2)));
    process.stdout.write(`${JSON.stringify({ output: result.output, registration: result.registration })}\n`);
  } catch (error) {
    process.stderr.write(`P-05 credential custody capture failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
