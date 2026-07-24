#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  P08_PROOF_FILENAME,
  P08_PROOF_ROLE,
  P08_SESSION_FILENAME,
  canonicalP08SourceEvidence,
  sha256P08,
  validateP08InstalledMediaSession,
  validateP08MercuryMediaProof
} from './lib/p08-mercury-media-proof.mjs';
import { readRegularSnapshot, SUPPORT_ENVIRONMENTS } from './lib/product-proof-closure.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const HEAD = /^[a-f0-9]{40,64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;

function atomicWrite(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
  fs.renameSync(temporary, file);
}

function assertInside(root, candidate, label) {
  const relative = path.relative(root, candidate);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} must remain inside the repository`);
  }
}

function assertNoSymlink(root, candidate, label) {
  const relative = path.relative(root, candidate);
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

export function captureP08MercuryMediaProof({
  inputRoot,
  sessionReport,
  environmentId,
  targetHead,
  candidateRunId,
  candidateArtifactDigest,
  repoRoot = DEFAULT_REPO_ROOT,
  resolveHead = currentHead
}) {
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId)) throw new Error(`unknown support environment: ${environmentId}`);
  if (!HEAD.test(targetHead) || !RUN_ID.test(String(candidateRunId)) || !DIGEST.test(candidateArtifactDigest)) {
    throw new Error('P-08 candidate binding is invalid');
  }
  const repository = fs.realpathSync(repoRoot);
  const root = path.resolve(inputRoot);
  const source = path.resolve(sessionReport);
  assertInside(repository, root, 'P-08 input root');
  assertInside(repository, source, 'P-08 session report');
  assertNoSymlink(repository, root, 'P-08 input root');
  assertNoSymlink(repository, source, 'P-08 session report');
  if (path.dirname(source) !== root || path.basename(source) !== P08_SESSION_FILENAME) {
    throw new Error(`P-08 session report must be ${P08_SESSION_FILENAME} at the input root`);
  }
  if (resolveHead(repository) !== targetHead) throw new Error('P-08 target head does not match checkout HEAD');
  const sourceRelative = path.relative(repository, source).split(path.sep).join('/');
  const sessionSnapshot = readRegularSnapshot(repository, sourceRelative, 'P-08 installed media session');
  let observed;
  try { observed = JSON.parse(sessionSnapshot.bytes.toString('utf8')); } catch (error) { throw new Error(`P-08 session is not JSON: ${error.message}`); }
  const binding = { environmentId, targetHead, candidateRunId, candidateArtifactDigest };
  validateP08InstalledMediaSession(observed, binding, { repoRoot: repository });
  const document = {
    schemaVersion: 1,
    requirementId: 'P-08',
    environmentId,
    targetHead,
    candidate: structuredClone(observed.candidate),
    source: {
      method: 'installed-linux-physical-device-session',
      path: sourceRelative,
      sha256: sessionSnapshot.sha256
    },
    sourceEvidence: canonicalP08SourceEvidence(repository),
    observed,
    passed: true
  };
  const output = path.join(root, 'feature-artifacts', P08_PROOF_FILENAME);
  const registration = path.join(root, 'feature-proof-registration.json');
  fs.rmSync(output, { force: true });
  fs.rmSync(registration, { force: true });
  atomicWrite(output, document);
  const proofSnapshot = readRegularSnapshot(repository, path.relative(repository, output).split(path.sep).join('/'), 'P-08 Mercury media proof');
  validateP08MercuryMediaProof({
    repoRoot: repository,
    snapshot: proofSnapshot,
    sourceSnapshot: sessionSnapshot,
    environmentId,
    targetHead,
    candidateRunId,
    candidateArtifactDigest
  });
  const registrationDocument = {
    schemaVersion: 1,
    requirementId: 'P-08',
    environmentId,
    artifacts: [{ role: P08_PROOF_ROLE, path: `feature-artifacts/${P08_PROOF_FILENAME}` }]
  };
  atomicWrite(registration, registrationDocument);
  return { document, output, registration, sha256: sha256P08(proofSnapshot.bytes) };
}

function parseArguments(argv) {
  const allowed = new Set([
    '--input-root', '--session-report', '--environment', '--target-head',
    '--candidate-run-id', '--candidate-artifact-digest'
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    if (!allowed.has(flag) || argv[index + 1] === undefined || values.has(flag)) {
      throw new Error(`invalid argument: ${flag ?? '<missing>'}`);
    }
    values.set(flag, argv[index + 1]);
  }
  for (const flag of allowed) if (!values.has(flag)) throw new Error(`${flag} is required`);
  return {
    inputRoot: values.get('--input-root'),
    sessionReport: values.get('--session-report'),
    environmentId: values.get('--environment'),
    targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'),
    candidateArtifactDigest: values.get('--candidate-artifact-digest')
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = captureP08MercuryMediaProof(parseArguments(process.argv.slice(2)));
    process.stdout.write(`${JSON.stringify({ output: result.output, registration: result.registration })}\n`);
  } catch (error) {
    process.stderr.write(`P-08 Mercury media capture failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
