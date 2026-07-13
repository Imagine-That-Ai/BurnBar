#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {
  inspectArchPackageDependencies,
  inspectNativePackageMetadata,
  verifySignedNativePackage
} from './lib/linux-native-package.mjs';
import { readJson, relative, repoRoot, runStep, writeJson } from './lib/linux-release-common.mjs';

const outDir = path.resolve(process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? path.join(repoRoot, '.linux-shard'));
// Keep the Arch lifecycle report outside the general session directory.  The
// later desktop/daemon probes are allowed to write session evidence, but must
// not be able to replace an already-authenticated package transition report.
const reportFile = path.join(outDir, 'arch-lifecycle/arch-package-update-rollback.json');
const closure = readJson(path.join(outDir, 'architecture-closure.json'));
const artifacts = (closure.artifacts ?? []).filter((entry) => entry.type === 'arch');
if (artifacts.length !== 1) throw new Error(`Arch lifecycle requires exactly one closure artifact, found ${artifacts.length}`);
const artifact = artifacts[0];
const candidate = requiredArgument('--candidate');
const previous = optionalArgument('--previous');
const candidateRecord = recordedCandidate(candidate, artifact);
const releasePublicKey = optionalArgument('--release-public-key');
const previousSignature = optionalArgument('--previous-signature');
const previousManifest = optionalArgument('--previous-installed-manifest');
const previousManifestSignature = optionalArgument('--previous-installed-manifest-signature');
const previousProductProof = optionalArgument('--previous-product-proof');
const previousProductProofSignature = optionalArgument('--previous-product-proof-signature');
const previousReleaseTag = optionalArgument('--previous-release-tag');

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
    previousProvenance: null,
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

const candidateManifestBytes = readClosureSubject(
  artifact.installedManifest,
  'Arch candidate installed manifest'
);
const candidateManifestSignatureBytes = readClosureSubject(
  artifact.installedManifestSignature,
  'Arch candidate installed manifest signature'
);
const publicKeyBytes = readRegularFile(releasePublicKey, 'release public key');
verifySignedNativePackage({
  format: 'arch',
  artifact: candidate,
  manifestBytes: candidateManifestBytes,
  signatureBytes: candidateManifestSignatureBytes,
  publicKeyPem: publicKeyBytes
});
const previousProvenance = authenticatePreviousRelease({
  packageFile: previous,
  packageRecord: previousRecord,
  packageSignatureFile: previousSignature,
  manifestFile: previousManifest,
  manifestSignatureFile: previousManifestSignature,
  productProofFile: previousProductProof,
  productProofSignatureFile: previousProductProofSignature,
  releasePublicKey: publicKeyBytes,
  releaseTag: previousReleaseTag,
  architecture: closure.architecture,
  packageMetadata: previousMetadata
});

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
  previousProvenance,
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
  const absolute = confinedRegularFile(file, 'Arch lifecycle package');
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

function readRegularFile(file, label) {
  if (!file) throw new Error(`${label} is required for authenticated Arch lifecycle evidence`);
  const absolute = confinedRegularFile(file, label);
  return fs.readFileSync(absolute);
}

function readClosureSubject(record, label) {
  if (!record || typeof record.file !== 'string' || !SHA256.test(record.sha256 ?? '')
      || !Number.isSafeInteger(record.size) || record.size <= 0) {
    throw new Error(`${label} record is invalid`);
  }
  const bytes = readRegularFile(path.resolve(repoRoot, record.file), label);
  if (bytes.length !== record.size || sha256Buffer(bytes) !== record.sha256) {
    throw new Error(`${label} does not match the architecture closure`);
  }
  return bytes;
}

function confinedRegularFile(file, label) {
  const absolute = path.resolve(file);
  const root = fs.realpathSync(repoRoot);
  const relativePath = path.relative(root, absolute);
  if (relativePath === '..' || relativePath.startsWith(`..${path.sep}`)
      || path.isAbsolute(relativePath)) {
    throw new Error(`${label} must be repository-confined`);
  }
  let current = root;
  for (const component of relativePath.split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    const metadata = fs.lstatSync(current);
    if (metadata.isSymbolicLink()) throw new Error(`${label} traverses a symlink`);
  }
  const metadata = fs.lstatSync(absolute);
  if (!metadata.isFile()) throw new Error(`${label} must be a regular file`);
  return absolute;
}

