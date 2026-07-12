import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

export const PRODUCT_PROOF_CLOSURE_SCHEMA_VERSION = 2;
export const REQUIREMENT_RELEASE_CLOSURE_SCHEMA_VERSION = 3;
export const RELEASE_ARCHITECTURES = Object.freeze(['aarch64', 'x86_64']);
export const SUPPORT_ENVIRONMENTS = Object.freeze([
  'ubuntu-24.04-gnome-x11-x86_64',
  'ubuntu-24.04-gnome-x11-aarch64',
  'ubuntu-24.04-gnome-wayland-x86_64',
  'ubuntu-24.04-gnome-wayland-aarch64',
  'fedora-kde-wayland-x86_64',
  'fedora-kde-wayland-aarch64',
  'arch-sway-wayland-x86_64'
]);

const SHA256 = /^[a-f0-9]{64}$/u;
const HEAD = /^[a-f0-9]{40,64}$/u;

export function sha256Bytes(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

export function readRegularSnapshot(root, relativePath, label) {
  if (typeof relativePath !== 'string' || relativePath.trim() !== relativePath
      || relativePath.length === 0 || relativePath.includes('\\')
      || path.posix.isAbsolute(relativePath) || path.posix.normalize(relativePath) !== relativePath
      || relativePath === '..' || relativePath.startsWith('../')) {
    throw new Error(`${label} must be a canonical relative POSIX path`);
  }
  const resolvedRoot = fs.realpathSync(root);
  const candidate = path.resolve(resolvedRoot, relativePath);
  const relative = path.relative(resolvedRoot, candidate);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} escapes its evidence root`);
  }
  let current = resolvedRoot;
  for (const component of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink()) throw new Error(`${label} traverses a symlink`);
  }
  const descriptor = fs.openSync(candidate, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
  try {
    const before = fs.fstatSync(descriptor);
    if (!before.isFile()) throw new Error(`${label} must be a regular file`);
    const bytes = fs.readFileSync(descriptor);
    const after = fs.fstatSync(descriptor);
    if (before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size
        || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs) {
      throw new Error(`${label} changed while it was read`);
    }
    return { path: relativePath, absolute: candidate, bytes, sha256: sha256Bytes(bytes), size: bytes.length };
  } finally {
    fs.closeSync(descriptor);
  }
}

export function validateRecord(root, record, label) {
  if (record === null || typeof record !== 'object' || Array.isArray(record)
      || !SHA256.test(record.sha256 ?? '')) {
    throw new Error(`${label} must contain a canonical path and lowercase SHA-256`);
  }
  const snapshot = readRegularSnapshot(root, record.path ?? record.file, label);
  if (snapshot.sha256 !== record.sha256) throw new Error(`${label} SHA-256 does not match its bytes`);
  if (record.size !== undefined && record.size !== snapshot.size) throw new Error(`${label} size does not match its bytes`);
  return snapshot;
}

export function assertExactStringSet(actual, expected, label) {
  if (!Array.isArray(actual) || actual.some((entry) => typeof entry !== 'string')) {
    throw new Error(`${label} must be a string array`);
  }
  const normalized = [...new Set(actual)].sort();
  const wanted = [...expected].sort();
  if (normalized.length !== actual.length || normalized.length !== wanted.length
      || normalized.some((entry, index) => entry !== wanted[index])) {
    throw new Error(`${label} must be exactly: ${wanted.join(', ')}`);
  }
}

export function validateAggregateDocument(document) {
  if (document?.schemaVersion !== PRODUCT_PROOF_CLOSURE_SCHEMA_VERSION
      || document?.stage !== 'candidate' || document?.status !== 'passed'
      || !HEAD.test(document?.targetHead ?? '')
      || document.sourceCommit !== document.targetHead || document.git?.dirty !== false
      || !Array.isArray(document.blockers) || document.blockers.length !== 0) {
    throw new Error('aggregate product proof closure is not a clean passed source-bound closure');
  }
  assertExactStringSet(document.architectures, RELEASE_ARCHITECTURES, 'aggregate architectures');
  assertExactStringSet(document.supportEnvironments, SUPPORT_ENVIRONMENTS, 'aggregate support environments');
  const releaseTypes = ['appimage', 'daemon', 'deb', 'rpm'];
  if (!Array.isArray(document.releaseArtifacts) || document.releaseArtifacts.length !== releaseTypes.length * RELEASE_ARCHITECTURES.length) {
    throw new Error('aggregate product proof closure must contain the complete release artifact matrix');
  }
  const expectedReleaseKeys = new Set(releaseTypes.flatMap((type) =>
    RELEASE_ARCHITECTURES.map((architecture) => `${type}:${architecture}`)
  ));
  const actualReleaseKeys = new Set();
  for (const row of document.releaseArtifacts) {
    const key = `${row?.type}:${row?.architecture}`;
    if (!expectedReleaseKeys.has(key) || actualReleaseKeys.has(key)) {
      throw new Error(`invalid or duplicate aggregate release artifact row: ${key}`);
    }
    actualReleaseKeys.add(key);
    for (const field of ['artifact', 'detachedSignature', 'sigstore']) {
      if (!row?.[field]) throw new Error(`aggregate release artifact row ${key} is missing ${field}`);
    }
  }
  if (!Array.isArray(document.packages) || document.packages.length !== 4) {
    throw new Error('aggregate product proof closure must contain deb and rpm packages for both architectures');
  }
  const expectedKeys = new Set(RELEASE_ARCHITECTURES.flatMap((architecture) => [
    `deb:${architecture}`,
    `rpm:${architecture}`
  ]));
  const actualKeys = new Set();
  for (const row of document.packages) {
    const key = `${row?.format}:${row?.architecture}`;
    if (!expectedKeys.has(key) || actualKeys.has(key)) throw new Error(`invalid or duplicate aggregate package row: ${key}`);
    actualKeys.add(key);
    for (const field of ['artifact', 'installedManifest', 'installedManifestSignature']) {
      if (!row?.[field]) throw new Error(`aggregate package row ${key} is missing ${field}`);
    }
  }
  if (!Array.isArray(document.proofs) || document.proofs.length === 0) {
    throw new Error('aggregate product proof closure has no proof subjects');
  }
  if (document.featureProofRegistry === null || typeof document.featureProofRegistry !== 'object'
      || Array.isArray(document.featureProofRegistry)
      || typeof document.featureProofRegistry.path !== 'string'
      || !SHA256.test(document.featureProofRegistry.sha256 ?? '')
      || !Number.isInteger(document.featureProofRegistry.size) || document.featureProofRegistry.size < 0) {
    throw new Error('aggregate product proof closure has no immutable feature proof registry');
  }
  return document;
}

export function environmentPackage(environmentId) {
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId)) throw new Error(`unknown support environment: ${environmentId}`);
  const architecture = environmentId.endsWith('-aarch64') ? 'aarch64' : 'x86_64';
  if (environmentId.startsWith('ubuntu-')) return { architecture, format: 'deb' };
  if (environmentId.startsWith('fedora-')) return { architecture, format: 'rpm' };
  throw new Error('Arch product evidence remains blocked until a signed AUR installed-manifest lifecycle exists');
}

export function atomicWriteJson(file, value) {
  atomicWriteBytes(file, Buffer.from(`${JSON.stringify(value, null, 2)}\n`, 'utf8'));
}

export function atomicWriteBytes(file, bytes) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}-${crypto.randomBytes(8).toString('hex')}`;
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
