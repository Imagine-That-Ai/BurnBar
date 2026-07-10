import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

export const NATIVE_GENERATED_PACKAGE_INPUT_PATHS = Object.freeze({
  guiBinary: 'apps/linux-desktop/src-tauri/target/release/openburnbar-linux-desktop',
  daemonBinary: 'apps/linux-desktop/src-tauri/target/openburnbar-package-payload/openburnbar-daemon',
  swiftRuntimeDir: 'apps/linux-desktop/src-tauri/target/openburnbar-package-payload/swift',
  nativeRuntimeDir: 'apps/linux-desktop/src-tauri/target/openburnbar-package-payload/native',
  attestdBinary: 'crates/openburnbar-attestd/target/release/openburnbar-attestd'
});

export const NATIVE_PACKAGE_ASSET_PATHS = Object.freeze({
  daemonLaunch: 'packaging/linux/openburnbar-daemon-launch.sh',
  daemonUserService: 'packaging/linux/openburnbar-daemon.service',
  attestdService: 'packaging/linux/openburnbar-attestd.service',
  attestdSocket: 'packaging/linux/openburnbar-attestd.socket',
  attestdPurgeHelper: 'packaging/linux/openburnbar-attestd-purge-state',
  attestdActivationReady: 'packaging/linux/openburnbar-attestd-activation-ready',
  restartActiveUserDaemons: 'packaging/linux/openburnbar-restart-active-user-daemons',
  desktopEntry: 'packaging/linux/openburnbar.desktop',
  safeModeDesktopEntry: 'packaging/linux/openburnbar-safe-mode.desktop',
  autostartEntry: 'packaging/linux/autostart/openburnbar.desktop',
  daemonEnvExample: 'packaging/linux/daemon.env.example',
  customXdgDropInExample: 'packaging/linux/systemd/openburnbar-daemon.service.d/custom-xdg.conf.example',
  attestationSchema: 'packaging/linux/attestation/openburnbar-installed-manifest.schema.json',
  attestationPublicKey: 'packaging/linux/openburnbar-linux-ed25519.pub.pem',
  icon: 'apps/linux-desktop/src-tauri/icons/icon.png'
});

export const NATIVE_PACKAGE_LIFECYCLE_PATHS = Object.freeze({
  deb: Object.freeze({
    postinst: 'packaging/linux/debian/openburnbar-attestd.postinst',
    prerm: 'packaging/linux/debian/openburnbar-attestd.prerm',
    postrm: 'packaging/linux/debian/openburnbar-attestd.postrm'
  }),
  rpm: Object.freeze({
    post: 'packaging/linux/rpm/openburnbar-attestd.post',
    preun: 'packaging/linux/rpm/openburnbar-attestd.preun',
    postun: 'packaging/linux/rpm/openburnbar-attestd.postun'
  })
});

export const NATIVE_SIGNER_INPUT_PATHS = Object.freeze([
  'functions/.env.burnbar.production',
  ...Object.values(NATIVE_GENERATED_PACKAGE_INPUT_PATHS),
  ...Object.values(NATIVE_PACKAGE_ASSET_PATHS),
  ...Object.values(NATIVE_PACKAGE_LIFECYCLE_PATHS.deb),
  ...Object.values(NATIVE_PACKAGE_LIFECYCLE_PATHS.rpm)
]);

export function canonicalJson(value) {
  const canonicalize = (item) => {
    if (Array.isArray(item)) return item.map(canonicalize);
    if (item && typeof item === 'object') {
      return Object.fromEntries(
        Object.keys(item).sort(compareUtf8).map((key) => [key, canonicalize(item[key])])
      );
    }
    return item;
  };
  return `${JSON.stringify(canonicalize(value))}\n`;
}