function sha256Buffer(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function authenticatePreviousRelease({
  packageFile,
  packageRecord: record,
  packageSignatureFile,
  manifestFile,
  manifestSignatureFile,
  productProofFile,
  productProofSignatureFile,
  releasePublicKey: publicKey,
  releaseTag,
  architecture,
  packageMetadata
}) {
  if (!packageSignatureFile || !manifestFile || !manifestSignatureFile || !productProofFile
      || !productProofSignatureFile || !releaseTag) {
    throw new Error('authenticated previous Arch lifecycle evidence requires package signature, manifest, product proof, closure signature, public key, and release tag');
  }
  const packageSignatureBytes = readRegularFile(packageSignatureFile, 'previous Arch package signature');
  if (packageSignatureBytes.length !== 64
      || !crypto.verify(null, fs.readFileSync(packageFile), crypto.createPublicKey(publicKey), packageSignatureBytes)) {
    throw new Error('previous Arch package detached signature does not verify with the pinned release public key');
  }
  const manifestBytes = readRegularFile(manifestFile, 'previous Arch installed manifest');
  const manifestSignatureBytes = readRegularFile(manifestSignatureFile, 'previous Arch installed manifest signature');
  const manifest = JSON.parse(manifestBytes.toString('utf8'));
  if (manifest.packageName !== 'openburnbar' || manifest.packageFormat !== 'arch'
      || manifest.packageArchitecture !== architecture || manifest.packageVersion !== packageMetadata.packageVersion
      || !/^[a-f0-9]{40}$/u.test(manifest.gitCommit ?? '')) {
    throw new Error('previous Arch installed manifest is not bound to the package identity');
  }
  if (manifestSignatureBytes.length !== 64
      || !crypto.verify(null, manifestBytes, crypto.createPublicKey(publicKey), manifestSignatureBytes)) {
    throw new Error('previous Arch installed manifest signature does not verify with the pinned release public key');
  }
  verifySignedNativePackage({
    format: 'arch',
    artifact: packageFile,
    manifestBytes,
    signatureBytes: manifestSignatureBytes,
    publicKeyPem: publicKey
  });
  const proofBytes = readRegularFile(productProofFile, 'previous product proof closure');
  const proofSignatureBytes = readRegularFile(productProofSignatureFile, 'previous product proof closure signature');
  if (proofSignatureBytes.length !== 64
      || !crypto.verify(null, proofBytes, crypto.createPublicKey(publicKey), proofSignatureBytes)) {
    throw new Error('previous product proof closure signature does not verify with the pinned release public key');
  }
  const proof = JSON.parse(proofBytes.toString('utf8'));
  const packageRow = (proof.packages ?? []).find((row) =>
    row?.format === 'arch' && row?.architecture === architecture
  );
  if (proof.status !== 'passed' || proof.stage !== 'candidate' || proof.version !== packageMetadata.packageVersion
      || proof.targetHead !== manifest.gitCommit || proof.sourceCommit !== manifest.gitCommit || !packageRow
      || packageRow.artifact?.sha256 !== record.sha256 || packageRow.artifact?.size !== record.size
      || packageRow.installedManifest?.sha256 !== sha256Buffer(manifestBytes)
      || packageRow.installedManifestSignature?.sha256 !== sha256Buffer(manifestSignatureBytes)) {
    throw new Error('previous product proof closure is not bound to the signed Arch package and manifest');
  }
  const expectedTag = `linux-v${packageMetadata.packageVersion}`;
  if (releaseTag !== expectedTag) throw new Error('previous Arch release tag does not match the signed package version');
  const previousPrefix = `${path.posix.dirname(record.file)}/`;
  const provenanceRecords = {
    packageSignature: fileRecord(packageSignatureFile),
    installedManifest: fileRecord(manifestFile),
    installedManifestSignature: fileRecord(manifestSignatureFile),
    productProofClosure: fileRecord(productProofFile),
    productProofClosureSignature: fileRecord(productProofSignatureFile)
  };
  const expectedFiles = {
    packageSignature: `${record.file}.ed25519.sig`,
    installedManifest: `${previousPrefix}openburnbar-${packageMetadata.packageVersion}-${architecture}.installed-manifest.json`,
    installedManifestSignature: `${previousPrefix}openburnbar-${packageMetadata.packageVersion}-${architecture}.installed-manifest.ed25519`,
    productProofClosure: `${previousPrefix}product-proof-closure.json`,
    productProofClosureSignature: `${previousPrefix}product-proof-closure.json.ed25519.sig`
  };
  for (const [field, expectedFile] of Object.entries(expectedFiles)) {
    if (provenanceRecords[field].file !== expectedFile) {
      throw new Error(`previous Arch ${field} is not the exact release asset`);
    }
  }
  return {
    releaseTag,
    releaseCommit: manifest.gitCommit,
    ...provenanceRecords
  };
}

function fileRecord(file) {
  const absolute = confinedRegularFile(file, 'Arch lifecycle provenance subject');
  const bytes = fs.readFileSync(absolute);
  return {
    file: path.relative(fs.realpathSync(repoRoot), absolute).split(path.sep).join('/'),
    sha256: sha256Buffer(bytes),
    size: bytes.length
  };
}

function sha256File(file) {
  return sha256Buffer(fs.readFileSync(file));
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
  if (indexes.length !== 1) return '';
  const value = process.argv[indexes[0] + 1];
  if (!value || value.startsWith('--')) throw new Error(`${name} requires a value`);
  return value.trim();
}
