#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  P31_REQUIREMENT_ID,
  P31_ROLES,
  buildP31Proof,
  parseP31Json,
  sha256Bytes,
  validateP31LiveSession
} from './lib/p31-accessibility-proof.mjs';
import { readRegularSnapshot } from './lib/product-proof-closure.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const HEAD = /^[a-f0-9]{40,64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;

function parseArguments(argv) {
  const allowed = new Set([
    '--input-root', '--session-report', '--environment', '--target-head',
    '--candidate-run-id', '--candidate-artifact-digest'
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag) || value === undefined || values.has(flag)) {
      throw new Error(`invalid argument: ${flag ?? '<missing>'}`);
    }
    values.set(flag, value);
  }
  for (const flag of allowed) if (!values.has(flag)) throw new Error(`${flag} is required`);
  if (!HEAD.test(values.get('--target-head'))) throw new Error('--target-head must be a commit id');
  if (!RUN_ID.test(values.get('--candidate-run-id'))) throw new Error('--candidate-run-id must be a positive integer');
  if (!DIGEST.test(values.get('--candidate-artifact-digest'))) throw new Error('--candidate-artifact-digest must be a sha256 digest');
  return {
    inputRoot: values.get('--input-root'),
    sessionReport: values.get('--session-report'),
    environmentId: values.get('--environment'),
    targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'),
    candidateArtifactDigest: values.get('--candidate-artifact-digest')
  };
}

function assertInside(root, candidate, label) {
  const relative = path.relative(root, candidate);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} must be inside the requirement evidence root`);
  }
}

function readRegular(file, root, repository, label) {
  const lexical = path.resolve(file);
  assertInside(root, lexical, label);
  const relative = path.relative(root, lexical).split(path.sep).join('/');
  const snapshot = readRegularSnapshot(root, relative, label);
  return {
    bytes: snapshot.bytes,
    path: path.relative(repository, lexical).split(path.sep).join('/')
  };
}

function writeJsonAtomic(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
  fs.renameSync(temporary, file);
}

function removeStale(root) {
  const featureDir = path.join(root, 'feature-artifacts');
  for (const role of P31_ROLES) {
    const name = role.slice('feature.'.length).replaceAll('.', '-');
    fs.rmSync(path.join(featureDir, `p31-${name}.json`), { force: true });
  }
  fs.rmSync(path.join(root, 'feature-proof-registration.json'), { force: true });
}

export function captureP31Accessibility({
  repoRoot = DEFAULT_REPO_ROOT,
  inputRoot,
  sessionReport,
  environmentId,
  targetHead,
  candidateRunId,
  candidateArtifactDigest,
  resolveHead = null
}) {
  const repository = fs.realpathSync(repoRoot);
  const root = path.resolve(inputRoot);
  const canonicalRoot = fs.realpathSync(inputRoot);
  assertInside(repository, canonicalRoot, 'P-31 input root');
  removeStale(root);

  const currentHead = resolveHead
    ? resolveHead()
    : spawnSync('git', ['rev-parse', 'HEAD'], { cwd: repository, encoding: 'utf8' }).stdout.trim();
  if (currentHead !== targetHead) throw new Error('P-31 capture checkout is not the requested target HEAD');

  const source = readRegular(sessionReport, root, path.resolve(repoRoot), 'P-31 live session report');
  const session = parseP31Json(source.bytes, 'P-31 live session report');
  validateP31LiveSession(session, { environmentId, targetHead, candidateRunId, candidateArtifactDigest });
  const sourceSha256 = sha256Bytes(source.bytes);
  const featureDir = path.join(root, 'feature-artifacts');
  const registrations = [];
  for (const role of P31_ROLES) {
    const name = role.slice('feature.'.length).replaceAll('.', '-');
    const relativePath = `feature-artifacts/p31-${name}.json`;
    const output = path.join(root, relativePath);
    const proof = buildP31Proof({ role, session, sourcePath: source.path, sourceSha256 });
    writeJsonAtomic(output, proof);
    registrations.push({ role, path: relativePath });
  }
  const registration = {
    schemaVersion: 1,
    requirementId: P31_REQUIREMENT_ID,
    environmentId,
    artifacts: registrations
  };
  writeJsonAtomic(path.join(root, 'feature-proof-registration.json'), registration);
  return {
    output: path.join(root, 'feature-proof-registration.json'),
    registration,
    source: { path: source.path, sha256: sourceSha256 },
    featureDir
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = parseArguments(process.argv.slice(2));
    const result = captureP31Accessibility({
      ...args,
      inputRoot: path.resolve(args.inputRoot),
      sessionReport: path.resolve(args.sessionReport)
    });
    process.stdout.write(`${JSON.stringify({
      output: path.relative(DEFAULT_REPO_ROOT, result.output),
      requirementId: result.registration.requirementId,
      artifactCount: result.registration.artifacts.length
    }, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`P-31 accessibility capture failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
