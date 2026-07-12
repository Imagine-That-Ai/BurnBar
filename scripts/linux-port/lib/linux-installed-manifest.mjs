import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

export const INSTALLED_MANIFEST_PATH = '/usr/share/openburnbar/attestation/installed-manifest.json';
export const INSTALLED_MANIFEST_SIGNATURE_PATH = `${INSTALLED_MANIFEST_PATH}.sig`;
export const RELEASE_PUBLIC_KEY_PATH = '/usr/share/openburnbar/attestation/release-ed25519.pub.pem';

const MANIFEST_KEYS = Object.freeze([
  'appId',
  'authorizedClients',
  'brokerProtocolVersion',
  'files',
  'firebaseAppId',
  'gitCommit',
  'installedFilesRootSha256',
  'packageArchitecture',
  'packageFormat',
  'packageName',
  'packageVersion',
  'policyId',
  'product',
  'schemaVersion'
]);
const SHA256 = /^[a-f0-9]{64}$/u;
const VERSION = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;
const FIREBASE_APP_ID = /^1:[0-9]+:web:[A-Za-z0-9_-]+$/u;
const MODE = /^[0-7]{4}$/u;
const FILE_KEYS = Object.freeze(['gid', 'mode', 'path', 'sha256', 'size', 'type', 'uid']);
const SYMLINK_KEYS = Object.freeze(['gid', 'mode', 'path', 'target', 'type', 'uid']);
const AUTHORIZED_CLIENT_KEYS = Object.freeze([
  'mode', 'ownerGid', 'ownerUid', 'path', 'role', 'sha256'
]);

function compareUtf8(left, right) {
  return Buffer.compare(Buffer.from(left, 'utf8'), Buffer.from(right, 'utf8'));
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value).sort(compareUtf8).map((key) => [key, canonicalize(value[key])])
    );
  }
  return value;
}

export function canonicalJsonBytes(value) {
  return Buffer.from(`${JSON.stringify(canonicalize(value))}\n`, 'utf8');
}

export function sha256Bytes(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function normalizedMode(stat) {
  return (stat.mode & 0o7777).toString(8).padStart(4, '0');
}

function recordLine(file) {
  return file.type === 'file'
    ? `${file.path}\0file\0${file.sha256}\0${file.size}\0${file.mode}\0${file.uid}\0${file.gid}`
    : `${file.path}\0symlink\0${file.target}\0${file.mode}\0${file.uid}\0${file.gid}`;
}

export function installedFilesRoot(files) {
  const lines = files.map(recordLine).sort(compareUtf8);
  return sha256Bytes(Buffer.from(lines.join('\n'), 'utf8'));
}

function ownership(stat, installedPath, metadataProvider) {
  const value = metadataProvider ? metadataProvider({ stat, installedPath }) : stat;
  if (!Number.isInteger(value?.uid) || !Number.isInteger(value?.gid)) {
    throw new Error(`installed path has invalid ownership metadata: ${installedPath}`);
  }
  return { uid: value.uid, gid: value.gid };
}

function assertTrustedDirectory(stat, installedPath, metadataProvider) {
  const owner = ownership(stat, installedPath, metadataProvider);
  const mode = stat.mode & 0o7777;
  if (!stat.isDirectory() || stat.isSymbolicLink() || owner.uid !== 0 || owner.gid !== 0
      || (mode & 0o022) !== 0) {
    throw new Error(`installed package directory is not root-owned and write-safe: ${installedPath}`);
  }
}

function assertSafeSymlink(root, full, installedPath, target, metadataProvider) {
  if (path.posix.isAbsolute(target)) {
    throw new Error(`installed package symlink target must be relative: ${installedPath}`);
  }
  const normalizedTarget = path.posix.normalize(path.posix.join(path.posix.dirname(installedPath), target));
  if (!normalizedTarget.startsWith('/usr/')) {
    throw new Error(`installed package symlink escapes /usr: ${installedPath}`);
  }
  const candidate = path.resolve(path.dirname(full), target);
  const relative = path.relative(root, candidate);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`installed package symlink escapes its package root: ${installedPath}`);
  }
  let resolved;
  try {
    resolved = fs.realpathSync(candidate);
  } catch {
    throw new Error(`installed package symlink is dangling: ${installedPath}`);
  }
  const resolvedRelative = path.relative(root, resolved);
  if (resolvedRelative === '..' || resolvedRelative.startsWith(`..${path.sep}`)
      || path.isAbsolute(resolvedRelative) || !resolvedRelative.split(path.sep).join('/').startsWith('usr/')) {
    throw new Error(`installed package symlink resolves outside packaged /usr: ${installedPath}`);
  }
  const resolvedStat = fs.lstatSync(resolved);
  const resolvedInstalledPath = `/${resolvedRelative.split(path.sep).join('/')}`;
  const resolvedOwner = ownership(resolvedStat, resolvedInstalledPath, metadataProvider);
  if (resolvedOwner.uid !== 0 || resolvedOwner.gid !== 0) {
    throw new Error(`installed package symlink target is not root-owned: ${installedPath}`);
  }
}

