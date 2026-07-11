#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

import {
  createNativePackageSigningReceipt,
  measureNativeSignerInputs,
  NATIVE_GENERATED_PACKAGE_INPUT_PATHS,
  NATIVE_PACKAGE_ASSET_PATHS,
  NATIVE_PACKAGE_LIFECYCLE_PATHS,
  sha256File,
  signNativePackageSigningReceipt,
  validatePreparationForSigner
} from './lib/linux-native-signing-receipt.mjs';
import {
  buildDebPackage,
  buildRpmPackage,
  stageNativeLinuxPackageRoot,
  validateDedicatedLinuxFirebaseAppId
} from './lib/native-linux-packager.mjs';
import { gitInfo, packageVersion, repoRoot } from './lib/linux-release-common.mjs';

const versionIndex = process.argv.indexOf('--version');
const version = versionIndex >= 0 ? process.argv[versionIndex + 1]?.trim() : packageVersion();
const privateKeyFileIndex = process.argv.indexOf('--private-key-file');
const privateKeyFile = privateKeyFileIndex >= 0
  ? process.argv[privateKeyFileIndex + 1]?.trim()
  : null;
const privateKeyStdin = process.argv.includes('--private-key-stdin');
const architecture = process.arch === 'arm64' ? 'aarch64' : process.arch === 'x64' ? 'x86_64' : process.arch;
if (Object.hasOwn(process.env, 'OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM')) {
  throw new Error('OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM is forbidden; pass the native signing key only by stdin or file');
}
const firebaseAppIdIndex = process.argv.indexOf('--firebase-app-id');
const cliFirebaseAppId = firebaseAppIdIndex >= 0
  ? process.argv[firebaseAppIdIndex + 1]?.trim()
  : null;
const environmentFirebaseAppId = process.env.OPENBURNBAR_LINUX_FIREBASE_APP_ID?.trim() || null;
if (cliFirebaseAppId && environmentFirebaseAppId && cliFirebaseAppId !== environmentFirebaseAppId) {
  throw new Error('--firebase-app-id does not match OPENBURNBAR_LINUX_FIREBASE_APP_ID');
}
const firebaseAppId = cliFirebaseAppId || environmentFirebaseAppId;
const configuredStandardWebFirebaseAppIds = [
  process.env.OPENBURNBAR_STANDARD_WEB_FIREBASE_APP_IDS,
  process.env.APP_CHECK_STANDARD_WEB_APP_IDS
].filter(Boolean).flatMap((value) => value.split(/[\s,]+/u)).filter(Boolean);
const productionEnvironment = fs.readFileSync(
  path.join(repoRoot, 'functions/.env.burnbar.production'),
  'utf8'
);
const productionRegistryLine = productionEnvironment
  .split(/\r?\n/u)
  .filter((line) => line.startsWith('APP_CHECK_STANDARD_WEB_APP_IDS='));
if (productionRegistryLine.length !== 1) {
  throw new Error('committed production standard Web Firebase app ID registry must appear exactly once');
}
const standardWebFirebaseAppIds = productionRegistryLine[0]
  .slice('APP_CHECK_STANDARD_WEB_APP_IDS='.length)
  .split(/[\s,]+/u)
  .filter(Boolean);
const configuredRegistry = [...new Set(configuredStandardWebFirebaseAppIds)].sort();
const committedRegistry = [...new Set(standardWebFirebaseAppIds)].sort();
if (configuredRegistry.length > 0
    && (configuredRegistry.length !== committedRegistry.length
      || configuredRegistry.some((value, index) => value !== committedRegistry[index]))) {
  throw new Error('configured standard Web Firebase app ID registry does not exactly match committed production');
}
validateDedicatedLinuxFirebaseAppId(firebaseAppId, standardWebFirebaseAppIds);
const git = gitInfo();
const appDirectory = path.join(repoRoot, 'apps/linux-desktop/src-tauri');
const targetDirectory = path.join(appDirectory, 'target');
const bundleDirectory = path.join(targetDirectory, 'release/bundle');
const workDirectory = path.join(targetDirectory, 'openburnbar-native-package-work');
const receiptDirectory = path.join(targetDirectory, 'openburnbar-release');
const preparationReceiptPath = path.join(receiptDirectory, 'architecture-preparation.json');
const signingReceiptPath = path.join(receiptDirectory, 'native-package-signing.json');
const signingReceiptSignaturePath = `${signingReceiptPath}.ed25519.sig`;
if (privateKeyFile && privateKeyStdin) {
  throw new Error('--private-key-file and --private-key-stdin are mutually exclusive');
}
if (!privateKeyFile && !privateKeyStdin) {
  throw new Error('--private-key-stdin or --private-key-file is required to sign the installed manifest');
}

if (!/^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$/.test(version ?? '')) {
  throw new Error('native Linux package build requires strict --version X.Y.Z');
}
if (!['aarch64', 'x86_64'].includes(architecture)) {
  throw new Error(`native Linux packages do not support architecture ${architecture}`);
}
if (!git.gitAvailable || git.dirty) {
  throw new Error(`native Linux packages require a clean Git checkout: ${git.dirtyEntries.join(', ')}`);
}
fs.rmSync(signingReceiptPath, { force: true });
fs.rmSync(signingReceiptSignaturePath, { force: true });

