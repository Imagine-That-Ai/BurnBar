#!/usr/bin/env node
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import {
  captureLiveRuntimeCapabilities,
  verifyLiveInstalledProduct
} from './lib/live-installed-product-evidence.mjs';

export const CANONICAL_REQUIREMENT_IDS = Array.from(
  { length: 40 },
  (_, index) => `P-${String(index + 1).padStart(2, '0')}`
);
export const CANONICAL_ENVIRONMENT_IDS = [
  'ubuntu-24.04-gnome-x11-x86_64',
  'ubuntu-24.04-gnome-x11-aarch64',
  'ubuntu-24.04-gnome-wayland-x86_64',
  'ubuntu-24.04-gnome-wayland-aarch64',
  'fedora-kde-wayland-x86_64',
  'fedora-kde-wayland-aarch64',
  'arch-sway-wayland-x86_64'
];

const REQUIREMENTS_PATH = 'docs/linux-port/product-parity-requirements.json';
const INSTALLED_MANIFEST_SCHEMA_PATH = 'packaging/linux/attestation/openburnbar-installed-manifest.schema.json';
const RUNTIME_MANIFEST_SCHEMA_PATH = 'schemas/linux-runtime-capability-manifest.schema.json';
const RUNTIME_CAPABILITY_CATALOG_PATH = 'packaging/linux/runtime-capability-catalog.json';
const INPUT_ROOT = 'docs/linux-port/evidence/product-parity-inputs';
const RECEIPT_ROOT = 'docs/linux-port/evidence/validator-receipts';
const VALIDATOR_ROOT = 'scripts/linux-port/product-validators';
const REQUIRED_FLAGS = ['--requirement', '--environment', '--release-closure', '--output'];
const RECEIPT_FIELDS = [
  'schemaVersion',
  'requirementId',
  'checkId',
  'environmentId',
  'targetHead',
  'status',
  'artifacts'
];
const RECEIPT_SCHEMA_FIELDS = [
  ...RECEIPT_FIELDS.slice(0, -1),
  'subject',
  'producer',
  'artifacts'
];
const ARTIFACT_FIELDS = ['path', 'sha256'];
const HEAD_PATTERN = /^[a-f0-9]{40,64}$/u;
const SHA256_PATTERN = /^[a-f0-9]{64}$/u;
const AREA_PATTERN = /^[a-z0-9]+(?:[._-][a-z0-9]+)*$/u;
const PACKAGE_TYPES = new Set(['appimage', 'deb', 'rpm', 'package']);
const PRODUCER_REPOSITORY = 'Imagine-That-Ai/BurnBar';
const PRODUCER_WORKFLOW = 'github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-product-parity.yml';

function assertExactKeys(value, keys, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    throw new Error(`${label} fields must be exactly: ${expected.join(', ')}`);
  }
}

function isInside(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function canonicalRelativePath(value, label) {
  if (typeof value !== 'string' || value.length === 0 || value.trim() !== value) {
    throw new Error(`${label} must be a nonempty repository-relative path`);
  }
  if (value.includes('\\') || path.posix.isAbsolute(value)) {
    throw new Error(`${label} must be a canonical repository-relative POSIX path: ${value}`);
  }
  const normalized = path.posix.normalize(value);
  if (normalized !== value || normalized === '.' || normalized === '..' || normalized.startsWith('../')) {
    throw new Error(`${label} escapes the repository or is not canonical: ${value}`);
  }
  return normalized;
}

function assertNoSymlinkComponents(repoRoot, absolutePath, label, allowMissing = false) {
  if (!isInside(repoRoot, absolutePath)) throw new Error(`${label} escapes the repository`);
  let current = repoRoot;
  for (const component of path.relative(repoRoot, absolutePath).split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    let stat;
    try {
      stat = fs.lstatSync(current);
    } catch (error) {
      if (allowMissing && error.code === 'ENOENT') return;
      throw new Error(`${label} does not exist: ${path.relative(repoRoot, current)}`);
    }
    if (stat.isSymbolicLink()) {
      throw new Error(`${label} traverses a symlink: ${path.relative(repoRoot, current)}`);
    }
  }
}

function resolveRegularFile(repoRoot, relativePath, label) {
  const canonical = canonicalRelativePath(relativePath, label);
  const absolute = path.resolve(repoRoot, canonical);
  assertNoSymlinkComponents(repoRoot, absolute, label);
  const stat = fs.lstatSync(absolute);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`${label} must be a regular non-symlink file`);
  const realRoot = fs.realpathSync(repoRoot);
  const realFile = fs.realpathSync(absolute);
  if (!isInside(realRoot, realFile)) throw new Error(`${label} escapes the repository through a symlink`);
  return { path: canonical, absolute: realFile };
}

function readJson(repoRoot, relativePath, label) {
  const source = resolveRegularFile(repoRoot, relativePath, label);
  const descriptor = fs.openSync(
    source.absolute,
    fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0)
  );
  try {
    const before = fs.fstatSync(descriptor);
    if (!before.isFile()) throw new Error(`${label} must be a regular file`);
    const bytes = fs.readFileSync(descriptor);
    const after = fs.fstatSync(descriptor);
    if (before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size
        || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs) {
      throw new Error(`${label} changed while it was being read`);
    }
    return {
      ...source,
      bytes,
      sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
      value: JSON.parse(bytes.toString('utf8'))
    };
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  } finally {
    fs.closeSync(descriptor);
  }
}

function readFileSnapshot(repoRoot, relativePath, label) {
  const source = resolveRegularFile(repoRoot, relativePath, label);
  const descriptor = fs.openSync(
    source.absolute,
    fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0)
  );
  try {
    const before = fs.fstatSync(descriptor);
    const bytes = fs.readFileSync(descriptor);
    const after = fs.fstatSync(descriptor);
    if (!before.isFile() || before.dev !== after.dev || before.ino !== after.ino
        || before.size !== after.size || before.mtimeMs !== after.mtimeMs
        || before.ctimeMs !== after.ctimeMs) {
      throw new Error(`${label} changed while it was being read`);
    }
    return {
      ...source,
      bytes,
      sha256: crypto.createHash('sha256').update(bytes).digest('hex')
    };
  } finally {
    fs.closeSync(descriptor);
  }
}