function collectTree(root, current, records, excluded, metadataProvider) {
  const currentPath = `/${path.relative(root, current).split(path.sep).join('/')}`;
  if (currentPath.startsWith('/usr')) {
    assertTrustedDirectory(fs.lstatSync(current), currentPath, metadataProvider);
  }
  for (const entry of fs.readdirSync(current, { withFileTypes: true }).sort((a, b) => compareUtf8(a.name, b.name))) {
    const full = path.join(current, entry.name);
    const relative = path.relative(root, full).split(path.sep).join('/');
    const installedPath = `/${relative}`;
    const stat = fs.lstatSync(full);
    if (entry.isDirectory()) {
      if (stat.isSymbolicLink()) throw new Error(`installed tree directory is a symlink: ${installedPath}`);
      collectTree(root, full, records, excluded, metadataProvider);
      continue;
    }
    if (!installedPath.startsWith('/usr/')) {
      throw new Error(`package owns a non-/usr file that cannot be signed: ${installedPath}`);
    }
    const owner = ownership(stat, installedPath, metadataProvider);
    if (owner.uid !== 0 || owner.gid !== 0) {
      throw new Error(`installed package path is not root-owned: ${installedPath}`);
    }
    if (excluded.has(installedPath)) {
      if (!stat.isFile() || stat.isSymbolicLink() || normalizedMode(stat) !== '0644') {
        throw new Error(`installed attestation subject is not a regular mode 0644 file: ${installedPath}`);
      }
      continue;
    }
    if (stat.isSymbolicLink()) {
      const target = fs.readlinkSync(full);
      assertSafeSymlink(root, full, installedPath, target, metadataProvider);
      records.push({
        path: installedPath,
        type: 'symlink',
        target,
        mode: normalizedMode(stat),
        uid: owner.uid,
        gid: owner.gid
      });
      continue;
    }
    if (!stat.isFile()) throw new Error(`package owns an unsupported file type: ${installedPath}`);
    if (((stat.mode & 0o7777) & 0o022) !== 0) {
      throw new Error(`installed package file is group/world writable: ${installedPath}`);
    }
    const bytes = fs.readFileSync(full);
    records.push({
      path: installedPath,
      type: 'file',
      sha256: sha256Bytes(bytes),
      size: bytes.length,
      mode: normalizedMode(stat),
      uid: owner.uid,
      gid: owner.gid
    });
  }
}

export function collectInstalledFiles(installedRoot, {
  excludedPaths = [INSTALLED_MANIFEST_PATH, INSTALLED_MANIFEST_SIGNATURE_PATH],
  metadataProvider = null
} = {}) {
  const root = fs.realpathSync(installedRoot);
  const records = [];
  collectTree(root, root, records, new Set(excludedPaths), metadataProvider);
  return records.sort((left, right) => compareUtf8(left.path, right.path));
}

