import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

export const linuxAppImagePeerManifestSchemaVersion = 1;
export const linuxAppImagePeerManifestKind = 'openburnbar.appimage.peer.v1';
export const linuxAppImagePeerManifestName = 'appimage-peer-manifest.json';
export const linuxAppImagePeerSignatureName = 'appimage-peer-manifest.ed25519.sig';
export const linuxAppImagePeerIdentity = 'com.openburnbar.app';
export const linuxAppImagePeerExecutableRelativePath = 'usr/bin/openburnbar-linux-desktop';
export const linuxReleasePublicKeySpkiSha256 =
  '0e0fd1f52af308d96c71571ef7e94f3e183218abf531760dfcc8ef8e499e5c37';

const manifestKeys = [
  'schemaVersion',
  'kind',
  'keyId',
  'identity',
  'executableRelativePath',
  'executableBasename',
  'executableSHA256'
];
const sha256Pattern = /^[0-9a-f]{64}$/u;
const basenamePattern = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/u;

function sha256Bytes(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function readRegularFileBytes(file, label) {
  const filePath = path.resolve(file);
  const noFollow = fs.constants.O_NOFOLLOW ?? 0;
  let fd;
  try {
    fd = fs.openSync(filePath, fs.constants.O_RDONLY | noFollow);
  } catch (error) {
    if (error?.code === 'ELOOP') throw new Error(`${label} is not a regular file: ${filePath}`, { cause: error });
    throw error;
  }
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) throw new Error(`${label} is not a regular file: ${filePath}`);
    return { filePath, bytes: fs.readFileSync(fd) };
  } finally {
    fs.closeSync(fd);
  }
}

function privateSigningKey(privateKeyPem, expectedKeyId) {
  const key = crypto.createPrivateKey(privateKeyPem ?? '');
  if (key.asymmetricKeyType !== 'ed25519') throw new Error('AppImage peer manifest requires an Ed25519 private key');
  const publicKey = crypto.createPublicKey(key);
  const spki = publicKey.export({ type: 'spki', format: 'der' });
  const keyId = sha256Bytes(spki);
  if (keyId !== expectedKeyId) {
    throw new Error(`AppImage peer manifest signing key is not the pinned Linux release key: ${keyId}`);
  }
  return key;
}

export function validateLinuxAppImagePeerManifest(
  manifest,
  { trustedKeyId = linuxReleasePublicKeySpkiSha256 } = {}
) {
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) {
    throw new Error('AppImage peer manifest must be an object');
  }
  if (JSON.stringify(Object.keys(manifest).sort()) !== JSON.stringify([...manifestKeys].sort())) {
    throw new Error('AppImage peer manifest fields do not exactly match schema');
  }
  if (manifest.schemaVersion !== linuxAppImagePeerManifestSchemaVersion) throw new Error('AppImage peer manifest schemaVersion must be 1');
  if (manifest.kind !== linuxAppImagePeerManifestKind) throw new Error('AppImage peer manifest kind is invalid');
  if (manifest.keyId !== trustedKeyId) throw new Error('AppImage peer manifest keyId is not trusted');
  if (manifest.identity !== linuxAppImagePeerIdentity) throw new Error('AppImage peer manifest identity is invalid');
  if (manifest.executableRelativePath !== linuxAppImagePeerExecutableRelativePath) {
    throw new Error('AppImage peer manifest executable path is invalid');
  }
  if (!basenamePattern.test(manifest.executableBasename)
      || manifest.executableBasename !== path.posix.basename(manifest.executableRelativePath)) {
    throw new Error('AppImage peer manifest executable basename is invalid');
  }
  if (!sha256Pattern.test(manifest.executableSHA256)) throw new Error('AppImage peer manifest executableSHA256 is invalid');
  return manifest;
}

export function createLinuxAppImagePeerManifest({
  executable,
  keyId = linuxReleasePublicKeySpkiSha256
}) {
  const { filePath: executablePath, bytes } = readRegularFileBytes(executable, 'AppImage GUI executable');
  const manifest = {
    schemaVersion: linuxAppImagePeerManifestSchemaVersion,
    kind: linuxAppImagePeerManifestKind,
    keyId,
    identity: linuxAppImagePeerIdentity,
    executableRelativePath: linuxAppImagePeerExecutableRelativePath,
    executableBasename: path.basename(executablePath),
    executableSHA256: sha256Bytes(bytes)
  };
  return validateLinuxAppImagePeerManifest(manifest, { trustedKeyId: keyId });
}

