#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {
  inspectArchPackageDependencies,
  inspectNativePackageMetadata
} from './lib/linux-native-package.mjs';
import { readJson, relative, repoRoot, runStep, writeJson } from './lib/linux-release-common.mjs';

const outDir = path.resolve(process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? path.join(repoRoot, '.linux-shard'));
const reportFile = path.join(outDir, 'session/arch-package-update-rollback.json');
const closure = readJson(path.join(outDir, 'architecture-closure.json'));
const artifacts = (closure.artifacts ?? []).filter((entry) => entry.type === 'arch');
if (artifacts.length !== 1) throw new Error(`Arch lifecycle requires exactly one closure artifact, found ${artifacts.length}`);
const artifact = artifacts[0];
const candidate = requiredArgument('--candidate');
const previous = optionalArgument('--previous');
const candidateRecord = recordedCandidate(candidate, artifact);

if (!previous) {
  const reason = 'No previous same-architecture Arch package was supplied; pacman update, rollback, and data-preservation gates remain blocked.';
  writeJson(reportFile, {
    schemaVersion: 1,
    manager: 'pacman',
    packageName: 'openburnbar',
    architecture: closure.architecture,
    gitCommit: closure.git?.commit,
    candidate: candidateRecord,
    previous: null,
    steps: [],
    lifecycle: Object.fromEntries(['update', 'rollback', 'dataPreservation'].map((key) => [key, { status: 'blocked', reason }])),
    passed: false
  });
  console.log(fs.readFileSync(reportFile, 'utf8'));
  process.exit(0);
}

const previousRecord = packageRecord(previous);
const candidateMetadata = inspectNativePackageMetadata('arch', candidate);
const previousMetadata = inspectNativePackageMetadata('arch', previous);
for (const [label, metadata, record] of [
  ['candidate', candidateMetadata, candidateRecord],
  ['previous', previousMetadata, previousRecord]
]) {
  if (metadata.packageName !== 'openburnbar' || metadata.packageArchitecture !== closure.architecture
      || metadata.packageVersion !== record.version) {
    throw new Error(`Arch ${label} package manager identity is not release-bound`);
  }
}
if (candidateMetadata.packageVersion !== closure.version
    || compareVersions(previousMetadata.packageVersion, candidateMetadata.packageVersion) >= 0) {
  throw new Error('Arch previous package must be older than the candidate closure version');
}

const dependencies = inspectArchPackageDependencies(candidate);
const dependencyPackages = [...new Set(dependencies.map((dependency) => {
  const match = /^([a-z0-9@._+:-]+)/u.exec(dependency);
  if (!match) throw new Error(`Arch dependency cannot be installed safely: ${dependency}`);
  return match[1];
}))];
const steps = [];
runRequired('pacman', ['-Syu', '--noconfirm', '--needed', ...dependencyPackages]);
runRequired('pacman', ['-T', ...dependencies]);

const workRoot = path.join(outDir, 'session/arch-update-runtime');
fs.rmSync(workRoot, { recursive: true, force: true });
for (const directory of ['home/.local/share/openburnbar', 'config', 'run']) {
  fs.mkdirSync(path.join(workRoot, directory), { recursive: true });
}
fs.chmodSync(path.join(workRoot, 'run'), 0o700);
const sentinel = path.join(workRoot, 'home/.local/share/openburnbar/parity-update-sentinel.json');
fs.writeFileSync(sentinel, '{"preserve":"openburnbar-linux-parity","createdBy":"arch-package-update-rollback"}\n', { mode: 0o600 });
const sentinelSha256 = sha256File(sentinel);
const preservation = {};

installAndProbe(previous, previousRecord, 'afterPreviousSha256');
installAndProbe(candidate, candidateRecord, 'afterUpdateSha256');
installAndProbe(previous, previousRecord, 'afterRollbackSha256');
installAndProbe(candidate, candidateRecord, 'afterRestoreSha256');

const lifecycle = {
  update: transition(previousRecord, candidateRecord),
  rollback: transition(candidateRecord, previousRecord),
  dataPreservation: { status: 'passed', sentinelSha256, ...preservation }
};
const report = {
  schemaVersion: 1,
  manager: 'pacman',
  packageName: 'openburnbar',
  architecture: closure.architecture,
  gitCommit: closure.git?.commit,
  candidate: candidateRecord,
  previous: previousRecord,
  steps,
  lifecycle,
  passed: true
};
writeJson(reportFile, report);
console.log(JSON.stringify(report, null, 2));

