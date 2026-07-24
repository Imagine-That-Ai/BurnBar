#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  P08_DESKTOP_OBSERVATION_FILENAME,
  P08_DEVICE_OBSERVATION_FILENAME,
  P08_SESSION_FILENAME,
  P08_TARGET_IDS,
  validatePairedAgreement,
  validateP08InstalledMediaSession,
  validateP08Observation
} from './lib/p08-mercury-media-proof.mjs';
import { readRegularSnapshot, SUPPORT_ENVIRONMENTS } from './lib/product-proof-closure.mjs';
import {
  INSTALLED_MANIFEST_PATH,
  INSTALLED_MANIFEST_SIGNATURE_PATH,
  RELEASE_PUBLIC_KEY_PATH,
  assertInstalledManifest
} from './lib/linux-installed-manifest.mjs';
import { verifyLiveInstalledProduct } from './lib/live-installed-product-evidence.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const INSTALLED_BINARIES = Object.freeze([
  '/usr/bin/openburnbar-linux-desktop',
  '/usr/bin/openburnbar-daemon',
  '/usr/bin/openburnbar-cli'
]);
const HEAD = /^[a-f0-9]{40,64}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;
const VERSION = /^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$/u;
const MAX_OBSERVATION_AGE_MS = 15 * 60 * 1000;

function fail(message) { throw new Error(message); }
function assert(condition, message) { if (!condition) fail(message); }
function sha256(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }

function environmentContract(environmentId) {
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId)) fail(`unsupported P-08 environment: ${environmentId}`);
  const architecture = environmentId.endsWith('-aarch64') ? 'aarch64' : 'x86_64';
  const session = environmentId.includes('-x11-') ? 'x11' : 'wayland';
  if (environmentId.startsWith('ubuntu-')) return { architecture, desktop: 'gnome', format: 'deb', os: 'ubuntu', version: '24.04', session };
  if (environmentId.startsWith('fedora-')) return { architecture, desktop: 'kde', format: 'rpm', os: 'fedora', version: null, session };
  return { architecture, desktop: 'sway', format: 'arch', os: 'arch', version: null, session };
}

function parseOsRelease() {
  return Object.fromEntries(fs.readFileSync('/etc/os-release', 'utf8').split('\n')
    .map((line) => line.match(/^([A-Z_]+)=(.*)$/u)).filter(Boolean)
    .map((match) => [match[1], match[2].replace(/^"|"$/gu, '')]));
}

function rootOwnedInstalledFile(file) {
  const link = fs.lstatSync(file);
  const stat = fs.statSync(file);
  assert(link.isFile() && !link.isSymbolicLink() && stat.uid === 0 && (stat.mode & 0o022) === 0,
    `${file} is not a root-owned immutable installed file`);
}

export function verifyInstalledManifestSignature({
  manifestBytes, signatureBytes, publicKeyBytes, expectedManifestSha256, expectedSignatureSha256
}) {
  assert(sha256(manifestBytes) === expectedManifestSha256, 'installed manifest digest does not match the selected candidate');
  assert(sha256(signatureBytes) === expectedSignatureSha256, 'installed manifest signature digest does not match the selected candidate');
  assert(signatureBytes.length === 64, 'installed manifest signature must be Ed25519');
  let valid = false;
  try {
    const publicKey = crypto.createPublicKey(publicKeyBytes);
    valid = publicKey.asymmetricKeyType === 'ed25519'
      && crypto.verify(null, manifestBytes, publicKey, signatureBytes);
  } catch {
    valid = false;
  }
  assert(valid, 'installed manifest signature verification failed');
}

