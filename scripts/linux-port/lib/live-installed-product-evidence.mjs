import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

export const LIVE_INSTALLED_MANIFEST_PATH = '/usr/share/openburnbar/attestation/installed-manifest.json';
export const LIVE_INSTALLED_SIGNATURE_PATH = `${LIVE_INSTALLED_MANIFEST_PATH}.sig`;
export const LIVE_RELEASE_PUBLIC_KEY_PATH = '/usr/share/openburnbar/attestation/release-ed25519.pub.pem';
export const LIVE_DESKTOP_BINARY_PATH = '/usr/bin/openburnbar-linux-desktop';

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function compareUtf8(left, right) {
  return Buffer.compare(Buffer.from(left, 'utf8'), Buffer.from(right, 'utf8'));
}

function normalizedMode(stat) {
  return (stat.mode & 0o7777).toString(8).padStart(4, '0');
}

function mappedPath(installedRoot, absolutePath, label) {
  if (!path.posix.isAbsolute(absolutePath) || !absolutePath.startsWith('/usr/')) {
    throw new Error(`${label} must be an absolute /usr path`);
  }
  const root = path.resolve(installedRoot);
  const candidate = path.resolve(root, absolutePath.slice(1));
  const relative = path.relative(root, candidate);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} escapes the installed root`);
  }
  return candidate;
}

function assertNoParentSymlinks(installedRoot, absolutePath, label) {
  const root = path.resolve(installedRoot);
  const candidate = mappedPath(root, absolutePath, label);
  let current = root;
  for (const component of path.relative(root, path.dirname(candidate)).split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    const stat = fs.lstatSync(current);
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new Error(`${label} traverses a non-directory or symlink: ${current}`);
    }
  }
  return candidate;
}

function readRegularSnapshot(installedRoot, absolutePath, label) {
  const candidate = assertNoParentSymlinks(installedRoot, absolutePath, label);
  const descriptor = fs.openSync(candidate, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
  try {
    const before = fs.fstatSync(descriptor);
    if (!before.isFile()) throw new Error(`${label} must be a regular file`);
    const bytes = fs.readFileSync(descriptor);
    const after = fs.fstatSync(descriptor);
    if (before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size
        || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs) {
      throw new Error(`${label} changed while it was being read`);
    }
    return { bytes, stat: after, sha256: sha256(bytes) };
  } finally {
    fs.closeSync(descriptor);
  }
}

function timingSafeBytesEqual(left, right) {
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function assertRootOwnedTrustFile(snapshot, absolutePath, ownership) {
  const uid = ownership?.uid ?? snapshot.stat.uid;
  const gid = ownership?.gid ?? snapshot.stat.gid;
  if (uid !== 0 || gid !== 0 || normalizedMode(snapshot.stat) !== '0644') {
    throw new Error(`live installed trust file must be root-owned mode 0644: ${absolutePath}`);
  }
}

function actualFileRecord(installedRoot, expected, ownership = null) {
  const candidate = assertNoParentSymlinks(installedRoot, expected.path, `installed file ${expected.path}`);
  const stat = fs.lstatSync(candidate);
  const uid = ownership?.uid ?? stat.uid;
  const gid = ownership?.gid ?? stat.gid;
  if (expected.type === 'symlink') {
    if (!stat.isSymbolicLink()) throw new Error(`installed file is not the expected symlink: ${expected.path}`);
    return {
      path: expected.path,
      type: 'symlink',
      target: fs.readlinkSync(candidate),
      mode: normalizedMode(stat),
      uid,
      gid
    };
  }
  const snapshot = readRegularSnapshot(installedRoot, expected.path, `installed file ${expected.path}`);
  return {
    path: expected.path,
    type: 'file',
    sha256: snapshot.sha256,
    size: snapshot.stat.size,
    mode: normalizedMode(snapshot.stat),
    uid,
    gid
  };
}

function recordLine(file) {
  return file.type === 'file'
    ? `${file.path}\0file\0${file.sha256}\0${file.size}\0${file.mode}\0${file.uid}\0${file.gid}`
    : `${file.path}\0symlink\0${file.target}\0${file.mode}\0${file.uid}\0${file.gid}`;
}

function exactRecordEquals(left, right) {
  return left.type === right.type && recordLine(left) === recordLine(right);
}

function listPackageOwnedPaths(installedManifest, installedRoot, runner) {
  const [command, args] = installedManifest.packageFormat === 'deb'
    ? ['dpkg-query', ['-L', installedManifest.packageName]]
    : installedManifest.packageFormat === 'rpm'
      ? ['rpm', ['-ql', installedManifest.packageName]]
      : [null, null];
  if (command === null) throw new Error(`unsupported installed package format: ${installedManifest.packageFormat}`);
  const result = runner(command, args, { encoding: 'utf8', timeout: 30_000, maxBuffer: 4 * 1024 * 1024 });
  if (result.error) throw new Error(`installed package ownership query failed: ${result.error.message}`);
  if (result.status !== 0) {
    throw new Error(`installed package ownership query failed: ${(result.stderr || result.stdout || 'unknown error').trim()}`);
  }
  const listed = result.stdout.split('\n').map((entry) => entry.trim()).filter(Boolean);
  const paths = [];
  const seen = new Set();
  for (const installedPath of listed) {
    if (!path.posix.isAbsolute(installedPath)) {
      throw new Error(`package manager returned a non-absolute owned path: ${installedPath}`);
    }
    const candidate = path.resolve(installedRoot, installedPath.slice(1));
    const stat = fs.lstatSync(candidate);
    if (stat.isDirectory()) continue;
    if (seen.has(installedPath)) throw new Error(`package manager repeated owned path: ${installedPath}`);
    seen.add(installedPath);
    paths.push(installedPath);
  }
  return paths.sort(compareUtf8);
}

function assertExactPackageOwnership(installedManifest, packageOwnedPaths) {
  const expected = [
    ...installedManifest.files.map((entry) => entry.path),
    LIVE_INSTALLED_MANIFEST_PATH,
    LIVE_INSTALLED_SIGNATURE_PATH
  ].sort(compareUtf8);
  const actual = [...packageOwnedPaths].sort(compareUtf8);
  if (actual.length !== expected.length || actual.some((entry, index) => entry !== expected[index])) {
    const expectedSet = new Set(expected);
    const actualSet = new Set(actual);
    const extra = actual.filter((entry) => !expectedSet.has(entry));
    const missing = expected.filter((entry) => !actualSet.has(entry));
    throw new Error(
      `live package-owned path inventory differs from the signed manifest; extra=${extra.join(',') || 'none'}; missing=${missing.join(',') || 'none'}`
    );
  }
}

export function verifyLiveInstalledProduct({
  installedManifest,
  expectedManifestBytes,
  installedRoot = '/',
  ownership = null,
  packageOwnedPaths = null,
  packageListRunner = spawnSync
}) {
  const liveManifest = readRegularSnapshot(
    installedRoot,
    LIVE_INSTALLED_MANIFEST_PATH,
    'live installed manifest'
  );
  if (!timingSafeBytesEqual(liveManifest.bytes, expectedManifestBytes)) {
    throw new Error('live installed manifest bytes do not match the release closure subject');
  }
  const signature = readRegularSnapshot(
    installedRoot,
    LIVE_INSTALLED_SIGNATURE_PATH,
    'live installed manifest signature'
  );
  assertRootOwnedTrustFile(liveManifest, LIVE_INSTALLED_MANIFEST_PATH, ownership);
  assertRootOwnedTrustFile(signature, LIVE_INSTALLED_SIGNATURE_PATH, ownership);
  if (signature.bytes.length !== 64) throw new Error('live installed manifest signature must be 64 bytes');
  const publicKey = readRegularSnapshot(
    installedRoot,
    LIVE_RELEASE_PUBLIC_KEY_PATH,
    'live installed release public key'
  );
  assertRootOwnedTrustFile(publicKey, LIVE_RELEASE_PUBLIC_KEY_PATH, ownership);
  let key;
  try {
    key = crypto.createPublicKey(publicKey.bytes);
  } catch (error) {
    throw new Error(`live installed release public key is invalid: ${error.message}`);
  }
  if (key.asymmetricKeyType !== 'ed25519') {
    throw new Error('live installed release public key must be Ed25519');
  }
  if (!crypto.verify(null, liveManifest.bytes, key, signature.bytes)) {
    throw new Error('live installed manifest signature verification failed');
  }

  const ownedPaths = packageOwnedPaths
    ?? listPackageOwnedPaths(installedManifest, installedRoot, packageListRunner);
  assertExactPackageOwnership(installedManifest, ownedPaths);

  const actualFiles = installedManifest.files
    .map((expected) => {
      const actual = actualFileRecord(installedRoot, expected, ownership);
      if (!exactRecordEquals(actual, expected)) {
        throw new Error(`live installed file does not match signed inventory: ${expected.path}`);
      }
      return actual;
    })
    .sort((left, right) => compareUtf8(left.path, right.path));
  const actualRoot = sha256(Buffer.from(actualFiles.map(recordLine).sort(compareUtf8).join('\n'), 'utf8'));
  if (actualRoot !== installedManifest.installedFilesRootSha256) {
    throw new Error('live installed file inventory root does not match the signed manifest');
  }
  const daemon = actualFiles.find((entry) => entry.path === '/usr/bin/openburnbar-daemon' && entry.type === 'file');
  const authorized = installedManifest.authorizedClients.find((entry) => entry.role === 'daemon');
  if (!daemon || !authorized || daemon.sha256 !== authorized.sha256
      || daemon.uid !== authorized.ownerUid || daemon.gid !== authorized.ownerGid
      || Number.parseInt(daemon.mode, 8) !== authorized.mode) {
    throw new Error('live installed daemon does not match the authorized client record');
  }

  return {
    schemaVersion: 1,
    manifestBytes: liveManifest.bytes,
    signatureBytes: signature.bytes,
    publicKeyBytes: publicKey.bytes,
    verification: {
      schemaVersion: 1,
      liveManifestSha256: liveManifest.sha256,
      signatureSha256: signature.sha256,
      publicKeySha256: publicKey.sha256,
      installedFilesRootSha256: actualRoot,
      installedFileCount: actualFiles.length,
      packageOwnedPathCount: ownedPaths.length,
      authorizedDaemonSha256: daemon.sha256,
      passed: true
    }
  };
}

export function captureLiveRuntimeCapabilities({
  binaryPath = LIVE_DESKTOP_BINARY_PATH,
  runner = spawnSync
} = {}) {
  const result = runner(binaryPath, ['--runtime-capabilities'], {
    encoding: 'utf8',
    timeout: 30_000,
    maxBuffer: 4 * 1024 * 1024
  });
  if (result.error) throw new Error(`live runtime capability capture failed: ${result.error.message}`);
  if (result.status !== 0) {
    throw new Error(`live runtime capability capture failed: ${(result.stderr || result.stdout || 'unknown error').trim()}`);
  }
  if (typeof result.stdout !== 'string' || result.stdout.trim().length === 0) {
    throw new Error('live runtime capability capture produced no JSON');
  }
  const bytes = Buffer.from(`${result.stdout.trim()}\n`, 'utf8');
  try {
    JSON.parse(bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`live runtime capability capture is not valid JSON: ${error.message}`);
  }
  return { bytes };
}
