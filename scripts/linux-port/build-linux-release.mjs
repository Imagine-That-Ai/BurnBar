#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {
  copyArtifact,
  discoverBundleArtifacts,
  fileSize,
  gitInfo,
  manifestPath,
  packageVersion,
  readJson,
  relative,
  repoRoot,
  runStep,
  sha256,
  writeJson
} from './lib/linux-release-common.mjs';
import {
  measureNativeSignerInputs,
  preparationReceiptDigest,
  validateSignedPackageArtifacts,
  verifyNativePackageSigningReceipt
} from './lib/linux-native-signing-receipt.mjs';

const args = new Set(process.argv.slice(2));
const prepareOnly = args.has('--prepare-only');
const finalizeOnly = args.has('--finalize-only');
const signingKeyEnvironmentName = 'OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM';
const versionArgIndex = process.argv.indexOf('--version');
const outDir = path.resolve(
  process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? path.join(repoRoot, '.linux-shard')
);
const appDir = path.join(repoRoot, 'apps/linux-desktop');
const manifest = readJson(manifestPath);
if (!args.has('--architecture-shard')) {
  console.error('build-linux-release.mjs is architecture-shard only; use assemble-linux-release.mjs after both native shards pass.');
  process.exit(1);
}
if (prepareOnly === finalizeOnly) {
  console.error('exactly one of --prepare-only or --finalize-only is required; one-pass release builds are forbidden.');
  process.exit(1);
}
if (Object.hasOwn(process.env, signingKeyEnvironmentName)) {
  console.error(`${signingKeyEnvironmentName} is forbidden in build/finalize phases; pass the key only to the dedicated native-package signer by stdin or file.`);
  process.exit(1);
}
const requestedVersion = versionArgIndex >= 0 ? process.argv[versionArgIndex + 1] : null;
const version = requestedVersion?.trim() || packageVersion();
const rawGit = gitInfo();
const generatedEvidencePrefix = `${relative(outDir)}/`;
const dirtyInputEntries = rawGit.dirtyEntries.filter((entry) => !entry.slice(3).startsWith(generatedEvidencePrefix));
const git = {
  ...rawGit,
  dirty: dirtyInputEntries.length > 0,
  dirtyEntries: dirtyInputEntries
};
if (git.dirty) {
  console.error(JSON.stringify({
    error: 'release checkout is dirty before artifact generation',
    dirtyEntries: git.dirtyEntries.slice(0, 40)
  }, null, 2));
  process.exit(1);
}
const logsDir = path.join(outDir, 'logs');
const artifactsDir = path.join(outDir, 'artifacts');
// Keep the pre-signing receipt under ignored build output so the dedicated
// signer still sees a clean Git checkout. Finalize publishes a copy to outDir
// only after the signer has completed.
const preparationReceiptPath = path.join(
  appDir,
  'src-tauri/target/openburnbar-release/architecture-preparation.json'
);
const signingReceiptPath = path.join(
  appDir,
  'src-tauri/target/openburnbar-release/native-package-signing.json'
);
const signingReceiptSignaturePath = `${signingReceiptPath}.ed25519.sig`;
const publishedPreparationReceiptPath = path.join(outDir, 'architecture-preparation.json');
const publishedSigningReceiptPath = path.join(outDir, 'native-package-signing.json');
const publishedSigningReceiptSignaturePath = `${publishedSigningReceiptPath}.ed25519.sig`;
const daemonBinary = path.join(repoRoot, 'OpenBurnBarDaemon/.build/release/OpenBurnBarDaemon');
const attestdManifest = path.join(repoRoot, 'crates/openburnbar-attestd/Cargo.toml');
const attestdBinary = path.join(repoRoot, 'crates/openburnbar-attestd/target/release/openburnbar-attestd');
fs.mkdirSync(logsDir, { recursive: true });
fs.mkdirSync(artifactsDir, { recursive: true });
if (prepareOnly) {
  for (const staleReceipt of [
    preparationReceiptPath,
    signingReceiptPath,
    signingReceiptSignaturePath,
    publishedPreparationReceiptPath,
    publishedSigningReceiptPath,
    publishedSigningReceiptSignaturePath
  ]) fs.rmSync(staleReceipt, { force: true });
}