export function verifyInstalledCandidate(options, { verifier = verifyLiveInstalledProduct } = {}) {
  assert(process.platform === 'linux', 'P-08 live session producer must execute on Linux');
  const contract = environmentContract(options.environmentId);
  for (const file of [INSTALLED_MANIFEST_PATH, INSTALLED_MANIFEST_SIGNATURE_PATH, RELEASE_PUBLIC_KEY_PATH, ...INSTALLED_BINARIES]) {
    rootOwnedInstalledFile(file);
  }
  const manifestBytes = fs.readFileSync(INSTALLED_MANIFEST_PATH);
  const signatureBytes = fs.readFileSync(INSTALLED_MANIFEST_SIGNATURE_PATH);
  const publicKeyBytes = fs.readFileSync(RELEASE_PUBLIC_KEY_PATH);
  verifyInstalledManifestSignature({
    manifestBytes,
    signatureBytes,
    publicKeyBytes,
    expectedManifestSha256: options.manifestSha256,
    expectedSignatureSha256: options.manifestSignatureSha256
  });
  const manifest = assertInstalledManifest(JSON.parse(manifestBytes.toString('utf8')));
  assert(manifest.gitCommit === options.targetHead && manifest.packageVersion === options.packageVersion
      && manifest.packageArchitecture === contract.architecture && manifest.packageFormat === contract.format,
    'installed manifest identity does not match the selected candidate');
  verifier({
    installedManifest: manifest,
    expectedManifestBytes: manifestBytes,
    expectedSignatureBytes: signatureBytes
  });
  const observedArchitecture = process.arch === 'arm64' ? 'aarch64' : process.arch === 'x64' ? 'x86_64' : process.arch;
  assert(observedArchitecture === contract.architecture, 'installed host architecture does not match the P-08 environment');
  const release = parseOsRelease();
  assert(release.ID === contract.os && (contract.version === null || release.VERSION_ID === contract.version),
    'installed host operating system does not match the P-08 environment');
  const observedSession = (process.env.XDG_SESSION_TYPE ?? '').toLowerCase();
  const observedDesktop = (process.env.XDG_CURRENT_DESKTOP ?? process.env.DESKTOP_SESSION ?? '').toLowerCase();
  assert(observedSession === contract.session && observedDesktop.includes(contract.desktop),
    'installed desktop session does not match the P-08 environment');
  return { contract, release, observedDesktop, observedSession };
}

function assertInside(root, candidate, label) {
  const relative = path.relative(root, candidate);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail(`${label} must remain inside the repository`);
  }
}

function readObservation(repoRoot, outputRoot, filename, side, binding, expectedSession = null) {
  const absolute = path.join(outputRoot, filename);
  assertInside(repoRoot, absolute, `P-08 ${side} observation`);
  assert(path.dirname(absolute) === outputRoot, `P-08 ${side} observation must be at the output root`);
  const relative = path.relative(repoRoot, absolute).split(path.sep).join('/');
  const snapshot = readRegularSnapshot(repoRoot, relative, `P-08 ${side} observation`);
  const document = JSON.parse(snapshot.bytes.toString('utf8'));
  const validated = validateP08Observation(document, binding, side, expectedSession);
  const now = Date.now();
  assert(validated.captureEnd <= now + 60_000 && now - validated.captureEnd <= MAX_OBSERVATION_AGE_MS,
    `P-08 ${side} requires fresh live observations`);
  return { document, snapshot, relative, validated };
}

function ownerOnlyDirectory(directory) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const link = fs.lstatSync(directory);
  const stat = fs.statSync(directory);
  assert(link.isDirectory() && !link.isSymbolicLink() && stat.uid === process.getuid() && (stat.mode & 0o077) === 0,
    'P-08 output root must be an owner-only real directory');
}

function atomicWrite(file, bytes) {
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(temporary, bytes, { mode: 0o600, flag: 'wx' });
  fs.renameSync(temporary, file);
}