let preparationReceipt;
try {
  preparationReceipt = JSON.parse(fs.readFileSync(preparationReceiptPath, 'utf8'));
} catch (error) {
  throw new Error(`native package signing requires a successful preparation receipt: ${error.message}`);
}
const signerInputs = measureNativeSignerInputs(repoRoot);
const preparationDigestSha256 = validatePreparationForSigner({
  receipt: preparationReceipt,
  version,
  architecture,
  gitCommit: git.commit,
  signerInputsRootSha256: signerInputs.rootSha256
});

if (privateKeyFile) {
  const keyPath = path.resolve(privateKeyFile);
  const keyStat = fs.lstatSync(keyPath);
  if (!keyStat.isFile() || keyStat.isSymbolicLink() || (keyStat.mode & 0o077) !== 0) {
    throw new Error('--private-key-file must be a regular file with no group or other permissions');
  }
}
const privateKeyPem = (privateKeyStdin
  ? fs.readFileSync(0, 'utf8')
  : fs.readFileSync(path.resolve(privateKeyFile), 'utf8')).trim();
const privateKey = crypto.createPrivateKey(privateKeyPem);
if (privateKey.asymmetricKeyType !== 'ed25519') {
  throw new Error('native Linux installed-manifest signing key must be Ed25519');
}

const assets = Object.fromEntries(Object.entries(NATIVE_PACKAGE_ASSET_PATHS)
  .map(([name, relativePath]) => [name, path.join(repoRoot, relativePath)]));
const generatedInputs = Object.fromEntries(Object.entries(NATIVE_GENERATED_PACKAGE_INPUT_PATHS)
  .map(([name, relativePath]) => [name, path.join(repoRoot, relativePath)]));

const common = {
  ...generatedInputs,
  assets,
  version,
  gitCommit: git.commit,
  architecture,
  privateKeyPem,
  firebaseAppId,
  standardWebFirebaseAppIds
};

fs.mkdirSync(bundleDirectory, { recursive: true });
const debRoot = path.join(workDirectory, 'deb-root');
const deb = stageNativeLinuxPackageRoot({ ...common, root: debRoot, packageType: 'deb' });
const debArchitecture = architecture === 'aarch64' ? 'arm64' : 'amd64';
const debOutput = path.join(bundleDirectory, 'deb', `OpenBurnBar_${version}_${debArchitecture}.deb`);
buildDebPackage({
  root: deb.root,
  output: debOutput,
  version,
  architecture,
  scripts: {
    ...Object.fromEntries(Object.entries(NATIVE_PACKAGE_LIFECYCLE_PATHS.deb)
      .map(([name, relativePath]) => [name, path.join(repoRoot, relativePath)]))
  }
});

const rpmRoot = path.join(workDirectory, 'rpm-root');
const rpm = stageNativeLinuxPackageRoot({ ...common, root: rpmRoot, packageType: 'rpm' });
const rpmOutput = buildRpmPackage({
  root: rpm.root,
  outputDirectory: path.join(bundleDirectory, 'rpm'),
  workDirectory: path.join(workDirectory, 'rpmbuild'),
  version,
  architecture,
  scripts: {
    ...Object.fromEntries(Object.entries(NATIVE_PACKAGE_LIFECYCLE_PATHS.rpm)
      .map(([name, relativePath]) => [name, path.join(repoRoot, relativePath)]))
  }
});

const packageRows = [
  { type: 'deb', output: debOutput, installedManifestDigestSha256: deb.releaseDigestSha256 },
  { type: 'rpm', output: rpmOutput, installedManifestDigestSha256: rpm.releaseDigestSha256 }
].map((item) => ({
  type: item.type,
  file: path.relative(repoRoot, item.output).split(path.sep).join('/'),
  size: fs.statSync(item.output).size,
  sha256: sha256File(item.output),
  installedManifestDigestSha256: item.installedManifestDigestSha256
}));
const finalSignerInputs = measureNativeSignerInputs(repoRoot);
if (finalSignerInputs.rootSha256 !== signerInputs.rootSha256
    || finalSignerInputs.records.length !== signerInputs.records.length) {
  throw new Error('native signer inputs changed while deb/rpm packages were being built');
}
const signingReceipt = createNativePackageSigningReceipt({
  version,
  architecture,
  gitCommit: git.commit,
  firebaseAppId,
  preparationDigestSha256,
  signerInputsRootSha256: finalSignerInputs.rootSha256,
  packages: packageRows
});
const signedReceipt = signNativePackageSigningReceipt(signingReceipt, privateKey);
fs.mkdirSync(receiptDirectory, { recursive: true });
fs.writeFileSync(signingReceiptPath, signedReceipt.bytes, { mode: 0o644 });
fs.writeFileSync(signingReceiptSignaturePath, signedReceipt.signature, { mode: 0o644 });

console.log(JSON.stringify({
  schemaVersion: 1,
  version,
  architecture,
  gitCommit: git.commit,
  firebaseAppId,
  preparationDigestSha256,
  signerInputsRootSha256: signerInputs.rootSha256,
  signingReceipt: path.relative(repoRoot, signingReceiptPath),
  signingReceiptSignature: path.relative(repoRoot, signingReceiptSignaturePath),
  packages: packageRows
}, null, 2));