const cargoBuildJobs = process.env.OPENBURNBAR_LINUX_CARGO_BUILD_JOBS?.trim() || '4';
const swiftBuildJobs = process.env.OPENBURNBAR_LINUX_SWIFT_BUILD_JOBS?.trim() || '4';
const {
  OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM: _excludedSigningKey,
  ...nonSigningEnvironment
} = process.env;
const packageBuildEnv = {
  ...nonSigningEnvironment,
  CARGO_BUILD_JOBS: cargoBuildJobs,
  // linuxdeploy (Tauri's AppImage bundler) is itself an AppImage and needs FUSE
  // to self-mount; container builds (local toolchain + CI docker) have no FUSE,
  // so tell it to self-extract instead. Harmless outside containers.
  APPIMAGE_EXTRACT_AND_RUN: '1'
};

function writeLog(name, steps) {
  const body = steps
    .map((step) => [
      `## ${step.command}`,
      `cwd=${step.cwd}`,
      `exit_code=${step.exitCode}`,
      '### stdout',
      step.stdout,
      '### stderr',
      step.stderr
    ].join('\n'))
    .join('\n\n');
  fs.writeFileSync(path.join(logsDir, name), `${body}\n`, 'utf8');
}

const blockers = [];
const daemonSteps = [];
if (!args.has('--skip-daemon') && !finalizeOnly) {
  // Swift 6.1 Linux libswiftObservation.so references swift::threading::fatal which
  // is missing from the shared libswiftCore.so (present only in the static archive).
  // --allow-shlib-undefined lets the link complete; runtime uses matching 6.1 libs.
  daemonSteps.push(runStep('swift', [
    'build',
    '--disable-automatic-resolution',
    '--jobs',
    swiftBuildJobs,
    '--package-path',
    'OpenBurnBarDaemon',
    '-c',
    'release',
    '--product',
    'OpenBurnBarDaemon',
    '-Xlinker',
    '--allow-shlib-undefined'
  ], { env: packageBuildEnv }));
}
if (!args.has('--skip-daemon') && !finalizeOnly) {
  daemonSteps.push(runStep('cargo', [
    'build',
    '--locked',
    '--release'
  ], { cwd: path.dirname(attestdManifest), env: packageBuildEnv }));
}
if (!finalizeOnly) writeLog('daemon-build.log', daemonSteps);
for (const step of daemonSteps) {
  if (step.exitCode !== 0) {
    blockers.push({
      kind: 'daemon-build',
      message: `Command failed: ${step.command}`,
      log: 'logs/daemon-build.log'
    });
  }
}

const daemonBuildPassed = daemonSteps.every((step) => step.exitCode === 0);
const daemonReady = daemonBuildPassed && fs.existsSync(daemonBinary);
const attestdReady = daemonBuildPassed && fs.existsSync(attestdBinary);
if (!daemonReady) {
  blockers.push({
    kind: 'missing-daemon-artifact',
    message: args.has('--skip-daemon')
      ? 'Required Linux daemon executable is missing at OpenBurnBarDaemon/.build/release/OpenBurnBarDaemon (stage a native binary when using --skip-daemon).'
      : 'Required native Linux daemon executable was not produced by swift build.',
    log: 'logs/daemon-build.log'
  });
}
if (!attestdReady) {
  blockers.push({
    kind: 'missing-attestation-broker-artifact',
    message: args.has('--skip-daemon')
      ? 'Required openburnbar-attestd executable is missing (stage it when using --skip-daemon).'
      : 'Required root attestation broker executable was not produced by cargo build.',
    log: 'logs/daemon-build.log'
  });
}