function sha256File(absolutePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(absolutePath)).digest('hex');
}

function runGit(repoRoot, args, allowStatusOne = false) {
  const result = spawnSync('git', args, { cwd: repoRoot, encoding: 'utf8' });
  if (result.status !== 0 && !(allowStatusOne && result.status === 1)) {
    throw new Error(`git ${args.join(' ')} failed: ${(result.stderr || result.stdout || 'unknown error').trim()}`);
  }
  return result;
}

function requireCleanCurrentHead(repoRoot) {
  const realRoot = fs.realpathSync(repoRoot);
  const topLevel = fs.realpathSync(runGit(repoRoot, ['rev-parse', '--show-toplevel']).stdout.trim());
  if (topLevel !== realRoot) throw new Error('repository root does not match the real git top level');
  const targetHead = runGit(repoRoot, ['rev-parse', '--verify', 'HEAD']).stdout.trim();
  if (!HEAD_PATTERN.test(targetHead)) throw new Error(`git HEAD is not a canonical commit id: ${targetHead}`);
  const index = runGit(repoRoot, ['diff', '--quiet', '--cached', 'HEAD', '--'], true);
  const worktree = runGit(repoRoot, ['diff', '--quiet', 'HEAD', '--'], true);
  if (index.status !== 0 || worktree.status !== 0) {
    throw new Error('git tracked worktree and index must be clean before validation');
  }
  const untracked = runGit(repoRoot, ['ls-files', '--others', '--exclude-standard', '-z'])
    .stdout.split('\0').filter(Boolean);
  const unexpected = untracked.filter((entry) =>
    !entry.startsWith(`${INPUT_ROOT}/`) && !entry.startsWith(`${RECEIPT_ROOT}/`)
  );
  if (unexpected.length > 0) {
    throw new Error(`git worktree has unexpected untracked files:\n${unexpected.join('\n')}`);
  }
  return targetHead;
}

function requireTrackedSourcesRemainClean(repoRoot) {
  const index = runGit(repoRoot, ['diff', '--quiet', '--cached', 'HEAD', '--'], true);
  const worktree = runGit(repoRoot, ['diff', '--quiet', 'HEAD', '--'], true);
  if (index.status !== 0 || worktree.status !== 0) {
    throw new Error('validator mutated tracked repository content');
  }
}

function currentSourceRef(repoRoot) {
  const configured = process.env.GITHUB_REF;
  if (typeof configured === 'string' && /^refs\/(heads|tags)\/[A-Za-z0-9._/-]+$/u.test(configured)) {
    return configured;
  }
  const result = runGit(repoRoot, ['symbolic-ref', '-q', 'HEAD'], true);
  const ref = result.stdout.trim();
  if (result.status !== 0 || !/^refs\/heads\/[A-Za-z0-9._/-]+$/u.test(ref)) {
    throw new Error('validator requires a canonical GITHUB_REF when HEAD is detached');
  }
  return ref;
}

export function parseArguments(argv) {
  const parsed = new Map();
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (!REQUIRED_FLAGS.includes(flag)) throw new Error(`unknown argument: ${flag}`);
    if (parsed.has(flag)) throw new Error(`${flag} may be specified only once`);
    const value = argv[index + 1];
    if (value === undefined || value.startsWith('--')) throw new Error(`${flag} requires a value`);
    parsed.set(flag, value);
    index += 1;
  }
  for (const flag of REQUIRED_FLAGS) if (!parsed.has(flag)) throw new Error(`${flag} is required`);
  return {
    requirementId: parsed.get('--requirement'),
    environmentId: parsed.get('--environment'),
    releaseClosurePath: parsed.get('--release-closure'),
    outputPath: parsed.get('--output')
  };
}

function loadRequirementContract(repoRoot, requirementId, environmentId) {
  if (!CANONICAL_REQUIREMENT_IDS.includes(requirementId)) {
    throw new Error(`requirement must be one of P-01 through P-40: ${requirementId}`);
  }
  if (!CANONICAL_ENVIRONMENT_IDS.includes(environmentId)) {
    throw new Error(`environment is not in the canonical minimum support matrix: ${environmentId}`);
  }
  const manifest = readJson(repoRoot, REQUIREMENTS_PATH, 'requirements manifest').value;
  if (manifest?.schemaVersion !== 1 || manifest?.id !== 'openburnbar-linux-macos-parity-v1') {
    throw new Error('requirements manifest has the wrong schemaVersion or id');
  }
  if (!Array.isArray(manifest.requirements) || !Array.isArray(manifest.minimumSupportMatrix)) {
    throw new Error('requirements manifest is missing requirements or minimumSupportMatrix');
  }
  const requirementIds = manifest.requirements.map((entry) => entry?.id);
  const environmentIds = manifest.minimumSupportMatrix.map((entry) => entry?.id);
  if (requirementIds.length !== 40 || requirementIds.some((id, index) => id !== CANONICAL_REQUIREMENT_IDS[index])) {
    throw new Error('requirements manifest must contain exactly P-01 through P-40 in order');
  }
  if (environmentIds.length !== 7 || environmentIds.some((id, index) => id !== CANONICAL_ENVIRONMENT_IDS[index])) {
    throw new Error('requirements manifest must contain the exact canonical environment matrix');
  }
  const requirement = manifest.requirements.find((entry) => entry.id === requirementId);
  const environment = manifest.minimumSupportMatrix.find((entry) => entry.id === environmentId);
  if (!AREA_PATTERN.test(requirement?.area ?? '')) throw new Error(`${requirementId} has a non-canonical area`);
  assertExactKeys(environment, ['id', 'os', 'desktop', 'session', 'architecture'], `${environmentId} matrix row`);
  return { checkId: `${requirementId.toLowerCase()}.${requirement.area}`, environment };
}

