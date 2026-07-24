#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  P06_PROOF_FILENAME,
  P06_PROOF_ROLE,
  P06_SESSION_FILENAME,
  buildP06GatewayBoundaryProof,
  normalizeEvidencePath,
  validateP06GatewayBoundaryProof,
  validateP06GatewayBoundarySession
} from './lib/p06-gateway-credential-boundary-proof.mjs';
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

function assertInside(root, candidate, label) {
  const relative = path.relative(root, candidate);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} must be inside the repository`);
  }
  let current = root;
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

export function captureP06GatewayBoundaryProof({
  inputRoot, sessionReport, environmentId, targetHead, candidateRunId,
  candidateArtifactDigest, repoRoot = DEFAULT_REPO_ROOT, resolveHead = currentHead
}) {
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId)) throw new Error(`unknown support environment: ${environmentId}`);
  if (!HEAD.test(targetHead) || !RUN_ID.test(String(candidateRunId)) || !DIGEST.test(candidateArtifactDigest)) {
    throw new Error('P-06 candidate binding is invalid');
  }
  const repository = fs.realpathSync(repoRoot);
  const lexicalRoot = path.resolve(inputRoot);
  const lexicalSession = path.resolve(sessionReport);
  assertInside(repository, lexicalRoot, 'P-06 input root');
  assertInside(repository, lexicalSession, 'P-06 session report');
  const root = fs.realpathSync(lexicalRoot);
  if (path.dirname(lexicalSession) !== root || path.basename(lexicalSession) !== P06_SESSION_FILENAME) {
    throw new Error(`P-06 session report must be ${P06_SESSION_FILENAME} at the input root`);
  }
  if (resolveHead(repository) !== targetHead) throw new Error('P-06 target head does not match checkout HEAD');
  const sessionSnapshot = readRegularSnapshot(root, P06_SESSION_FILENAME, 'P-06 gateway boundary session');
  let session;
  try { session = JSON.parse(sessionSnapshot.bytes.toString('utf8')); } catch (error) { throw new Error(`P-06 session is not JSON: ${error.message}`); }
  validateP06GatewayBoundarySession(session, { environmentId, targetHead, candidateRunId, candidateArtifactDigest });
  const document = buildP06GatewayBoundaryProof({
    session,
    sourcePath: normalizeEvidencePath(repository, lexicalSession),
    sourceSha256: sessionSnapshot.sha256,
    repoRoot: repository
  });
  const output = path.join(root, 'feature-artifacts', P06_PROOF_FILENAME);
  const registration = path.join(root, 'feature-proof-registration.json');
  fs.rmSync(output, { force: true });
  fs.rmSync(registration, { force: true });
  atomicWrite(output, Buffer.from(`${JSON.stringify(document, null, 2)}\n`));
  const snapshot = readRegularSnapshot(root, `feature-artifacts/${P06_PROOF_FILENAME}`, 'P-06 gateway boundary proof');
  validateP06GatewayBoundaryProof({
    repoRoot: repository, snapshot, environmentId, targetHead, candidateRunId,
    candidateArtifactDigest, sourceSnapshot: sessionSnapshot
  });
  atomicWrite(registration, Buffer.from(`${JSON.stringify({
    schemaVersion: 1,
    requirementId: 'P-06',
    environmentId,
    artifacts: [{ role: P06_PROOF_ROLE, path: `feature-artifacts/${P06_PROOF_FILENAME}` }]
  }, null, 2)}\n`));
  return { document, output, registration };
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
    const result = captureP06GatewayBoundaryProof(parseArguments(process.argv.slice(2)));
    process.stdout.write(`${JSON.stringify({ output: result.output, registration: result.registration })}\n`);
  } catch (error) {
    process.stderr.write(`P-06 gateway boundary capture failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