export function serializeLinuxAppImagePeerManifest(
  manifest,
  { trustedKeyId = linuxReleasePublicKeySpkiSha256 } = {}
) {
  return Buffer.from(`${JSON.stringify(validateLinuxAppImagePeerManifest(manifest, { trustedKeyId }), null, 2)}\n`, 'utf8');
}

export function signLinuxAppImagePeerManifest({
  executable,
  privateKeyPem,
  trustedKeyId = linuxReleasePublicKeySpkiSha256
}) {
  const key = privateSigningKey(privateKeyPem, trustedKeyId);
  const manifest = createLinuxAppImagePeerManifest({ executable, keyId: trustedKeyId });
  const bytes = serializeLinuxAppImagePeerManifest(manifest, { trustedKeyId });
  const signature = crypto.sign(null, bytes, key);
  if (signature.length !== 64) throw new Error(`AppImage peer manifest signature must be 64 bytes, got ${signature.length}`);
  return { manifest, bytes, signature };
}

export function verifyLinuxAppImagePeerManifest({
  manifestBytes,
  signature,
  executable,
  publicKeyPem,
  trustedKeyId = linuxReleasePublicKeySpkiSha256
}) {
  if (!Buffer.isBuffer(manifestBytes) || manifestBytes.length === 0 || manifestBytes.length > 4096) {
    throw new Error('AppImage peer manifest must be between 1 and 4096 bytes');
  }
  if (!Buffer.isBuffer(signature) || signature.length !== 64) throw new Error('AppImage peer manifest signature must be 64 bytes');
  const publicKey = crypto.createPublicKey(publicKeyPem);
  if (publicKey.asymmetricKeyType !== 'ed25519') throw new Error('AppImage peer manifest public key must be Ed25519');
  const keyId = sha256Bytes(publicKey.export({ type: 'spki', format: 'der' }));
  if (keyId !== trustedKeyId) throw new Error(`AppImage peer manifest key is not trusted: ${keyId}`);
  const manifest = validateLinuxAppImagePeerManifest(JSON.parse(manifestBytes.toString('utf8')), { trustedKeyId });
  const canonicalBytes = serializeLinuxAppImagePeerManifest(manifest, { trustedKeyId });
  if (manifestBytes.length !== canonicalBytes.length || !crypto.timingSafeEqual(manifestBytes, canonicalBytes)) {
    throw new Error('AppImage peer manifest bytes are not canonical');
  }
  if (!crypto.verify(null, manifestBytes, publicKey, signature)) throw new Error('AppImage peer manifest signature is invalid');
  const actual = createLinuxAppImagePeerManifest({ executable, keyId: trustedKeyId });
  if (manifest.executableBasename !== actual.executableBasename
      || manifest.executableSHA256 !== actual.executableSHA256) {
    throw new Error('AppImage peer manifest does not match the GUI executable');
  }
  return manifest;
}

export function writeSignedLinuxAppImagePeerManifest({
  appDir,
  privateKeyPem,
  trustedKeyId = linuxReleasePublicKeySpkiSha256
}) {
  const root = path.resolve(appDir);
  const executable = path.join(root, linuxAppImagePeerExecutableRelativePath);
  const outputDirectory = path.join(root, 'usr/share/openburnbar');
  const manifestFile = path.join(outputDirectory, linuxAppImagePeerManifestName);
  const signatureFile = path.join(outputDirectory, linuxAppImagePeerSignatureName);
  const signed = signLinuxAppImagePeerManifest({ executable, privateKeyPem, trustedKeyId });
  fs.mkdirSync(outputDirectory, { recursive: true });
  const outputStat = fs.lstatSync(outputDirectory);
  if (!outputStat.isDirectory() || outputStat.isSymbolicLink()) {
    throw new Error(`AppImage peer manifest output directory is not a regular directory: ${outputDirectory}`);
  }
  for (const file of [manifestFile, signatureFile]) {
    if (fs.existsSync(file) || fs.lstatSync(file, { throwIfNoEntry: false })) {
      throw new Error(`AppImage peer manifest output already exists: ${file}`);
    }
  }
  fs.writeFileSync(manifestFile, signed.bytes, { mode: 0o644, flag: 'wx' });
  fs.writeFileSync(signatureFile, signed.signature, { mode: 0o644, flag: 'wx' });
  fs.chmodSync(manifestFile, 0o644);
  fs.chmodSync(signatureFile, 0o644);
  return { ...signed, executable, manifestFile, signatureFile };
}
