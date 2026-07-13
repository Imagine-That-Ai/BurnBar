#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  P40_PROOF_FILENAME,
  P40_PROOF_ROLE,
  P40_REGISTRATION_FILENAME,
  canonicalCases,
  canonicalControls,
  canonicalInventory,
  canonicalSourceEvidence,
  parseP40Json,
  validateP40DataPrivacyProof
} from './lib/p40-data-privacy-proof.mjs';
import { readRegularSnapshot, SUPPORT_ENVIRONMENTS } from './lib/product-proof-closure.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const HEAD = /^[a-f0-9]{40,64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;

function parseOsRelease(source) {
  return Object.fromEntries(source.split('\n')
    .map((line) => line.match(/^([A-Z_]+)=(.*)$/u))
    .filter(Boolean)
    .map((match) => [match[1], match[2].replace(/^"|"$/gu, '')]));
}

function defaultHostProbe() {
  if (process.platform !== 'linux') throw new Error('P-40 installed proof must run on Linux');
  const release = parseOsRelease(fs.readFileSync('/etc/os-release', 'utf8'));
  const desktop = (process.env.XDG_CURRENT_DESKTOP ?? process.env.DESKTOP_SESSION ?? 'unknown').trim() || 'unknown';
  const session = (process.env.XDG_SESSION_TYPE ?? 'unknown').trim() || 'unknown';
  return {
    platform: 'linux',
    architecture: process.arch === 'arm64' ? 'aarch64' : process.arch === 'x64' ? 'x86_64' : process.arch,
    desktop,
    session,
    os: { id: release.ID ?? 'unknown', versionId: release.VERSION_ID ?? 'unknown' }
  };
}

function fixtureHostProbe() {
  return {
    platform: 'linux',
    architecture: 'x86_64',
    desktop: 'GNOME fixture',
    session: 'x11',
    os: { id: 'ubuntu', versionId: '24.04' }
  };
}

function atomicWrite(file, bytes) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(temporary, bytes, { mode: 0o600, flag: 'wx' });
  fs.renameSync(temporary, file);
}

function assertNoSymlinkComponents(repoRoot, absolutePath, label) {
  const relative = path.relative(repoRoot, absolutePath);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} escapes its repository`);
  }
  let current = repoRoot;
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

function proofDocument({ repoRoot, environmentId, targetHead, candidateRunId, candidateArtifactDigest, host }) {
  return {
    schemaVersion: 1,
    id: 'openburnbar-linux-p40-data-privacy-proof-v1',
    requirementId: 'P-40',
    environmentId,
    targetHead,
    candidate: { runId: String(candidateRunId), artifactDigest: candidateArtifactDigest },
    capture: {
      architecture: host.architecture,
      desktop: host.desktop,
      evidenceOrigin: 'contract-fixture',
      mode: 'fixture',
      os: host.os,
      piiObserved: false,
      platform: host.platform,
      productionDataObserved: false,
      secretBytesObserved: false,
      session: host.session
    },
    inventory: canonicalInventory(repoRoot),
    controls: canonicalControls(),
    cases: canonicalCases(),
    sourceEvidence: canonicalSourceEvidence(repoRoot),
    passed: true
  };
}

export function captureP40DataPrivacy({
  inputRoot,
  environmentId,
  targetHead,
  candidateRunId,
  candidateArtifactDigest,
  repoRoot = DEFAULT_REPO_ROOT,
  hostProbe = defaultHostProbe,
  gitHead = currentHead
}) {
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId)) throw new Error(`unknown support environment: ${environmentId}`);
  if (!HEAD.test(targetHead ?? '')) throw new Error('target head must be a commit id');
  if (!RUN_ID.test(String(candidateRunId ?? ''))) throw new Error('candidate run id must be a positive integer');
  if (!DIGEST.test(candidateArtifactDigest ?? '')) throw new Error('candidate artifact digest must be a SHA-256 digest');

  const repository = fs.realpathSync(repoRoot);
  const lexicalRoot = path.resolve(inputRoot);
  assertNoSymlinkComponents(repository, lexicalRoot, 'P-40 input root');
  const relative = path.relative(repository, lexicalRoot);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error('P-40 input root must be inside the repository');
  }
  const root = fs.realpathSync(lexicalRoot);
  const resolvedHead = gitHead(repository);
  if (resolvedHead !== targetHead) {
    throw new Error(`P-40 capture target head ${targetHead} does not match checkout HEAD ${resolvedHead}`);
  }
  const host = { ...hostProbe() };
  if (host.platform !== 'linux') throw new Error('P-40 capture requires a Linux host probe');
  if (!host.os?.id || !host.os?.versionId) throw new Error('P-40 host probe must identify the operating system');

  const document = proofDocument({
    repoRoot: repository,
    environmentId,
    targetHead,
    candidateRunId,
    candidateArtifactDigest,
    host
  });
  const output = path.join(root, 'feature-artifacts', P40_PROOF_FILENAME);
  const registrationPath = path.join(root, P40_REGISTRATION_FILENAME);
  fs.rmSync(output, { force: true });
  fs.rmSync(registrationPath, { force: true });
  atomicWrite(output, Buffer.from(`${JSON.stringify(document, null, 2)}\n`, 'utf8'));
  const registration = {
    schemaVersion: 1,
    requirementId: 'P-40',
    environmentId,
    artifacts: [{ role: P40_PROOF_ROLE, path: `feature-artifacts/${P40_PROOF_FILENAME}` }]
  };
  atomicWrite(registrationPath, Buffer.from(`${JSON.stringify(registration, null, 2)}\n`, 'utf8'));
  const snapshot = readRegularSnapshot(root, `feature-artifacts/${P40_PROOF_FILENAME}`, 'P-40 data privacy proof');
  validateP40DataPrivacyProof({
    repoRoot: repository,
    snapshot,
    targetHead,
    environmentId,
    candidateRunId,
    candidateArtifactDigest
  });
  return { output, registration: registrationPath, document: parseP40Json(snapshot.bytes) };
}

export function parseArguments(argv) {
  const allowed = new Set([
    '--input-root', '--environment', '--target-head', '--candidate-run-id', '--candidate-artifact-digest'
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
  return {
    inputRoot: values.get('--input-root'),
    environmentId: values.get('--environment'),
    targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'),
    candidateArtifactDigest: values.get('--candidate-artifact-digest')
  };
}

function main(argv = process.argv.slice(2), repoRoot = DEFAULT_REPO_ROOT) {
  const result = captureP40DataPrivacy({ ...parseArguments(argv), repoRoot });
  process.stdout.write(`${JSON.stringify({
    output: path.relative(repoRoot, result.output),
    registration: path.relative(repoRoot, result.registration),
    status: result.document.passed ? 'passed' : 'blocked'
  }, null, 2)}\n`);
  return result;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`P-40 data privacy capture failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