function installAndProbe(file, record, preservationField) {
  runRequired('pacman', ['-U', '--noconfirm', file]);
  const identity = runRequired('pacman', ['-Qi', 'openburnbar']);
  const fields = Object.fromEntries(identity.stdout.split('\n')
    .map((line) => line.match(/^([^:]+?)\s*:\s*(.*)$/u))
    .filter(Boolean)
    .map((match) => [match[1].trim(), match[2].trim()]));
  const installedVersion = String(fields.Version ?? '').replace(/-[1-9][0-9]*$/u, '');
  if (fields.Name !== 'openburnbar' || installedVersion !== record.version
      || normalizeArchitecture(fields.Architecture) !== closure.architecture) {
    throw new Error('live pacman identity does not match the expected lifecycle package');
  }
  const env = {
    ...process.env,
    HOME: path.join(workRoot, 'home'),
    XDG_CONFIG_HOME: path.join(workRoot, 'config'),
    XDG_DATA_HOME: path.join(workRoot, 'home/.local/share'),
    XDG_RUNTIME_DIR: path.join(workRoot, 'run')
  };
  const desktop = runRequired('/usr/bin/openburnbar-linux-desktop', ['--version'], { env });
  if (!desktop.stdout.includes(record.version)) throw new Error('installed Arch desktop version readback drifted');
  const daemon = runRequired('/usr/libexec/openburnbar-daemon-launch', ['--help'], { env });
  if (!daemon.stdout.includes('socket-path') && !daemon.stderr.includes('socket-path')) {
    throw new Error('installed Arch daemon launcher help did not expose the socket contract');
  }
  preservation[preservationField] = sha256File(sentinel);
  if (preservation[preservationField] !== sentinelSha256) throw new Error('Arch lifecycle changed persisted user data');
}

function runRequired(command, args, options = {}) {
  const step = runStep(command, args, options);
  steps.push(step);
  if (step.exitCode !== 0) throw new Error(`${step.command} failed\n${step.stdout}\n${step.stderr}`);
  return step;
}

function transition(from, to) {
  return {
    status: 'passed',
    manager: 'pacman',
    packageName: 'openburnbar',
    architecture: closure.architecture,
    fromVersion: from.version,
    toVersion: to.version,
    fromSha256: from.sha256,
    toSha256: to.sha256
  };
}

function recordedCandidate(file, record) {
  const actual = packageRecord(file);
  if (actual.file !== record.file || actual.sha256 !== record.sha256 || actual.size !== record.size) {
    throw new Error('Arch candidate path, size, or SHA-256 does not match the architecture closure');
  }
  return { ...actual, version: closure.version };
}

function packageRecord(file) {
  const absolute = fs.realpathSync(path.resolve(file));
  const root = fs.realpathSync(repoRoot);
  const repositoryRelative = path.relative(root, absolute);
  if (repositoryRelative === '..' || repositoryRelative.startsWith(`..${path.sep}`)
      || path.isAbsolute(repositoryRelative) || !absolute.endsWith('.pkg.tar.zst')) {
    throw new Error('Arch lifecycle package must be a repository-confined .pkg.tar.zst file');
  }
  const metadata = inspectNativePackageMetadata('arch', absolute);
  const bytes = fs.readFileSync(absolute);
  return {
    file: repositoryRelative.split(path.sep).join('/'),
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    size: bytes.length,
    version: metadata.packageVersion
  };
}

function sha256File(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function compareVersions(left, right) {
  const leftParts = left.split('.').map(Number);
  const rightParts = right.split('.').map(Number);
  for (let index = 0; index < leftParts.length; index += 1) {
    if (leftParts[index] !== rightParts[index]) return leftParts[index] - rightParts[index];
  }
  return 0;
}

function normalizeArchitecture(value) {
  if (value === 'amd64' || value === 'x86_64') return 'x86_64';
  if (value === 'arm64' || value === 'aarch64') return 'aarch64';
  return value;
}

function requiredArgument(name) {
  const value = optionalArgument(name);
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function optionalArgument(name) {
  const indexes = process.argv.flatMap((value, index) => value === name ? [index] : []);
  if (indexes.length > 1) throw new Error(`${name} may occur only once`);
  return indexes.length === 1 ? process.argv[indexes[0] + 1]?.trim() ?? '' : '';
}