export function createInstalledManifest({
  files,
  packageVersion,
  gitCommit,
  packageArchitecture,
  packageFormat,
  firebaseAppId
}) {
  if (!VERSION.test(packageVersion ?? '')) throw new Error('installed manifest requires strict X.Y.Z packageVersion');
  if (!/^[a-f0-9]{40}$/u.test(gitCommit ?? '')) throw new Error('installed manifest requires a 40-character gitCommit');
  if (!['aarch64', 'x86_64'].includes(packageArchitecture)) throw new Error('installed manifest has unsupported architecture');
  if (!['deb', 'rpm'].includes(packageFormat)) throw new Error('installed manifest has unsupported package format');
  if (!FIREBASE_APP_ID.test(firebaseAppId ?? '')) throw new Error('installed manifest requires a valid Linux Firebase app id');
  if (!Array.isArray(files) || files.length === 0) throw new Error('installed manifest requires a non-empty file inventory');
  const daemon = files.find((file) => file.path === '/usr/bin/openburnbar-daemon' && file.type === 'file');
  const desktop = files.find((file) => file.path === '/usr/bin/openburnbar-linux-desktop' && file.type === 'file');
  const releaseKey = files.find((file) => file.path === RELEASE_PUBLIC_KEY_PATH && file.type === 'file');
  if (!daemon || daemon.mode !== '0755') throw new Error('installed manifest requires mode 0755 daemon inventory');
  if (!desktop || desktop.mode !== '0755') throw new Error('installed manifest requires mode 0755 desktop inventory');
  if (!releaseKey || releaseKey.mode !== '0644') throw new Error('installed manifest requires mode 0644 release public key inventory');
  const manifest = {
    schemaVersion: 1,
    product: 'OpenBurnBar',
    appId: 'dev.openburnbar.OpenBurnBar',
    firebaseAppId,
    packageVersion,
    gitCommit,
    packageArchitecture,
    packageFormat,
    packageName: 'open-burn-bar',
    policyId: 'openburnbar-linux-signed-package-inventory-v1',
    brokerProtocolVersion: 2,
    installedFilesRootSha256: installedFilesRoot(files),
    authorizedClients: [{
      role: 'daemon',
      path: daemon.path,
      sha256: daemon.sha256,
      ownerUid: daemon.uid,
      ownerGid: daemon.gid,
      mode: Number.parseInt(daemon.mode, 8)
    }],
    files
  };
  assertInstalledManifest(manifest);
  return manifest;
}

export function assertInstalledManifest(manifest) {
  if (!manifest || Array.isArray(manifest) || typeof manifest !== 'object') throw new Error('installed manifest must be an object');
  const keys = Object.keys(manifest).sort(compareUtf8);
  if (keys.length !== MANIFEST_KEYS.length || keys.some((key, index) => key !== MANIFEST_KEYS[index])) {
    throw new Error('installed manifest has missing or unexpected fields');
  }
  if (manifest.schemaVersion !== 1 || manifest.product !== 'OpenBurnBar'
      || manifest.appId !== 'dev.openburnbar.OpenBurnBar'
      || manifest.packageName !== 'open-burn-bar'
      || manifest.policyId !== 'openburnbar-linux-signed-package-inventory-v1'
      || manifest.brokerProtocolVersion !== 2) {
    throw new Error('installed manifest constants do not match the release contract');
  }
  if (!VERSION.test(manifest.packageVersion ?? '') || !/^[a-f0-9]{40}$/u.test(manifest.gitCommit ?? '')
      || !['aarch64', 'x86_64'].includes(manifest.packageArchitecture)
      || !['deb', 'rpm'].includes(manifest.packageFormat)
      || !FIREBASE_APP_ID.test(manifest.firebaseAppId ?? '')) {
    throw new Error('installed manifest identity is invalid');
  }
  if (!Array.isArray(manifest.files) || manifest.files.length === 0 || manifest.files.length > 100_000) {
    throw new Error('installed manifest inventory is empty or unbounded');
  }
  let previousPath = null;
  for (const file of manifest.files) {
    assertInstalledFileRecord(file);
    if (previousPath !== null && compareUtf8(previousPath, file.path) >= 0) {
      throw new Error('installed manifest file paths must be strictly sorted and unique');
    }
    previousPath = file.path;
  }
  if (installedFilesRoot(manifest.files) !== manifest.installedFilesRootSha256
      || !SHA256.test(manifest.installedFilesRootSha256 ?? '')) {
    throw new Error('installed manifest inventory root is invalid');
  }
  if (!Array.isArray(manifest.authorizedClients) || manifest.authorizedClients.length !== 1) {
    throw new Error('installed manifest must authorize exactly one daemon client');
  }
  const daemon = manifest.files.find((file) => file.path === '/usr/bin/openburnbar-daemon');
  const desktop = manifest.files.find((file) => file.path === '/usr/bin/openburnbar-linux-desktop');
  const releaseKey = manifest.files.find((file) => file.path === RELEASE_PUBLIC_KEY_PATH);
  const authorized = manifest.authorizedClients[0];
  if (!daemon || daemon.type !== 'file' || daemon.mode !== '0755'
      || !desktop || desktop.type !== 'file' || desktop.mode !== '0755'
      || !releaseKey || releaseKey.type !== 'file' || releaseKey.mode !== '0644') {
    throw new Error('installed manifest required executable and trust subjects are invalid');
  }
  if (JSON.stringify(Object.keys(authorized ?? {}).sort(compareUtf8))
        !== JSON.stringify(AUTHORIZED_CLIENT_KEYS)
      || authorized.role !== 'daemon' || authorized.path !== daemon.path
      || authorized.sha256 !== daemon.sha256 || authorized.ownerUid !== daemon.uid
      || authorized.ownerGid !== daemon.gid || authorized.mode !== Number.parseInt(daemon.mode, 8)) {
    throw new Error('installed manifest daemon authorization is not inventory-bound');
  }
  return manifest;
}

