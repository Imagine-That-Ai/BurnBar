#!/usr/bin/env node
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  P40_PROOF_FILENAME,
  P40_PROOF_ROLE,
  buildP40Proof,
  parseP40Json,
  validateP40LiveSession,
  validateP40PrivacyProof
} from './lib/p40-privacy-proof.mjs';
import { readRegularSnapshot } from './lib/product-proof-closure.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const HEAD = /^[a-f0-9]{40,64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;

function assertInside(root, candidate, label) {
  const relative = path.relative(root, candidate);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} must be inside the evidence root`);
  }
}

function assertNoSymlinkComponents(root, candidate, label) {
  let current = root;
  for (const component of path.relative(root, candidate).split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink()) throw new Error(`${label} traverses a symlink`);
  }
}

function readEvidenceFile(file, root, repository, label) {
  const lexical = path.resolve(file);
  assertInside(root, lexical, label);
  const relative = path.relative(root, lexical).split(path.sep).join('/');
  const snapshot = readRegularSnapshot(root, relative, label);
  return {
    bytes: snapshot.bytes,
    path: path.relative(repository, lexical).split(path.sep).join('/'),
    relative
  };
}

function validateEvidenceArtifacts(session, inputRoot) {
  const paths = new Set();
  for (const observation of Object.values(session.observations)) {
    for (const evidencePath of observation.evidencePaths ?? []) paths.add(evidencePath);
  }
  for (const evidencePath of paths) {
    const absolute = path.resolve(inputRoot, evidencePath);
    assertInside(inputRoot, absolute, `P-40 evidence artifact ${evidencePath}`);
    let stat;
    try {
      stat = fs.lstatSync(absolute);
    } catch {
      throw new Error(`P-40 evidence artifact is missing: ${evidencePath}`);
    }
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size === 0) {
      throw new Error(`P-40 evidence artifact is not a non-empty regular file: ${evidencePath}`);
    }
  }
}

function atomicWrite(file, bytes) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(temporary, bytes, { mode: 0o600, flag: 'wx' });
  fs.renameSync(temporary, file);
}

function removeStale(root) {
  fs.rmSync(path.join(root, 'feature-artifacts', P40_PROOF_FILENAME), { force: true });
  fs.rmSync(path.join(root, 'feature-proof-registration.json'), { force: true });
}

function currentHead(repository) {
  const result = spawnSync('git', ['rev-parse', '--verify', 'HEAD'], { cwd: repository, encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`unable to resolve checkout HEAD: ${(result.stderr || '').trim()}`);
  return result.stdout.trim();
}

export function captureP40PrivacyProof({
  repoRoot = DEFAULT_REPO_ROOT,
  inputRoot,
  sessionReport,
  environmentId,
  targetHead,
  candidateRunId,
  candidateArtifactDigest,
  resolveHead = null
}) {
  if (!HEAD.test(targetHead ?? '')) throw new Error('P-40 target head must be a commit id');
  if (!RUN_ID.test(String(candidateRunId ?? ''))) throw new Error('P-40 candidate run id must be a positive integer');
  if (!DIGEST.test(candidateArtifactDigest ?? '')) throw new Error('P-40 candidate artifact digest must be a SHA-256 digest');
  const repository = fs.realpathSync(repoRoot);
  const lexicalRoot = path.resolve(inputRoot);
  assertInside(repository, lexicalRoot, 'P-40 input root');
  assertNoSymlinkComponents(repository, lexicalRoot, 'P-40 input root');
  const root = fs.realpathSync(lexicalRoot);
  removeStale(root);
  const resolvedHead = resolveHead ? resolveHead() : currentHead(repository);
  if (resolvedHead !== targetHead) throw new Error(`P-40 capture target head ${targetHead} does not match checkout HEAD ${resolvedHead}`);

  const source = readEvidenceFile(sessionReport, root, repository, 'P-40 live session report');
  const session = parseP40Json(source.bytes, 'P-40 live session report');
  validateP40LiveSession(session, { environmentId, targetHead, candidateRunId, candidateArtifactDigest });
  validateEvidenceArtifacts(session, root);
  const document = buildP40Proof({
    session,
    sourcePath: source.path,
    sourceSha256: source.bytes.length === 0 ? '' : readRegularSnapshot(root, source.relative, 'P-40 live session report').sha256,
    repoRoot: repository
  });
  const output = path.join(root, 'feature-artifacts', P40_PROOF_FILENAME);
  const registrationPath = path.join(root, 'feature-proof-registration.json');
  atomicWrite(output, Buffer.from(`${JSON.stringify(document, null, 2)}\n`));
  const snapshot = readRegularSnapshot(root, `feature-artifacts/${P40_PROOF_FILENAME}`, 'P-40 privacy proof');
  validateP40PrivacyProof({
    repoRoot: repository,
    snapshot,
    targetHead,
    environmentId,
    candidateRunId,
    candidateArtifactDigest
  });
  const registration = {
    schemaVersion: 1,
    requirementId: 'P-40',
    environmentId,
    artifacts: [{ role: P40_PROOF_ROLE, path: `feature-artifacts/${P40_PROOF_FILENAME}` }]
  };
  atomicWrite(registrationPath, Buffer.from(`${JSON.stringify(registration, null, 2)}\n`));
  return { output, registration: registrationPath, document };
}

function parseArguments(argv) {
  const allowed = new Set([
    '--input-root', '--session-report', '--environment', '--target-head',
    '--candidate-run-id', '--candidate-artifact-digest'
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
    inputRoot: path.resolve(values.get('--input-root')),
    sessionReport: path.resolve(values.get('--session-report')),
    environmentId: values.get('--environment'),
    targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'),
    candidateArtifactDigest: values.get('--candidate-artifact-digest')
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = captureP40PrivacyProof(parseArguments(process.argv.slice(2)));
    process.stdout.write(`${JSON.stringify({ output: result.output, registration: result.registration }, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`P-40 privacy capture failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