export function sha256Bytes(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

export function sha256File(file) {
  return sha256Bytes(fs.readFileSync(file));
}

export function measureNativeSignerInputs(repoRoot, inputPaths = NATIVE_SIGNER_INPUT_PATHS) {
  const records = [];
  const seen = new Set();
  for (const relativeInput of inputPaths) {
    if (path.isAbsolute(relativeInput) || relativeInput.split('/').includes('..')) {
      throw new Error(`native signer input path must be repository-relative: ${relativeInput}`);
    }
    collectPath(repoRoot, relativeInput, records, seen);
  }
  records.sort((left, right) => compareUtf8(left.path, right.path));
  return {
    records,
    rootSha256: sha256Bytes(Buffer.from(canonicalJson(records), 'utf8'))
  };
}

export function preparationReceiptDigest(receipt) {
  return sha256Bytes(Buffer.from(canonicalJson(receipt), 'utf8'));
}

export function createNativePackageSigningReceipt({
  version,
  architecture,
  gitCommit,
  firebaseAppId,
  preparationDigestSha256,
  signerInputsRootSha256,
  packages
}) {
  const normalizedPackages = packages.map((item) => ({
    type: item.type,
    file: item.file,
    size: item.size,
    sha256: item.sha256,
    installedManifestDigestSha256: item.installedManifestDigestSha256
  })).sort((left, right) => compareUtf8(left.type, right.type));
  const receipt = {
    schemaVersion: 1,
    version,
    architecture,
    gitCommit,
    firebaseAppId,
    preparationDigestSha256,
    signerInputsRootSha256,
    packages: normalizedPackages
  };
  validateNativePackageSigningReceipt(receipt);
  return receipt;
}

export function signNativePackageSigningReceipt(receipt, privateKey) {
  const bytes = Buffer.from(canonicalJson(receipt), 'utf8');
  const signature = crypto.sign(null, bytes, privateKey);
  if (signature.length !== 64) throw new Error('native package signing receipt signature is invalid');
  return { bytes, signature };
}

export function verifyNativePackageSigningReceipt(receiptBytes, signature, publicKey) {
  if (signature.length !== 64 || !crypto.verify(null, receiptBytes, publicKey, signature)) {
    throw new Error('native package signing receipt signature verification failed');
  }
  const receipt = JSON.parse(receiptBytes.toString('utf8'));
  validateNativePackageSigningReceipt(receipt);
  if (!Buffer.from(canonicalJson(receipt), 'utf8').equals(receiptBytes)) {
    throw new Error('native package signing receipt is not canonical JSON');
  }
  return receipt;
}

export function validatePreparationForSigner({
  receipt,
  version,
  architecture,
  gitCommit,
  signerInputsRootSha256
}) {
  if (receipt?.schemaVersion !== 1
      || receipt.complete !== true
      || receipt.version !== version
      || receipt.architecture !== architecture
      || receipt.gitCommit !== gitCommit
      || receipt.signerInputsRootSha256 !== signerInputsRootSha256) {
    throw new Error('native signer inputs do not match the successful preparation receipt');
  }
  return preparationReceiptDigest(receipt);
}

export function validateSignedPackageArtifacts(repoRoot, receipt, discoveredArtifacts) {
  for (const packageRow of receipt.packages) {
    const packagePath = resolveRepositoryPath(repoRoot, packageRow.file);
    let stat;
    try {
      stat = fs.lstatSync(packagePath);
    } catch {
      throw new Error(`signed native package changed or is missing: ${packageRow.type}`);
    }
    if (!stat.isFile()
        || stat.isSymbolicLink()
        || stat.size !== packageRow.size
        || sha256File(packagePath) !== packageRow.sha256) {
      throw new Error(`signed native package changed or is missing: ${packageRow.type}`);
    }
  }
  const nativeArtifacts = discoveredArtifacts.filter((artifact) =>
    artifact && ['deb', 'rpm'].includes(artifact.type));
  if (nativeArtifacts.length !== 2
      || !nativeArtifacts.every((artifact) => receipt.packages.some((packageRow) =>
        packageRow.type === artifact.type
          && resolveRepositoryPath(repoRoot, packageRow.file) === path.resolve(artifact.file)))) {
    throw new Error('discovered deb/rpm artifacts do not exactly match the signed package receipt');
  }
}

function collectPath(repoRoot, relativeInput, records, seen) {
  const absolute = path.resolve(repoRoot, relativeInput);
  const relative = normalizeRelative(repoRoot, absolute);
  if (seen.has(relative)) return;
  seen.add(relative);
  let stat;
  try {
    stat = fs.lstatSync(absolute);
  } catch (error) {
    throw new Error(`required native signer input is missing: ${relativeInput}: ${error.message}`);
  }
  const mode = (stat.mode & 0o7777).toString(8).padStart(4, '0');
  if (stat.isSymbolicLink()) {
    const target = fs.readlinkSync(absolute);
    const resolved = path.resolve(path.dirname(absolute), target);
    normalizeRelative(repoRoot, resolved);
    records.push({ path: relative, type: 'symlink', mode, target });
    return;
  }
  if (stat.isDirectory()) {
    records.push({ path: relative, type: 'directory', mode });
    const entries = fs.readdirSync(absolute, { withFileTypes: true })
      .map((entry) => entry.name)
      .sort(compareUtf8);
    for (const entry of entries) collectPath(repoRoot, path.posix.join(relative, entry), records, seen);
    return;
  }
  if (!stat.isFile()) throw new Error(`native signer input has unsupported type: ${relative}`);
  records.push({
    path: relative,
    type: 'file',
    mode,
    size: stat.size,
    sha256: sha256File(absolute)
  });
}

function normalizeRelative(repoRoot, absolute) {
  const relative = path.relative(path.resolve(repoRoot), absolute);
  if (!relative || relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`native signer input escapes repository root: ${absolute}`);
  }
  return relative.split(path.sep).join('/');
}