function normalizeArchitecture(value) {
  if (value === 'x64' || value === 'amd64') return 'x86_64';
  if (value === 'arm64') return 'aarch64';
  return value;
}

function parseOsRelease(source) {
  return Object.fromEntries(
    source.split('\n')
      .map((line) => line.match(/^([A-Z_]+)=(.*)$/u))
      .filter(Boolean)
      .map((match) => [match[1], match[2].replace(/^"|"$/gu, '')])
  );
}

function desktopMatches(expected, actual) {
  const normalized = actual.toLowerCase();
  if (expected === 'GNOME') return normalized.includes('gnome');
  if (expected === 'KDE Plasma') return normalized.includes('kde') || normalized.includes('plasma');
  if (expected === 'Sway/wlroots') return normalized.includes('sway');
  return false;
}

function osMatches(expected, release) {
  if (expected === 'Ubuntu 24.04') return release.ID === 'ubuntu' && release.VERSION_ID === '24.04';
  if (expected === 'Fedora') return release.ID === 'fedora';
  if (expected === 'Arch Linux') return release.ID === 'arch';
  return false;
}

function runHostCommand(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 10_000 });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed: ${(result.stderr || result.stdout || 'unknown error').trim()}`);
  }
  return result.stdout.trim();
}

function queryInstalledPackage(expected, runner = runHostCommand) {
  if (expected.os === 'Ubuntu 24.04') {
    const output = runner('dpkg-query', [
      '-W',
      '-f=${db:Status-Status}\t${Version}\t${Architecture}',
      'open-burn-bar'
    ]);
    const [status, version, architecture] = output.split('\t');
    return { manager: 'dpkg', name: 'open-burn-bar', status, version, architecture: normalizeArchitecture(architecture) };
  }
  if (expected.os === 'Fedora') {
    const output = runner('rpm', ['-q', '--qf', '%{NAME}\t%{VERSION}\t%{ARCH}', 'open-burn-bar']);
    const [name, version, architecture] = output.split('\t');
    return { manager: 'rpm', name, status: 'installed', version, architecture: normalizeArchitecture(architecture) };
  }
  const output = runner('pacman', ['-Q', 'openburnbar']);
  const [name, version] = output.split(/\s+/u);
  return { manager: 'pacman', name, status: 'installed', version, architecture: 'x86_64' };
}

function queryLogindSession(runner = runHostCommand) {
  const id = (process.env.XDG_SESSION_ID ?? '').trim();
  if (!/^[A-Za-z0-9_.-]+$/u.test(id)) {
    throw new Error('XDG_SESSION_ID must identify the live logind desktop session');
  }
  const property = (name) => runner('loginctl', ['show-session', id, `--property=${name}`, '--value']).trim();
  return {
    id,
    type: property('Type').toLowerCase(),
    desktop: property('Desktop'),
    class: property('Class').toLowerCase(),
    active: property('Active').toLowerCase() === 'yes',
    remote: property('Remote').toLowerCase() === 'yes',
    state: property('State').toLowerCase(),
    user: Number.parseInt(property('User'), 10)
  };
}

function defaultHostProbe(expected, installedManifest) {
  if (process.platform !== 'linux') throw new Error('product evidence must run on Linux');
  const release = parseOsRelease(fs.readFileSync('/etc/os-release', 'utf8'));
  const logind = queryLogindSession();
  const sessionType = (process.env.XDG_SESSION_TYPE ?? '').trim().toLowerCase();
  const desktop = (process.env.XDG_CURRENT_DESKTOP ?? process.env.DESKTOP_SESSION ?? '').trim();
  const packageState = queryInstalledPackage(expected);
  const checks = [
    ['os', osMatches(expected.os, release), `${release.ID ?? 'unknown'} ${release.VERSION_ID ?? ''}`.trim()],
    ['architecture', normalizeArchitecture(process.arch) === expected.architecture, normalizeArchitecture(process.arch)],
    ['session', sessionType === expected.session.toLowerCase(), sessionType || 'missing'],
    ['desktop', desktopMatches(expected.desktop, desktop), desktop || 'missing'],
    ['logind-session-type', logind.type === expected.session.toLowerCase(), logind.type || 'missing'],
    ['logind-desktop', desktopMatches(expected.desktop, logind.desktop), logind.desktop || 'missing'],
    ['logind-class', logind.class === 'user', logind.class || 'missing'],
    ['logind-active', logind.active, String(logind.active)],
    ['logind-local', !logind.remote, String(logind.remote)],
    ['logind-state', ['active', 'online'].includes(logind.state), logind.state || 'missing'],
    ['logind-user', logind.user === process.getuid(), String(logind.user)],
    ['dbus-session', Boolean(process.env.DBUS_SESSION_BUS_ADDRESS?.trim()), 'DBUS_SESSION_BUS_ADDRESS'],
    ['runtime-directory', Boolean(process.env.XDG_RUNTIME_DIR?.trim()), process.env.XDG_RUNTIME_DIR ?? 'missing'],
    ['package-status', packageState.status === 'installed', packageState.status ?? 'missing'],
    ['package-name', ['open-burn-bar', 'openburnbar'].includes(packageState.name), packageState.name ?? 'missing'],
    ['package-version', packageState.version === installedManifest.packageVersion, packageState.version ?? 'missing'],
    ['package-architecture', packageState.architecture === expected.architecture, packageState.architecture ?? 'missing']
  ];
  if (sessionType === 'wayland') {
    checks.push(['wayland-display', Boolean(process.env.WAYLAND_DISPLAY?.trim()), process.env.WAYLAND_DISPLAY ?? 'missing']);
  } else if (sessionType === 'x11') {
    checks.push(['x11-display', Boolean(process.env.DISPLAY?.trim()), process.env.DISPLAY ?? 'missing']);
  }
  if (expected.desktop === 'Sway/wlroots') {
    checks.push(['sway-socket', Boolean(process.env.SWAYSOCK?.trim()), process.env.SWAYSOCK ?? 'missing']);
  }
  return {
    schemaVersion: 1,
    environmentId: expected.id,
    platform: process.platform,
    os: { id: release.ID ?? null, versionId: release.VERSION_ID ?? null },
    architecture: normalizeArchitecture(process.arch),
    kernelRelease: os.release(),
    logind,
    session: {
      type: sessionType || null,
      desktop: desktop || null,
      display: process.env.DISPLAY ?? null,
      waylandDisplay: process.env.WAYLAND_DISPLAY ?? null,
      dbusSession: Boolean(process.env.DBUS_SESSION_BUS_ADDRESS?.trim()),
      runtimeDirectory: process.env.XDG_RUNTIME_DIR ?? null,
      swaySocket: process.env.SWAYSOCK ?? null
    },
    package: packageState,
    checks: checks.map(([id, passed, detail]) => ({ id, passed, detail })),
    passed: checks.every(([, passed]) => passed)
  };
}

function assertLiveEnvironmentManifest(manifest, expected, installedManifest, targetHead) {
  assertExactKeys(
    manifest,
    ['schemaVersion', 'environmentId', 'targetHead', 'platform', 'os', 'architecture', 'kernelRelease', 'logind', 'session', 'package', 'installVerification', 'checks', 'passed'],
    'live environment manifest'
  );
  if (manifest.schemaVersion !== 1 || manifest.environmentId !== expected.id || manifest.targetHead !== targetHead) {
    throw new Error('live environment manifest is not bound to the invocation');
  }
  if (manifest.platform !== 'linux' || !osMatches(expected.os, { ID: manifest.os?.id, VERSION_ID: manifest.os?.versionId })) {
    throw new Error('live environment operating system does not match the support row');
  }
  if (manifest.architecture !== expected.architecture) throw new Error('live environment architecture does not match the support row');
  if (manifest.session?.type !== expected.session.toLowerCase()) throw new Error('live environment session does not match the support row');
  if (!desktopMatches(expected.desktop, manifest.session?.desktop ?? '')) throw new Error('live environment desktop does not match the support row');
  if (manifest.logind?.type !== expected.session.toLowerCase()
      || !desktopMatches(expected.desktop, manifest.logind?.desktop ?? '')
      || manifest.logind?.class !== 'user' || manifest.logind?.active !== true
      || manifest.logind?.remote !== false || !['active', 'online'].includes(manifest.logind?.state)
      || !Number.isInteger(manifest.logind?.user) || manifest.logind.user < 1) {
    throw new Error('live logind session does not match the support row');
  }
  if (manifest.package?.version !== installedManifest.packageVersion
      || manifest.package?.architecture !== expected.architecture
      || manifest.package?.status !== 'installed') {
    throw new Error('live installed package does not match the signed package manifest');
  }
  if (!Array.isArray(manifest.checks) || manifest.checks.length === 0
      || manifest.checks.some((check) => check?.passed !== true) || manifest.passed !== true) {
    throw new Error('live environment manifest contains a failed or missing check');
  }
}

export function canonicalOutputPath(requirementId, checkId, environmentId) {
  return `${RECEIPT_ROOT}/${requirementId}/${checkId}/${environmentId}.json`;
}

function artifactRoot(requirementId) {
  return `${INPUT_ROOT}/${requirementId}`;
}

function liveEvidencePaths(requirementId, environmentId) {
  const root = `${artifactRoot(requirementId)}/${environmentId}`;
  return {
    environment: `${root}/live-environment-manifest.json`,
    installedManifest: `${root}/live-installed-manifest.json`,
    installedSignature: `${root}/live-installed-manifest.json.sig`,
    releasePublicKey: `${root}/live-release-ed25519.pub.pem`,
    installVerification: `${root}/live-install-verification.json`,
    runtime: `${root}/live-runtime-capabilities.json`,
    runtimeFinal: `${root}/live-runtime-capabilities-final.json`
  };
}

function artifactIsRequirementOwned(relativePath, requirementId) {
  const root = artifactRoot(requirementId);
  return relativePath === root || relativePath.startsWith(`${root}/`);
}

function validateSubjectRecord(repoRoot, record, label, requirementId) {
  if (record === null || typeof record !== 'object' || Array.isArray(record)) {
    throw new Error(`${label} must be an object`);
  }
  const relativePath = record.path ?? record.file;
  if (typeof relativePath !== 'string' || !SHA256_PATTERN.test(record.sha256 ?? '')) {
    throw new Error(`${label} must contain a path or file and a lowercase sha256`);
  }
  const source = readFileSnapshot(repoRoot, relativePath, label);
  if (!artifactIsRequirementOwned(source.path, requirementId)) {
    throw new Error(`${label} must be under ${artifactRoot(requirementId)}`);
  }
  if (source.sha256 !== record.sha256) throw new Error(`${label} sha256 does not match its bytes`);
  return { path: source.path, sha256: source.sha256, bytes: source.bytes };
}

function validateJsonSchema(value, schema, label) {
  const ajv = new Ajv2020({ allErrors: true, strict: true });
  const validate = ajv.compile(schema);
  if (!validate(value)) {
    const detail = validate.errors?.map((error) => `${error.instancePath || '/'} ${error.message}`).join('; ');
    throw new Error(`${label} does not satisfy its canonical schema: ${detail ?? 'unknown schema error'}`);
  }
}

function parseSubjectJson(subject, label) {
  try {
    return JSON.parse(subject.bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function validateInstalledPackageManifest(repoRoot, subject, targetHead, expected) {
  const manifest = parseSubjectJson(subject, 'package manifest subject');
  const schema = readJson(repoRoot, INSTALLED_MANIFEST_SCHEMA_PATH, 'installed package manifest schema').value;
  validateJsonSchema(manifest, schema, 'package manifest subject');
  if (manifest.gitCommit !== targetHead) throw new Error('package manifest gitCommit does not match current HEAD');
  if (manifest.packageArchitecture !== expected.architecture) {
    throw new Error('package manifest architecture does not match the support row');
  }
  const expectedFormat = expected.os === 'Ubuntu 24.04' ? 'deb' : expected.os === 'Fedora' ? 'rpm' : null;
  if (expectedFormat === null) {
    throw new Error('Arch product evidence is blocked until the AUR installed-manifest lifecycle is promoted');
  }
  if (manifest.packageFormat !== expectedFormat) {
    throw new Error(`package manifest format must be ${expectedFormat} for ${expected.os}`);
  }
  for (const requiredPath of ['/usr/bin/openburnbar-daemon', '/usr/bin/openburnbar-linux-desktop']) {
    if (!manifest.files.some((entry) => entry.path === requiredPath && entry.type === 'file')) {
      throw new Error(`package manifest does not bind required installed binary ${requiredPath}`);
    }
  }
  return manifest;
}

function validateRuntimeCapabilityManifest(repoRoot, subject, installedManifest, expected) {
  const manifest = parseSubjectJson(subject, 'runtime manifest subject');
  const schema = readJson(repoRoot, RUNTIME_MANIFEST_SCHEMA_PATH, 'runtime capability manifest schema').value;
  validateJsonSchema(manifest, schema, 'runtime manifest subject');
  for (const field of ['daemonVersion', 'daemonProtocolVersion', 'sessionType', 'desktop']) {
    if (manifest[field] === null || manifest[field] === undefined || manifest[field] === '') {
      throw new Error(`runtime manifest ${field} is required for product parity evidence`);
    }
  }
  if (manifest.shellVersion !== installedManifest.packageVersion
      || manifest.daemonVersion !== installedManifest.packageVersion) {
    throw new Error('runtime manifest versions do not match the signed package manifest');
  }
  if (manifest.sessionType.toLowerCase() !== expected.session.toLowerCase()
      || !desktopMatches(expected.desktop, manifest.desktop)) {
    throw new Error('runtime manifest desktop session does not match the support row');
  }
  const catalog = readJson(repoRoot, RUNTIME_CAPABILITY_CATALOG_PATH, 'runtime capability catalog').value;
  const expectedIds = catalog.capabilities.map((entry) => entry.id).sort();
  const actualIds = manifest.capabilities.map((entry) => entry.id).sort();
  if (actualIds.length !== expectedIds.length || actualIds.some((id, index) => id !== expectedIds[index])) {
    throw new Error('runtime manifest capability inventory does not exactly match the canonical catalog');
  }
  return manifest;
}

function assertLiveInstallResult(result, packageManifestSubject, installedManifest) {
  assertExactKeys(
    result,
    ['schemaVersion', 'manifestBytes', 'signatureBytes', 'publicKeyBytes', 'verification'],
    'live install verification result'
  );
  if (result.schemaVersion !== 1 || !Buffer.isBuffer(result.manifestBytes)
      || !Buffer.isBuffer(result.signatureBytes) || !Buffer.isBuffer(result.publicKeyBytes)) {
    throw new Error('live install verification result has invalid binary evidence');
  }
  if (result.manifestBytes.length !== packageManifestSubject.bytes.length
      || !crypto.timingSafeEqual(result.manifestBytes, packageManifestSubject.bytes)) {
    throw new Error('live installed manifest bytes do not match the release closure subject');
  }
  const verification = result.verification;
  assertExactKeys(
    verification,
    ['schemaVersion', 'liveManifestSha256', 'signatureSha256', 'publicKeySha256', 'installedFilesRootSha256', 'installedFileCount', 'packageOwnedPathCount', 'authorizedDaemonSha256', 'passed'],
    'live install verification summary'
  );
  const daemon = installedManifest.authorizedClients.find((entry) => entry.role === 'daemon');
  if (verification.schemaVersion !== 1 || verification.passed !== true
      || verification.liveManifestSha256 !== packageManifestSubject.sha256
      || verification.signatureSha256 !== crypto.createHash('sha256').update(result.signatureBytes).digest('hex')
      || verification.publicKeySha256 !== crypto.createHash('sha256').update(result.publicKeyBytes).digest('hex')
      || verification.installedFilesRootSha256 !== installedManifest.installedFilesRootSha256
      || verification.installedFileCount !== installedManifest.files.length
      || verification.packageOwnedPathCount !== installedManifest.files.length + 2
      || verification.authorizedDaemonSha256 !== daemon?.sha256) {
    throw new Error('live install verification summary is not bound to the signed installed payload');
  }
}

function assertLiveEvidenceUnchanged(initial, final, label) {
  for (const field of ['manifestBytes', 'signatureBytes', 'publicKeyBytes']) {
    if (initial[field].length !== final[field].length
        || !crypto.timingSafeEqual(initial[field], final[field])) {
      throw new Error(`${label} changed while the requirement validator was running`);
    }
  }
  if (JSON.stringify(initial.verification) !== JSON.stringify(final.verification)) {
    throw new Error(`${label} verification summary changed while the requirement validator was running`);
  }
}

function normalizedRecords(value, label) {
  if (value === undefined) return null;
  const records = Array.isArray(value) ? value : [value];
  if (records.length === 0) throw new Error(`${label} must be nonempty`);
  return records;
}

function closureRecordsByType(closure, types) {
  if (!Array.isArray(closure.artifacts)) return [];
  return closure.artifacts.filter((record) => types.has(String(record?.type ?? '').toLowerCase()));
}

export function deriveReleaseSubjects(repoRoot, releaseClosurePath, requirementId, targetHead, expectedEnvironment) {
  const closureSource = readJson(repoRoot, releaseClosurePath, 'release closure');
  if (!artifactIsRequirementOwned(closureSource.path, requirementId)) {
    throw new Error(`release closure must be under ${artifactRoot(requirementId)}`);
  }
  const closure = closureSource.value;
  if (closure === null || typeof closure !== 'object' || Array.isArray(closure)) {
    throw new Error('release closure must be an object');
  }
  if (!Number.isInteger(closure.schemaVersion) || closure.schemaVersion < 1) {
    throw new Error('release closure must have a positive integer schemaVersion');
  }
  const closureTarget = closure.targetHead ?? closure.targetCommit ?? closure.git?.commit;
  const closureSourceCommit = closure.sourceCommit ?? closure.source?.commit ?? closure.git?.commit;
  if (closureTarget !== targetHead) throw new Error('release closure target commit does not match current HEAD');
  if (closureSourceCommit !== targetHead) throw new Error('release closure source commit does not match current HEAD');
  if (closure.git?.dirty === true) throw new Error('release closure describes a dirty source checkout');
  if (Array.isArray(closure.blockers) && closure.blockers.length > 0) throw new Error('release closure contains blockers');
  if (Object.hasOwn(closure, 'passed') && closure.passed !== true) throw new Error('release closure is not passed');
  if (Object.hasOwn(closure, 'status') && closure.status !== 'passed') throw new Error('release closure status is not passed');

  const packageRecords = normalizedRecords(closure.packages, 'release closure packages')
    ?? closureRecordsByType(closure, PACKAGE_TYPES);
  const packageManifestRecords = normalizedRecords(
    closure.packageManifest,
    'release closure packageManifest'
  );
  if (packageManifestRecords === null || packageManifestRecords.length !== 1) {
    throw new Error('environment release closure must identify exactly one package manifest');
  }
  if (packageRecords.length === 0) throw new Error('release closure has no package subjects');
  if (packageRecords.length !== 1) throw new Error('environment release closure must identify exactly one installed package');
  if (closure.runtime !== undefined || closure.runtimes !== undefined) {
    throw new Error('release closure must not supply runtime capability evidence; it is captured from the live installed shell');
  }

  const release = { path: closureSource.path, sha256: closureSource.sha256 };
  const packageManifest = validateSubjectRecord(
    repoRoot,
    packageManifestRecords[0],
    'package manifest subject',
    requirementId
  );
  const packages = packageRecords.map((record, index) =>
    validateSubjectRecord(repoRoot, record, `package subject ${index}`, requirementId)
  );
  const installedManifest = validateInstalledPackageManifest(
    repoRoot,
    packageManifest,
    targetHead,
    expectedEnvironment
  );
  const expectedPackageSuffix = installedManifest.packageFormat === 'deb' ? '.deb' : '.rpm';
  if (!packages[0].path.endsWith(expectedPackageSuffix)) {
    throw new Error(`installed package artifact must end in ${expectedPackageSuffix}`);
  }
  const all = [release, packageManifest, ...packages];
  const paths = new Set();
  for (const subject of all) {
    if (paths.has(subject.path)) throw new Error(`release closure repeats subject path: ${subject.path}`);
    paths.add(subject.path);
  }
  return { closure, release, packageManifest, packages, runtimes: [], all, installedManifest };
}

function validateModuleResult(repoRoot, result, context, subjects) {
  assertExactKeys(result, RECEIPT_FIELDS, 'validator result');
  if (result.schemaVersion !== 1) throw new Error('validator result schemaVersion must be 1');
  if (result.requirementId !== context.requirementId) throw new Error('validator result requirementId is not bound to the invocation');
  if (result.checkId !== context.checkId) throw new Error('validator result checkId is not bound to the requirement');
  if (result.environmentId !== context.environmentId) throw new Error('validator result environmentId is not bound to the invocation');
  if (result.targetHead !== context.targetHead) throw new Error('validator result targetHead is not current HEAD');
  if (result.status !== 'passed') throw new Error('validator result status must be passed');
  if (!Array.isArray(result.artifacts) || result.artifacts.length === 0) {
    throw new Error('validator result must contain artifacts');
  }

  const artifacts = [];
  const byPath = new Map();
  for (const [index, artifact] of result.artifacts.entries()) {
    assertExactKeys(artifact, ARTIFACT_FIELDS, `validator result artifact ${index}`);
    if (!SHA256_PATTERN.test(artifact.sha256 ?? '')) throw new Error(`validator result artifact ${index} has an invalid sha256`);
    const source = resolveRegularFile(repoRoot, artifact.path, `validator result artifact ${index}`);
    if (!artifactIsRequirementOwned(source.path, context.requirementId)) {
      throw new Error(`validator result artifact must be under ${artifactRoot(context.requirementId)}`);
    }
    if (byPath.has(source.path)) throw new Error(`validator result duplicates artifact: ${source.path}`);
    const actual = sha256File(source.absolute);
    if (artifact.sha256 !== actual) throw new Error(`validator result artifact hash mismatch: ${source.path}`);
    const normalized = { path: source.path, sha256: actual };
    artifacts.push(normalized);
    byPath.set(source.path, normalized);
  }
  for (const subject of subjects.all) {
    if (byPath.get(subject.path)?.sha256 !== subject.sha256) {
      throw new Error(`validator result omits or changes release subject: ${subject.path}`);
    }
  }
  return artifacts.sort((left, right) => left.path.localeCompare(right.path));
}

function removeOutput(repoRoot, relativePath) {
  const canonical = canonicalRelativePath(relativePath, 'output path');
  const absolute = path.resolve(repoRoot, canonical);
  if (!isInside(repoRoot, absolute)) throw new Error('output path escapes the repository');
  assertNoSymlinkComponents(repoRoot, path.dirname(absolute), 'output directory', true);
  try {
    fs.rmSync(absolute, { force: true });
  } catch (error) {
    throw new Error(`failed to remove stale output ${canonical}: ${error.message}`);
  }
}

function ensureOutputParent(repoRoot, relativePath) {
  const canonical = canonicalRelativePath(relativePath, 'output path');
  const absolute = path.resolve(repoRoot, canonical);
  if (!isInside(repoRoot, absolute)) throw new Error('output path escapes the repository');
  const parent = path.dirname(absolute);
  assertNoSymlinkComponents(repoRoot, parent, 'output directory', true);
  fs.mkdirSync(parent, { recursive: true });
  assertNoSymlinkComponents(repoRoot, parent, 'output directory');
  return absolute;
}

function atomicWriteJson(repoRoot, relativePath, value) {
  atomicWriteBuffer(repoRoot, relativePath, Buffer.from(`${JSON.stringify(value, null, 2)}\n`, 'utf8'));
}

function atomicWriteBuffer(repoRoot, relativePath, bytes) {
  const output = ensureOutputParent(repoRoot, relativePath);
  const temporary = `${output}.tmp-${process.pid}-${crypto.randomBytes(8).toString('hex')}`;
  try {
    const handle = fs.openSync(temporary, 'wx', 0o600);
    try {
      fs.writeFileSync(handle, bytes);
      fs.fsyncSync(handle);
    } finally {
      fs.closeSync(handle);
    }
    fs.renameSync(temporary, output);
    const directory = fs.openSync(path.dirname(output), 'r');
    try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

function safePreflightCleanup(argv, repoRoot) {
  try {
    const values = new Map();
    for (let index = 0; index < argv.length - 1; index += 1) {
      if (REQUIRED_FLAGS.includes(argv[index]) && !values.has(argv[index])) values.set(argv[index], argv[index + 1]);
    }
    const requirementId = values.get('--requirement');
    const environmentId = values.get('--environment');
    const requestedOutput = values.get('--output');
    if (!CANONICAL_REQUIREMENT_IDS.includes(requirementId) || !CANONICAL_ENVIRONMENT_IDS.includes(environmentId)) return;
    const { checkId } = loadRequirementContract(repoRoot, requirementId, environmentId);
    const expected = canonicalOutputPath(requirementId, checkId, environmentId);
    if (requestedOutput === expected) removeOutput(repoRoot, expected);
  } catch {
    // Cleanup is best-effort here. The normal validation path reports the authoritative error.
  }
}

function defaultRepoRoot() {
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
}

export async function runProductRequirementValidator(options) {
  const repoRoot = fs.realpathSync(options.repoRoot);
  const { requirementId, environmentId, releaseClosurePath, outputPath } = options;
  const { checkId, environment } = loadRequirementContract(repoRoot, requirementId, environmentId);
  const expectedOutput = canonicalOutputPath(requirementId, checkId, environmentId);
  if (outputPath !== expectedOutput) throw new Error(`--output must be exactly ${expectedOutput}`);
  const expectedClosure = `${artifactRoot(requirementId)}/${environmentId}/release-closure.json`;
  if (releaseClosurePath !== expectedClosure) {
    throw new Error(`--release-closure must be exactly ${expectedClosure}`);
  }
  const livePaths = liveEvidencePaths(requirementId, environmentId);
  removeOutput(repoRoot, expectedOutput);
  for (const generatedPath of Object.values(livePaths)) removeOutput(repoRoot, generatedPath);
  try {
    const targetHead = requireCleanCurrentHead(repoRoot);
    const subjects = deriveReleaseSubjects(
      repoRoot,
      releaseClosurePath,
      requirementId,
      targetHead,
      environment
    );
    const installProbe = options.liveInstallProbe ?? ((probeOptions) => verifyLiveInstalledProduct(probeOptions));
    const liveInstall = await installProbe({
      installedManifest: subjects.installedManifest,
      expectedManifestBytes: subjects.packageManifest.bytes,
      installedRoot: options.installedRoot ?? '/'
    });
    assertLiveInstallResult(liveInstall, subjects.packageManifest, subjects.installedManifest);
    atomicWriteBuffer(repoRoot, livePaths.installedManifest, liveInstall.manifestBytes);
    atomicWriteBuffer(repoRoot, livePaths.installedSignature, liveInstall.signatureBytes);
    atomicWriteBuffer(repoRoot, livePaths.releasePublicKey, liveInstall.publicKeyBytes);
    atomicWriteJson(repoRoot, livePaths.installVerification, liveInstall.verification);
    const installationSubjects = [
      [livePaths.installedManifest, 'live installed manifest'],
      [livePaths.installedSignature, 'live installed manifest signature'],
      [livePaths.releasePublicKey, 'live release public key'],
      [livePaths.installVerification, 'live install verification']
    ].map(([subjectPath, label]) => readFileSnapshot(repoRoot, subjectPath, label));

    const runtimeProbe = options.runtimeProbe ?? (() => captureLiveRuntimeCapabilities());
    const runtimeCapture = await runtimeProbe({
      expectedEnvironment: environment,
      installedManifest: subjects.installedManifest
    });
    assertExactKeys(runtimeCapture, ['bytes'], 'live runtime capability capture');
    if (!Buffer.isBuffer(runtimeCapture.bytes)) {
      throw new Error('live runtime capability capture bytes must be a Buffer');
    }
    atomicWriteBuffer(repoRoot, livePaths.runtime, runtimeCapture.bytes);
    const liveRuntimeSubject = readFileSnapshot(repoRoot, livePaths.runtime, 'live runtime capability manifest');
    const runtimeManifest = validateRuntimeCapabilityManifest(
      repoRoot,
      liveRuntimeSubject,
      subjects.installedManifest,
      environment
    );
    subjects.runtimes = [liveRuntimeSubject];
    subjects.runtimeManifest = runtimeManifest;

    const probe = options.hostProbe ?? defaultHostProbe;
    const detectedEnvironment = await probe(environment, subjects.installedManifest);
    const installVerificationSource = installationSubjects.find(
      (subject) => subject.path === livePaths.installVerification
    );
    const liveEnvironment = {
      ...detectedEnvironment,
      targetHead,
      installVerification: {
        path: installVerificationSource.path,
        sha256: installVerificationSource.sha256
      }
    };
    assertLiveEnvironmentManifest(liveEnvironment, environment, subjects.installedManifest, targetHead);
    const liveEnvironmentPath = livePaths.environment;
    atomicWriteJson(repoRoot, liveEnvironmentPath, liveEnvironment);
    const liveEnvironmentSource = readFileSnapshot(
      repoRoot,
      liveEnvironmentPath,
      'live environment manifest'
    );
    const liveEnvironmentSubject = {
      path: liveEnvironmentSource.path,
      sha256: liveEnvironmentSource.sha256,
      bytes: liveEnvironmentSource.bytes
    };
    subjects.installation = installationSubjects;
    subjects.all.push(...installationSubjects, liveRuntimeSubject, liveEnvironmentSubject);
    const validatorPath = `${VALIDATOR_ROOT}/${requirementId}.mjs`;
    const validatorSource = resolveRegularFile(repoRoot, validatorPath, `${requirementId} validator module`);
    const validatorModule = await import(`${pathToFileURL(validatorSource.absolute).href}?head=${targetHead}`);
    if (Object.keys(validatorModule).length !== 1 || typeof validatorModule.validateProductRequirement !== 'function') {
      throw new Error(`${requirementId} validator module must export only validateProductRequirement`);
    }
    const context = Object.freeze({
      schemaVersion: 1,
      repoRoot,
      requirementId,
      checkId,
      environmentId,
      targetHead,
      releaseClosure: Object.freeze({
        path: subjects.release.path,
        sha256: subjects.release.sha256,
        document: subjects.closure
      }),
      subjects: Object.freeze({
        release: Object.freeze({ path: subjects.release.path, sha256: subjects.release.sha256 }),
        packageManifest: Object.freeze({ path: subjects.packageManifest.path, sha256: subjects.packageManifest.sha256 }),
        packages: Object.freeze(subjects.packages.map(({ path: subjectPath, sha256 }) => Object.freeze({ path: subjectPath, sha256 }))),
        runtimes: Object.freeze(subjects.runtimes.map(({ path: subjectPath, sha256 }) => Object.freeze({ path: subjectPath, sha256 }))),
        installation: Object.freeze(subjects.installation.map(({ path: subjectPath, sha256 }) => Object.freeze({ path: subjectPath, sha256 }))),
        environment: Object.freeze({ path: liveEnvironmentSubject.path, sha256: liveEnvironmentSubject.sha256 })
      })
    });
    const result = await validatorModule.validateProductRequirement(context);
    const finalLiveInstall = await installProbe({
      installedManifest: subjects.installedManifest,
      expectedManifestBytes: subjects.packageManifest.bytes,
      installedRoot: options.installedRoot ?? '/'
    });
    assertLiveInstallResult(finalLiveInstall, subjects.packageManifest, subjects.installedManifest);
    assertLiveEvidenceUnchanged(liveInstall, finalLiveInstall, 'live installed product');
    const finalRuntimeCapture = await runtimeProbe({
      expectedEnvironment: environment,
      installedManifest: subjects.installedManifest
    });
    assertExactKeys(finalRuntimeCapture, ['bytes'], 'final live runtime capability capture');
    if (!Buffer.isBuffer(finalRuntimeCapture.bytes)) {
      throw new Error('final live runtime capability capture bytes must be a Buffer');
    }
    atomicWriteBuffer(repoRoot, livePaths.runtimeFinal, finalRuntimeCapture.bytes);
    const finalRuntimeSubject = readFileSnapshot(
      repoRoot,
      livePaths.runtimeFinal,
      'final live runtime capability manifest'
    );
    validateRuntimeCapabilityManifest(
      repoRoot,
      finalRuntimeSubject,
      subjects.installedManifest,
      environment
    );
    const finalDetectedEnvironment = await probe(environment, subjects.installedManifest);
    const finalLiveEnvironment = {
      ...finalDetectedEnvironment,
      targetHead,
      installVerification: liveEnvironment.installVerification
    };
    assertLiveEnvironmentManifest(finalLiveEnvironment, environment, subjects.installedManifest, targetHead);
    if (JSON.stringify(finalLiveEnvironment) !== JSON.stringify(liveEnvironment)) {
      throw new Error('live environment identity changed while the requirement validator was running');
    }
    requireTrackedSourcesRemainClean(repoRoot);
    const headAfterValidation = requireCleanCurrentHead(repoRoot);
    if (headAfterValidation !== targetHead) throw new Error('git HEAD changed while the validator was running');
    const artifacts = validateModuleResult(repoRoot, result, context, subjects);
    if (artifacts.some((artifact) => artifact.path === finalRuntimeSubject.path)) {
      throw new Error('validator result unexpectedly claimed the dispatcher-owned final runtime capture');
    }
    artifacts.push({ path: finalRuntimeSubject.path, sha256: finalRuntimeSubject.sha256 });
    artifacts.sort((left, right) => left.path.localeCompare(right.path));
    const receipt = {
      schemaVersion: 2,
      requirementId,
      checkId,
      environmentId,
      targetHead,
      status: 'passed',
      subject: {
        releaseClosureSha256: subjects.release.sha256,
        packageManifestSha256: subjects.packageManifest.sha256,
        installedEnvironmentSha256: liveEnvironmentSubject.sha256,
        runtimeManifestSha256: finalRuntimeSubject.sha256
      },
      producer: {
        id: 'openburnbar-linux-product-validator',
        version: 1,
        command: [
          'node scripts/linux-port/run-product-requirement-validator.mjs',
          `--requirement ${requirementId}`,
          `--environment ${environmentId}`,
          `--release-closure ${releaseClosurePath}`,
          `--output ${outputPath}`
        ].join(' '),
        sourceTree: targetHead,
        repository: PRODUCER_REPOSITORY,
        workflow: PRODUCER_WORKFLOW,
        sourceRef: currentSourceRef(repoRoot)
      },
      artifacts
    };
    assertExactKeys(receipt, RECEIPT_SCHEMA_FIELDS, 'emitted receipt');
    atomicWriteJson(repoRoot, expectedOutput, receipt);
    return { receipt, outputPath: expectedOutput };
  } catch (error) {
    removeOutput(repoRoot, expectedOutput);
    for (const generatedPath of Object.values(livePaths)) removeOutput(repoRoot, generatedPath);
    throw error;
  }
}

export async function main(argv = process.argv.slice(2), repoRoot = defaultRepoRoot(), options = {}) {
  safePreflightCleanup(argv, repoRoot);
  const parsed = parseArguments(argv);
  return runProductRequirementValidator({ repoRoot, ...parsed, ...options });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = await main();
    process.stdout.write(`${JSON.stringify(result.receipt, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`product requirement validation failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
