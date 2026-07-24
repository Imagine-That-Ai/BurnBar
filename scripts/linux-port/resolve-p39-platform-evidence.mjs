#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  P39_ARTIFACT_ID,
  validateBoundArtifact
} from './lib/p39-differential-proof.mjs';
import { validateP39ProducerArtifact } from './capture-p39-platform-evidence.mjs';
import { readRegularSnapshot } from './lib/product-proof-closure.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const HEAD = /^[a-f0-9]{40,64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;
const VERSION = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;

export const P39_PLATFORM_INPUT_FILENAMES = Object.freeze({
  macos: 'macos-platform-evidence.json',
  linux: 'linux-platform-evidence.json'
});
export const P39_AGGREGATE_PATH = '.linux-release/product-proof-closure.json';

function parseArguments(argv) {
  const expected = new Set([
    '--input-root', '--target-head', '--candidate-run-id', '--candidate-artifact-digest'
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!expected.has(flag) || values.has(flag)) throw new Error(`invalid argument: ${flag ?? '<missing>'}`);
    if (value === undefined || value.startsWith('--')) throw new Error(`${flag} requires a value`);
    values.set(flag, value);
  }
  for (const flag of expected) if (!values.has(flag)) throw new Error(`${flag} is required`);
  if (!HEAD.test(values.get('--target-head'))) throw new Error('--target-head must be a commit id');
  if (!RUN_ID.test(values.get('--candidate-run-id'))) {
    throw new Error('--candidate-run-id must be a positive integer');
  }
  if (!DIGEST.test(values.get('--candidate-artifact-digest'))) {
    throw new Error('--candidate-artifact-digest must be a SHA-256 digest');
  }
  return {
    inputRoot: values.get('--input-root'),
    targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'),
    candidateArtifactDigest: values.get('--candidate-artifact-digest')
  };
}

function assertDirectory(root, label) {
  const resolved = fs.realpathSync(root);
  const stat = fs.statSync(resolved);
  if (!stat.isDirectory()) throw new Error(`${label} must be a directory`);
  return resolved;
}

function walkRegularFiles(root) {
  const matches = [];
  const visit = (directory) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const candidate = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) {
        throw new Error(`P-39 candidate evidence contains a symbolic link: ${path.relative(root, candidate)}`);
      }
      if (entry.isDirectory()) visit(candidate);
      else if (entry.isFile()) matches.push(candidate);
    }
  };
  visit(root);
  return matches;
}

function parseJsonFile(file, label) {
  let value;
  try {
    value = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
  return value;
}

function resolveSingleInput(repository, root, role, targetHead, version, candidateRunId, candidateArtifactDigest) {
  const filename = P39_PLATFORM_INPUT_FILENAMES[role];
  const candidates = walkRegularFiles(root).filter((file) => path.basename(file) === filename);
  if (candidates.length === 0) {
    // Keep producer absence explicit so a missing platform run cannot be
    // mistaken for a passing differential proof or replaced with a fixture.
    throw new Error(
      `P-39 platform evidence producer is absent: candidate artifact is missing ${filename}; `
      + 'the workflow cannot synthesize macOS/Linux evidence'
    );
  }
  if (candidates.length !== 1) {
    throw new Error(`P-39 requires exactly one ${filename}; found ${candidates.length}`);
  }
  const file = candidates[0];
  const artifact = parseJsonFile(file, `P-39 ${role} platform evidence`);
  validateBoundArtifact(artifact, {
    targetHead,
    version,
    candidateRunId,
    candidateArtifactDigest
  });
  validateP39ProducerArtifact(artifact, { repoRoot: repository, platform: role });
  return file;
}

export function resolveP39PlatformEvidence({
  repoRoot = DEFAULT_REPO_ROOT,
  inputRoot,
  targetHead,
  candidateRunId,
  candidateArtifactDigest
}) {
  const repository = fs.realpathSync(repoRoot);
  const root = assertDirectory(inputRoot, 'P-39 input root');
  const rootRelative = path.relative(repository, root);
  if (rootRelative === '..' || rootRelative.startsWith(`..${path.sep}`) || path.isAbsolute(rootRelative)) {
    throw new Error('P-39 input root must be inside the repository');
  }
  const aggregate = parseJsonFile(
    readRegularSnapshot(root, P39_AGGREGATE_PATH, 'P-39 aggregate product proof closure').absolute,
    'P-39 aggregate product proof closure'
  );
  if (!VERSION.test(aggregate?.version ?? '')) {
    throw new Error('P-39 aggregate product proof closure has no strict release version');
  }
  if (aggregate.targetHead !== targetHead) {
    throw new Error('P-39 aggregate product proof closure target does not match the requested HEAD');
  }
  const version = aggregate.version;
  const macos = resolveSingleInput(
    repository, root, 'macos', targetHead, version, candidateRunId, candidateArtifactDigest
  );
  const linux = resolveSingleInput(
    repository, root, 'linux', targetHead, version, candidateRunId, candidateArtifactDigest
  );
  return {
    id: P39_ARTIFACT_ID,
    inputRoot: root,
    macos,
    linux,
    version,
    targetHead,
    candidateRunId: String(candidateRunId),
    candidateArtifactDigest
  };
}

function appendOutput(file, name, value) {
  fs.appendFileSync(file, `${name}=${value}\n`, { encoding: 'utf8', mode: 0o600 });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = parseArguments(process.argv.slice(2));
    const result = resolveP39PlatformEvidence({ ...args, inputRoot: path.resolve(args.inputRoot) });
    const output = process.env.GITHUB_OUTPUT;
    if (!output) throw new Error('GITHUB_OUTPUT is required');
    appendOutput(output, 'macos', result.macos);
    appendOutput(output, 'linux', result.linux);
    appendOutput(output, 'version', result.version);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`P-39 platform evidence resolution failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