const buildSteps = [];
if (!args.has('--skip-tauri') && !finalizeOnly && daemonReady && attestdReady) {
  // Never let an artifact from an earlier architecture/version satisfy this shard.
  fs.rmSync(path.join(appDir, 'src-tauri/target/release/bundle'), { recursive: true, force: true });
  const packageCommands = [
    ['npm', ['ci', '--no-audit', '--no-fund'], { cwd: appDir, env: packageBuildEnv }],
    ['npm', ['run', 'build'], { cwd: appDir, env: packageBuildEnv }],
    ['npm', ['run', 'tauri:build', '--', '--bundles', 'appimage'], {
      cwd: appDir,
      env: packageBuildEnv
    }],
    ['node', ['scripts/linux-port/embed-linux-appimage-payload.mjs'], {
      cwd: repoRoot,
      env: packageBuildEnv
    }]
  ];
  for (const [command, commandArgs, options] of packageCommands) {
    const step = runStep(command, commandArgs, options);
    buildSteps.push(step);
    if (step.exitCode !== 0) break;
  }
}
if (!finalizeOnly) writeLog('package-build.log', buildSteps);
for (const step of buildSteps) {
  if (step.exitCode !== 0) {
    blockers.push({
      kind: 'package-build',
      message: `Command failed: ${step.command}`,
      log: 'logs/package-build.log'
    });
  }
}

if (prepareOnly) {
  const appImages = discoverBundleArtifacts().filter((artifact) => artifact.type === 'appimage');
  if (appImages.length !== 1) {
    blockers.push({
      kind: 'missing-appimage-preparation-artifact',
      message: `Expected one prepared AppImage, found ${appImages.length}.`
    });
  }
  let signerInputs = null;
  try {
    signerInputs = measureNativeSignerInputs(repoRoot);
  } catch (error) {
    blockers.push({
      kind: 'native-signer-inputs',
      message: `Cannot measure native package signer inputs: ${error.message}`
    });
  }
  const preparation = {
    schemaVersion: 1,
    complete: blockers.length === 0,
    version,
    architecture: linuxArch(),
    gitCommit: git.commit,
    daemonSha256: daemonReady ? sha256(daemonBinary) : null,
    attestdSha256: attestdReady ? sha256(attestdBinary) : null,
    appImageSha256: appImages.length === 1 ? sha256(appImages[0].file) : null,
    signerInputsRootSha256: signerInputs?.rootSha256 ?? null,
    signerInputRecordCount: signerInputs?.records.length ?? null,
    blockers
  };
  writeJson(preparationReceiptPath, preparation);
  console.log(JSON.stringify({
    outDir: relative(outDir),
    preparation
  }, null, 2));
  process.exit(blockers.length === 0 ? 0 : 1);
}

let preparationReceipt = null;
let currentSignerInputs = null;
let preparationValid = false;
try {
  preparationReceipt = readJson(preparationReceiptPath);
} catch (error) {
  blockers.push({
    kind: 'missing-preparation-receipt',
    message: `Finalize requires a successful --prepare-only receipt: ${error.message}`
  });
}
try {
  currentSignerInputs = measureNativeSignerInputs(repoRoot);
} catch (error) {
  blockers.push({
    kind: 'native-signer-inputs',
    message: `Finalize cannot measure native package signer inputs: ${error.message}`
  });
}
if (preparationReceipt && (
  preparationReceipt.schemaVersion !== 1
  || preparationReceipt.complete !== true
  || preparationReceipt.version !== version
  || preparationReceipt.architecture !== linuxArch()
  || preparationReceipt.gitCommit !== git.commit
  || !daemonReady
  || preparationReceipt.daemonSha256 !== sha256(daemonBinary)
  || !attestdReady
  || preparationReceipt.attestdSha256 !== sha256(attestdBinary)
  || !currentSignerInputs
  || preparationReceipt.signerInputsRootSha256 !== currentSignerInputs.rootSha256
  || preparationReceipt.signerInputRecordCount !== currentSignerInputs.records.length
)) {
  blockers.push({
    kind: 'preparation-receipt-mismatch',
    message: 'Finalize inputs do not match the successful prepare phase for this commit, version, and architecture.'
  });
} else if (preparationReceipt) {
  preparationValid = true;
}

const discoveredArtifacts = discoverBundleArtifacts();
const preparedAppImage = discoveredArtifacts.filter((artifact) => artifact.type === 'appimage');
if (preparationReceipt && (
  preparedAppImage.length !== 1
  || preparationReceipt.appImageSha256 !== sha256(preparedAppImage[0].file)
)) {
  blockers.push({
    kind: 'prepared-appimage-mismatch',
    message: 'Prepared AppImage is missing or changed after the prepare phase.'
  });
  preparationValid = false;
}