function assertInstalledFileRecord(file) {
  if (!file || typeof file !== 'object' || Array.isArray(file)
      || !['file', 'symlink'].includes(file.type)) {
    throw new Error('installed manifest file record is invalid');
  }
  const expectedKeys = file.type === 'file' ? FILE_KEYS : SYMLINK_KEYS;
  if (JSON.stringify(Object.keys(file).sort(compareUtf8)) !== JSON.stringify(expectedKeys)) {
    throw new Error('installed manifest file record has unexpected fields');
  }
  if (typeof file.path !== 'string' || file.path.includes('\0')
      || !file.path.startsWith('/usr/') || path.posix.normalize(file.path) !== file.path
      || file.path === INSTALLED_MANIFEST_PATH || file.path === INSTALLED_MANIFEST_SIGNATURE_PATH
      || !MODE.test(file.mode ?? '') || file.uid !== 0 || file.gid !== 0) {
    throw new Error('installed manifest file record path, mode, or ownership is invalid');
  }
  if (file.type === 'file') {
    if (!SHA256.test(file.sha256 ?? '') || !Number.isSafeInteger(file.size) || file.size < 0
        || (Number.parseInt(file.mode, 8) & 0o022) !== 0) {
      throw new Error('installed manifest regular file record is invalid');
    }
    return;
  }
  if (typeof file.target !== 'string' || file.target.length === 0 || file.target.length > 4096
      || file.target.includes('\0') || path.posix.isAbsolute(file.target)) {
    throw new Error('installed manifest symlink record is invalid');
  }
  const resolved = path.posix.normalize(path.posix.join(path.posix.dirname(file.path), file.target));
  if (!resolved.startsWith('/usr/')) throw new Error('installed manifest symlink escapes /usr');
}

export function signInstalledManifest(manifestBytes, privateKeyPem, publicKeyPem) {
  const privateKey = crypto.createPrivateKey(privateKeyPem);
  const publicKey = crypto.createPublicKey(publicKeyPem);
  if (privateKey.asymmetricKeyType !== 'ed25519' || publicKey.asymmetricKeyType !== 'ed25519') {
    throw new Error('installed manifest signing requires Ed25519 keys');
  }
  const signature = crypto.sign(null, manifestBytes, privateKey);
  if (signature.length !== 64 || !crypto.verify(null, manifestBytes, publicKey, signature)) {
    throw new Error('installed manifest signing key does not match the pinned release public key');
  }
  return signature;
}

export function verifyInstalledManifestTree({
  installedRoot,
  manifestBytes,
  signatureBytes,
  publicKeyPem,
  metadataProvider = null
}) {
  if (signatureBytes.length !== 64) throw new Error('installed manifest signature must be exactly 64 bytes');
  const publicKey = crypto.createPublicKey(publicKeyPem);
  if (publicKey.asymmetricKeyType !== 'ed25519' || !crypto.verify(null, manifestBytes, publicKey, signatureBytes)) {
    throw new Error('installed manifest signature verification failed');
  }
  const embeddedPublicKey = fs.readFileSync(
    path.join(fs.realpathSync(installedRoot), RELEASE_PUBLIC_KEY_PATH.slice(1))
  );
  const expectedPublicKey = Buffer.isBuffer(publicKeyPem) ? publicKeyPem : Buffer.from(publicKeyPem);
  if (embeddedPublicKey.length !== expectedPublicKey.length
      || !crypto.timingSafeEqual(embeddedPublicKey, expectedPublicKey)) {
    throw new Error('embedded release public key does not match the pinned signing key');
  }
  const manifest = assertInstalledManifest(JSON.parse(manifestBytes.toString('utf8')));
  const files = collectInstalledFiles(installedRoot, { metadataProvider });
  const expected = canonicalJsonBytes(manifest.files);
  const actual = canonicalJsonBytes(files);
  if (expected.length !== actual.length || !crypto.timingSafeEqual(expected, actual)) {
    throw new Error('installed package inventory differs from signed manifest');
  }
  return manifest;
}
