#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  canonicalProofPath,
  P39_CONTRACT_SCHEMA_VERSION,
  P39_PROOF_ID,
  P39_REQUIREMENT_ID,
  proofReport,
  removeStaleP39Proof,
  validateBoundArtifact,
  validateIgnorePaths,
  validateP39DifferentialProof
} from './lib/p39-differential-proof.mjs';
import { readRegularSnapshot } from './lib/product-proof-closure.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const HEAD = /^[a-f0-9]{40,64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;
const VERSION = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;

function parseArguments(argv) {
  const required = new Set([
    '--input-root', '--macos', '--linux', '--environment', '--target-head', '--version',
    '--candidate-run-id', '--candidate-artifact-digest'
  ]);
  const values = new Map();
  const ignoredPaths = [];
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag === '--ignore') {
      const value = argv[index + 1];
      if (value === undefined || value.startsWith('--')) throw new Error('--ignore requires a value');
      ignoredPaths.push(value);
      index += 1;
      continue;
    }
    if (!required.has(flag) || values.has(flag)) throw new Error(`invalid argument: ${flag ?? '<missing>'}`);
    const value = argv[index + 1];
    if (value === undefined || value.startsWith('--')) throw new Error(`${flag} requires a value`);
    values.set(flag, value);
    index += 1;
  }
  for (const flag of required) if (!values.has(flag)) throw new Error(`${flag} is required`);
  if (!HEAD.test(values.get('--target-head'))) throw new Error('--target-head must be a commit id');
  if (!VERSION.test(values.get('--version'))) throw new Error('--version must be a semver release version');
  if (!RUN_ID.test(values.get('--candidate-run-id'))) throw new Error('--candidate-run-id must be a positive integer');
  if (!DIGEST.test(values.get('--candidate-artifact-digest'))) throw new Error('--candidate-artifact-digest must be a SHA-256 digest');
  return {
    inputRoot: values.get('--input-root'),
    macos: values.get('--macos'),
    linux: values.get('--linux'),
    environmentId: values.get('--environment'),
    targetHead: values.get('--target-head'),
    version: values.get('--version'),
    candidateRunId: values.get('--candidate-run-id'),
    candidateArtifactDigest: values.get('--candidate-artifact-digest'),
    ignoredPaths: validateIgnorePaths(ignoredPaths)
  };
}