function resolveRepositoryPath(repoRoot, relative) {
  const absolute = path.resolve(repoRoot, relative);
  normalizeRelative(repoRoot, absolute);
  return absolute;
}

function validateNativePackageSigningReceipt(receipt) {
  if (receipt?.schemaVersion !== 1
      || !/^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$/.test(receipt.version ?? '')
      || !['aarch64', 'x86_64'].includes(receipt.architecture)
      || !isHex(receipt.gitCommit, 40)
      || !isFirebaseWebAppId(receipt.firebaseAppId)
      || !isHex(receipt.preparationDigestSha256, 64)
      || !isHex(receipt.signerInputsRootSha256, 64)
      || !Array.isArray(receipt.packages)
      || receipt.packages.length !== 2) {
    throw new Error('native package signing receipt fields are invalid');
  }
  const types = new Set();
  for (const item of receipt.packages) {
    if (!['deb', 'rpm'].includes(item?.type)
        || types.has(item.type)
        || typeof item.file !== 'string'
        || item.file.length === 0
        || path.isAbsolute(item.file)
        || item.file.split('/').includes('..')
        || !Number.isSafeInteger(item.size)
        || item.size <= 0
        || !isHex(item.sha256, 64)
        || !isHex(item.installedManifestDigestSha256, 64)) {
      throw new Error('native package signing receipt package entry is invalid');
    }
    types.add(item.type);
  }
  if (!types.has('deb') || !types.has('rpm')) {
    throw new Error('native package signing receipt must bind one deb and one rpm');
  }
}

function compareUtf8(left, right) {
  return Buffer.compare(Buffer.from(left, 'utf8'), Buffer.from(right, 'utf8'));
}

function isHex(value, length) {
  return typeof value === 'string'
    && value.length === length
    && /^[a-f0-9]+$/.test(value);
}

function isFirebaseWebAppId(value) {
  if (typeof value !== 'string'
      || value.length > 160
      || !/^1:[0-9]+:web:[A-Za-z0-9]+$/.test(value)) return false;
  const [, projectNumber, , appInstance] = value.split(':');
  return !/^0+$/u.test(projectNumber)
    && !/^0+$/u.test(appInstance)
    && !appInstance.toLowerCase().includes('placeholder');
}