export function buildP08Session(options, installed, desktop, device) {
  const binding = {
    environmentId: options.environmentId,
    targetHead: options.targetHead,
    candidateRunId: options.candidateRunId,
    candidateArtifactDigest: options.candidateArtifactDigest
  };
  validateP08Observation(desktop.document, binding, 'linux-desktop');
  validateP08Observation(device.document, binding, 'physical-device', desktop.document.session);
  const desktopByTarget = new Map(desktop.document.events.map((event) => [event.targetId, event]));
  const deviceByTarget = new Map(device.document.events.map((event) => [event.targetId, event]));
  validatePairedAgreement(desktopByTarget, deviceByTarget);
  return {
    schemaVersion: 1,
    id: 'openburnbar-linux-p08-installed-mercury-media-session-v1',
    requirementId: 'P-08',
    environmentId: options.environmentId,
    targetHead: options.targetHead,
    candidate: { runId: String(options.candidateRunId), artifactDigest: options.candidateArtifactDigest },
    capture: {
      architecture: installed.contract.architecture,
      desktop: installed.observedDesktop,
      mode: 'installed-linux-paired-physical-device',
      os: { id: installed.release.ID, versionId: installed.release.VERSION_ID },
      platform: 'linux',
      session: installed.observedSession
    },
    package: {
      architecture: installed.contract.architecture,
      format: installed.contract.format,
      installed: true,
      manifestSha256: options.manifestSha256,
      manifestSignatureSha256: options.manifestSignatureSha256,
      source: 'signed-installed-candidate',
      version: options.packageVersion
    },
    session: structuredClone(desktop.document.session),
    peer: structuredClone(device.document.hardware),
    rawEvidence: [
      { side: 'linux-desktop', path: desktop.relative, sha256: desktop.snapshot.sha256 },
      { side: 'physical-device', path: device.relative, sha256: device.snapshot.sha256 }
    ],
    targets: P08_TARGET_IDS.map((targetId) => ({
      targetId,
      desktopMetrics: structuredClone(desktopByTarget.get(targetId).metrics),
      deviceMetrics: structuredClone(deviceByTarget.get(targetId).metrics),
      passed: true
    })),
    passed: true
  };
}

export function runP08MercuryMediaSession(options) {
  const repoRoot = fs.realpathSync(options.repoRoot ?? DEFAULT_REPO_ROOT);
  const outputRoot = path.resolve(options.outputRoot);
  assertInside(repoRoot, outputRoot, 'P-08 output root');
  ownerOnlyDirectory(outputRoot);
  const installed = verifyInstalledCandidate(options);
  const binding = {
    environmentId: options.environmentId,
    targetHead: options.targetHead,
    candidateRunId: options.candidateRunId,
    candidateArtifactDigest: options.candidateArtifactDigest
  };
  const desktop = readObservation(repoRoot, outputRoot, P08_DESKTOP_OBSERVATION_FILENAME, 'linux-desktop', binding);
  const device = readObservation(repoRoot, outputRoot, P08_DEVICE_OBSERVATION_FILENAME, 'physical-device', binding, desktop.document.session);
  const document = buildP08Session(options, installed, desktop, device);
  const output = path.join(outputRoot, P08_SESSION_FILENAME);
  fs.rmSync(output, { force: true });
  atomicWrite(output, Buffer.from(`${JSON.stringify(document, null, 2)}\n`));
  validateP08InstalledMediaSession(document, binding, { repoRoot });
  return { document, output };
}

function parseArguments(argv) {
  const flags = new Set([
    '--output-root', '--environment', '--target-head', '--candidate-run-id',
    '--candidate-artifact-digest', '--package-version', '--manifest-sha256',
    '--manifest-signature-sha256'
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    if (!flags.has(flag) || argv[index + 1] === undefined || values.has(flag)) fail(`invalid argument: ${flag ?? '<missing>'}`);
    values.set(flag, argv[index + 1]);
  }
  for (const flag of flags) if (!values.has(flag)) fail(`${flag} is required`);
  const result = {
    outputRoot: path.resolve(values.get('--output-root')),
    environmentId: values.get('--environment'),
    targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'),
    candidateArtifactDigest: values.get('--candidate-artifact-digest'),
    packageVersion: values.get('--package-version'),
    manifestSha256: values.get('--manifest-sha256'),
    manifestSignatureSha256: values.get('--manifest-signature-sha256')
  };
  assert(HEAD.test(result.targetHead) && RUN_ID.test(result.candidateRunId) && DIGEST.test(result.candidateArtifactDigest),
    'P-08 candidate binding is invalid');
  assert(VERSION.test(result.packageVersion) && SHA256.test(result.manifestSha256)
      && SHA256.test(result.manifestSignatureSha256), 'P-08 package binding is invalid');
  return result;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = runP08MercuryMediaSession(parseArguments(process.argv.slice(2)));
    process.stdout.write(`${JSON.stringify({ output: result.output })}\n`);
  } catch (error) {
    process.stderr.write(`P-08 installed Mercury media session failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
