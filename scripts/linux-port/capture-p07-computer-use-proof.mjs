#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  P07_PROOF_FILENAME,
  P07_PROOF_ID,
  P07_PROOF_ROLE,
  P07_REQUIREMENT_ID,
  validateP07CandidateSession
} from './lib/p07-computer-use-capture.mjs';
import { readRegularSnapshot } from './lib/product-proof-closure.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

function currentHead(repoRoot) {
  const result = spawnSync('git', ['rev-parse', '--verify', 'HEAD'], { cwd: repoRoot, encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`unable to resolve checkout HEAD: ${(result.stderr || '').trim()}`);
  return result.stdout.trim();
}

function assertInside(root, candidate, label) {
  const relative = path.relative(root, candidate);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} must be inside the repository`);
  }
}

function atomicWriteJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
  fs.renameSync(temporary, file);
}

function parseJson(snapshot, label) {
  try {
    return JSON.parse(snapshot.bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function canonicalInputRoot(repoRoot, environmentId) {
  return path.join(repoRoot, 'docs/linux-port/evidence/product-parity-inputs/P-07', environmentId);
}

function clearOutputs(inputRoot) {
  fs.rmSync(path.join(inputRoot, 'feature-artifacts', P07_PROOF_FILENAME), { force: true });
  fs.rmSync(path.join(inputRoot, 'feature-proof-registration.json'), { force: true });
}

export function captureP07ComputerUseProof({
  repoRoot = DEFAULT_REPO_ROOT,
  inputRoot,
  sessionReport,
  environmentId,
  targetHead,
  candidateRunId,
  candidateArtifactDigest,
  resolveHead = currentHead
}) {
  const repository = fs.realpathSync(repoRoot);
  const root = fs.realpathSync(inputRoot);
  assertInside(repository, root, 'P-07 input root');
  if (root !== fs.realpathSync(canonicalInputRoot(repository, environmentId))) {
    throw new Error('P-07 input root must be the canonical requirement/environment directory');
  }
  clearOutputs(root);
  if (resolveHead(repository) !== targetHead) throw new Error('P-07 capture checkout is not the requested target HEAD');
  const sessionAbsolute = path.resolve(sessionReport);
  assertInside(root, sessionAbsolute, 'P-07 session report');
  const sessionRelative = path.relative(root, sessionAbsolute).split(path.sep).join('/');
  const sessionSnapshot = readRegularSnapshot(root, sessionRelative, 'P-07 candidate session report');
  const session = parseJson(sessionSnapshot, 'P-07 candidate session report');
  const validated = validateP07CandidateSession({
    session,
    repoRoot: repository,
    inputRoot: root,
    environmentId,
    targetHead,
    candidateRunId,
    candidateArtifactDigest
  });
  const proof = {
    schemaVersion: 1,
    id: P07_PROOF_ID,
    requirementId: P07_REQUIREMENT_ID,
    environmentId,
    targetHead,
    candidate: structuredClone(session.candidate),
    capture: structuredClone(session.capture),
    source: {
      method: 'candidate-bound-installed-native-session',
      path: path.relative(repository, sessionSnapshot.absolute).split(path.sep).join('/'),
      sha256: sessionSnapshot.sha256,
      size: sessionSnapshot.size
    },
    targetIds: [...session.targetIds],
    rejectionPolicy: structuredClone(session.rejectionPolicy),
    targets: structuredClone(session.targets),
    failedTargets: [],
    sourceEvidence: validated.sourceEvidence
  };
  const relativeOutput = `feature-artifacts/${P07_PROOF_FILENAME}`;
  const output = path.join(root, relativeOutput);
  atomicWriteJson(output, proof);
  const outputSnapshot = readRegularSnapshot(root, relativeOutput, 'P-07 feature proof');
  const emitted = parseJson(outputSnapshot, 'P-07 feature proof');
  validateP07CandidateSession({
    session: { ...emitted, id: 'openburnbar-linux-computer-use-session-v1' },
    repoRoot: repository,
    inputRoot: root,
    environmentId,
    targetHead,
    candidateRunId,
    candidateArtifactDigest
  });
  const registration = {
    schemaVersion: 1,
    requirementId: P07_REQUIREMENT_ID,
    environmentId,
    artifacts: [{ role: P07_PROOF_ROLE, path: relativeOutput }]
  };
  const registrationPath = path.join(root, 'feature-proof-registration.json');
  atomicWriteJson(registrationPath, registration);
  return { output, registration: registrationPath, proof, sha256: outputSnapshot.sha256 };
}

function parseArguments(argv) {
  const allowed = new Set([
    '--input-root', '--session-report', '--environment', '--target-head',
    '--candidate-run-id', '--candidate-artifact-digest'
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (!allowed.has(argv[index]) || argv[index + 1] === undefined || values.has(argv[index])) {
      throw new Error(`invalid argument: ${argv[index] ?? '<missing>'}`);
    }
    values.set(argv[index], argv[index + 1]);
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
    const result = captureP07ComputerUseProof(parseArguments(process.argv.slice(2)));
    process.stdout.write(`${JSON.stringify({ output: result.output, registration: result.registration })}\n`);
  } catch (error) {
    process.stderr.write(`P-07 computer-use capture failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