let signingReceipt = null;
try {
  const signingReceiptBytes = fs.readFileSync(signingReceiptPath);
  const signingReceiptSignature = fs.readFileSync(signingReceiptSignaturePath);
  const publicKey = crypto.createPublicKey(fs.readFileSync(
    path.join(repoRoot, 'packaging/linux/openburnbar-linux-ed25519.pub.pem')
  ));
  signingReceipt = verifyNativePackageSigningReceipt(
    signingReceiptBytes,
    signingReceiptSignature,
    publicKey
  );
  if (!preparationValid
      || !preparationReceipt
      || signingReceipt.version !== version
      || signingReceipt.architecture !== linuxArch()
      || signingReceipt.gitCommit !== git.commit
      || signingReceipt.preparationDigestSha256 !== preparationReceiptDigest(preparationReceipt)
      || !currentSignerInputs
      || signingReceipt.signerInputsRootSha256 !== currentSignerInputs.rootSha256) {
    throw new Error('signed native package receipt does not bind the current preparation and inputs');
  }
  validateSignedPackageArtifacts(repoRoot, signingReceipt, discoveredArtifacts);
} catch (error) {
  signingReceipt = null;
  blockers.push({
    kind: 'native-package-signing-receipt',
    message: `Finalize requires an authentic signer receipt and unchanged deb/rpm artifacts: ${error.message}`
  });
}

if (preparationValid && preparationReceipt && signingReceipt) {
  writeJson(publishedPreparationReceiptPath, preparationReceipt);
  fs.copyFileSync(signingReceiptPath, publishedSigningReceiptPath);
  fs.copyFileSync(signingReceiptSignaturePath, publishedSigningReceiptSignaturePath);
}

const copied = discoveredArtifacts.map((artifact) => {
  const dest = copyArtifact(artifact.file, artifactsDir);
  return {
    type: artifact.type,
    architecture: linuxArch(),
    file: relative(dest),
    sourceFile: relative(artifact.file),
    size: fileSize(dest),
    sha256: sha256(dest)
  };
});
// Always package a prebuilt daemon when present (supports --skip-daemon after a
// guest/CI binary is staged at OpenBurnBarDaemon/.build/release/OpenBurnBarDaemon).
if (daemonReady) {
  const daemonArtifact = path.join(artifactsDir, `openburnbar-daemon-${version}-linux-${linuxArch()}`);
  fs.copyFileSync(daemonBinary, daemonArtifact);
  fs.chmodSync(daemonArtifact, 0o755);
  copied.push({
    type: 'daemon',
    architecture: linuxArch(),
    file: relative(daemonArtifact),
    sourceFile: relative(daemonBinary),
    size: fileSize(daemonArtifact),
    sha256: sha256(daemonArtifact)
  });
}

for (const required of manifest.requiredArtifacts) {
  if (!copied.some((artifact) => artifact.type === required)) {
    blockers.push({
      kind: 'missing-artifact',
      message: `Required Linux ${required} artifact was not produced by Tauri bundle output.`
    });
  }
}

{
  const architecture = linuxArch();
  const keys = new Set();
  for (const artifact of copied) {
    const key = `${artifact.type}:${artifact.architecture}`;
    if (keys.has(key)) {
      blockers.push({
        kind: 'duplicate-architecture-artifact',
        message: `Architecture shard produced duplicate ${key} artifacts.`
      });
    }
    keys.add(key);
    if (artifact.architecture !== architecture) {
      blockers.push({
        kind: 'architecture-mismatch',
        message: `Architecture shard ${architecture} produced ${key}.`
      });
    }
  }
  const shard = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    version,
    git,
    architecture,
    firebaseAppId: signingReceipt?.firebaseAppId ?? null,
    artifacts: copied,
    blockers
  };
  writeJson(path.join(outDir, 'architecture-closure.json'), shard);
  console.log(JSON.stringify({ outDir: relative(outDir), shard }, null, 2));
  process.exit(blockers.length === 0 ? 0 : 1);
}

function linuxArch() {
  switch (process.arch) {
    case 'arm64':
      return 'aarch64';
    case 'x64':
      return 'x86_64';
    default:
      return process.arch;
  }
}