function assertInside(root, candidate, label) {
  const relative = path.relative(root, candidate);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} must be inside the requirement evidence root`);
  }
}

function sourceSnapshot(root, repository, file, label) {
  const lexical = fs.realpathSync(path.resolve(file));
  assertInside(root, lexical, label);
  const relative = path.relative(root, lexical).split(path.sep).join('/');
  const snapshot = readRegularSnapshot(root, relative, label);
  return {
    snapshot,
    record: {
      path: path.relative(repository, snapshot.absolute).split(path.sep).join('/'),
      sha256: snapshot.sha256,
      size: snapshot.size
    }
  };
}

function writeJsonAtomic(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}`;
  const bytes = Buffer.from(`${JSON.stringify(value, null, 2)}\n`, 'utf8');
  try {
    const descriptor = fs.openSync(temporary, 'wx', 0o600);
    try {
      fs.writeFileSync(descriptor, bytes);
      fs.fsyncSync(descriptor);
    } finally {
      fs.closeSync(descriptor);
    }
    fs.renameSync(temporary, file);
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

function resolveHead(repository) {
  const result = spawnSync('git', ['rev-parse', '--verify', 'HEAD'], {
    cwd: repository,
    encoding: 'utf8'
  });
  if (result.status !== 0) throw new Error(`unable to resolve checkout HEAD: ${(result.stderr || '').trim()}`);
  return result.stdout.trim();
}

export function captureP39Differential({
  repoRoot = DEFAULT_REPO_ROOT,
  inputRoot,
  macos,
  linux,
  environmentId,
  targetHead,
  version,
  candidateRunId,
  candidateArtifactDigest,
  ignoredPaths = [],
  resolveHead: resolveHeadOverride = null
}) {
  const repository = fs.realpathSync(repoRoot);
  const root = fs.realpathSync(inputRoot);
  assertInside(repository, root, 'P-39 input root');
  if (!HEAD.test(targetHead ?? '')) throw new Error('P-39 target head must be a commit id');
  if (!VERSION.test(version ?? '')) throw new Error('P-39 version must be a semver release version');
  if (!RUN_ID.test(String(candidateRunId ?? ''))) throw new Error('P-39 candidate run id must be a positive integer');
  if (!DIGEST.test(candidateArtifactDigest ?? '')) throw new Error('P-39 candidate artifact digest must be a SHA-256 digest');
  const ignored = validateIgnorePaths(ignoredPaths);
  removeStaleP39Proof(root);
  const reportPath = path.join(root, 'platform-differential/report.json');
  fs.rmSync(reportPath, { force: true });
  try {
    const currentHead = resolveHeadOverride ? resolveHeadOverride() : resolveHead(repository);
    if (currentHead !== targetHead) throw new Error('P-39 capture checkout is not the requested target HEAD');
    const macosSource = sourceSnapshot(root, repository, macos, 'P-39 macOS artifact');
    const linuxSource = sourceSnapshot(root, repository, linux, 'P-39 Linux artifact');
    const macosArtifact = validateBoundArtifact(JSON.parse(macosSource.snapshot.bytes.toString('utf8')), {
      targetHead, version, candidateRunId, candidateArtifactDigest
    });
    const linuxArtifact = validateBoundArtifact(JSON.parse(linuxSource.snapshot.bytes.toString('utf8')), {
      targetHead, version, candidateRunId, candidateArtifactDigest
    });
    const report = proofReport({ macos: macosArtifact, linux: linuxArtifact, ignoredPaths: ignored });
    if (report.status !== 'exact_match') {
      throw new Error(`P-39 differential comparison found ${report.differences.length} unapproved difference(s)`);
    }
    writeJsonAtomic(reportPath, report);
    const reportSnapshot = readRegularSnapshot(root, 'platform-differential/report.json', 'P-39 differential report');
    const document = {
      schemaVersion: 1,
      id: P39_PROOF_ID,
      generatedAt: new Date().toISOString(),
      requirementId: P39_REQUIREMENT_ID,
      environmentId,
      targetHead,
      version,
      candidate: { runId: String(candidateRunId), artifactDigest: candidateArtifactDigest },
      contract: { schemaVersion: P39_CONTRACT_SCHEMA_VERSION, ignoredPaths: ignored },
      macos: macosSource.record,
      linux: linuxSource.record,
      report: {
        path: path.relative(repository, reportSnapshot.absolute).split(path.sep).join('/'),
        sha256: reportSnapshot.sha256,
        size: reportSnapshot.size
      },
      status: 'passed'
    };
    writeJsonAtomic(canonicalProofPath(root), document);
    const proofSnapshot = readRegularSnapshot(root, 'p39-differential-proof.json', 'P-39 differential proof');
    validateP39DifferentialProof({
      repoRoot: repository,
      snapshot: proofSnapshot,
      targetHead,
      environmentId,
      version,
      candidateRunId,
      candidateArtifactDigest
    });
    return { output: proofSnapshot.absolute, report: reportSnapshot.absolute, document };
  } catch (error) {
    fs.rmSync(reportPath, { force: true });
    removeStaleP39Proof(root);
    throw error;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = parseArguments(process.argv.slice(2));
    const result = captureP39Differential({
      ...args,
      inputRoot: path.resolve(args.inputRoot),
      macos: path.resolve(args.macos),
      linux: path.resolve(args.linux)
    });
    process.stdout.write(`${JSON.stringify({ output: result.output, report: result.report, status: result.document.status }, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`P-39 differential capture failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
