#!/usr/bin/env node
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
  verifyEd25519Signature,
  writeJson
} from './lib/linux-release-common.mjs';
import { verifySignedNativePackage } from './lib/linux-native-package.mjs';
import { withoutLinuxReleasePrivateKey } from './lib/linux-signing-environment.mjs';

const args = new Set(process.argv.slice(2));
const versionArgIndex = process.argv.indexOf('--version');
const phaseArgIndex = process.argv.indexOf('--phase');
const outDir = path.resolve(
  process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? path.join(repoRoot, '.linux-shard')
);
const appDir = path.join(repoRoot, 'apps/linux-desktop');
const manifest = readJson(manifestPath);
if (!args.has('--architecture-shard')) {
  console.error('build-linux-release.mjs is architecture-shard only; use assemble-linux-release.mjs after both native shards pass.');
  process.exit(1);
}
if (args.has('--skip-tauri')) {
  console.error('--skip-tauri is not supported for architecture closure; native packages must be rebuilt and reverified.');
  process.exit(1);
}
const phase = phaseArgIndex >= 0 ? process.argv[phaseArgIndex + 1]?.trim() : '';
if (!['prepare', 'finalize'].includes(phase)) {
  console.error('--phase prepare or --phase finalize is required for architecture closure.');
  process.exit(1);
}
if (process.env.OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM) {
  console.error(`${phase} architecture builds must not receive OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM; use sign-linux-release-requests.mjs in an isolated signer.`);
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
const installedManifestsDir = path.join(outDir, 'installed-manifests');
const signingStateDir = path.join(outDir, 'signing-state');
const daemonBinary = path.join(repoRoot, 'OpenBurnBarDaemon/.build/release/OpenBurnBarDaemon');
const cliBinary = path.join(repoRoot, 'OpenBurnBarDaemon/.build/release/OpenBurnBarCLI');
const irohManifest = path.join(repoRoot, 'crates/openburnbar-iroh/Cargo.toml');
const irohTargetDirectory = path.join(repoRoot, 'crates/openburnbar-iroh/target-linux-release');
const irohNativeLibraryDirectory = path.join(irohTargetDirectory, 'release');
const irohNativeLibrary = path.join(irohNativeLibraryDirectory, 'libopenburnbar_iroh.so');
const mediaManifest = path.join(repoRoot, 'crates/openburnbar-media/Cargo.toml');
const mediaTargetDirectory = path.join(repoRoot, 'crates/openburnbar-media/target-linux-release');
const mediaNativeLibraryDirectory = path.join(mediaTargetDirectory, 'release');
const mediaNativeLibrary = path.join(mediaNativeLibraryDirectory, 'libopenburnbar_media.so');
if (phase === 'finalize') {
  fs.rmSync(artifactsDir, { recursive: true, force: true });
  fs.rmSync(installedManifestsDir, { recursive: true, force: true });
}
fs.mkdirSync(logsDir, { recursive: true });
fs.mkdirSync(artifactsDir, { recursive: true });
fs.mkdirSync(installedManifestsDir, { recursive: true });

const cargoBuildJobs = process.env.OPENBURNBAR_LINUX_CARGO_BUILD_JOBS?.trim() || '4';
const irohCargoBuildJobs = process.env.OPENBURNBAR_LINUX_IROH_BUILD_JOBS?.trim() || '1';
const swiftBuildJobs = process.env.OPENBURNBAR_LINUX_SWIFT_BUILD_JOBS?.trim() || '4';
const packageBuildEnv = withoutLinuxReleasePrivateKey(process.env);
Object.assign(packageBuildEnv, {
  OPENBURNBAR_LINUX_RELEASE_BUILD: '1',
  OPENBURNBAR_LINUX_CLI_BIN: cliBinary,
  CARGO_BUILD_JOBS: cargoBuildJobs,
  OPENBURNBAR_LINUX_IROH_LIBRARY_DIR: irohNativeLibraryDirectory,
  // The daemon's Mercury capture ABI is a separate Rust crate from the iroh
  // file-transfer runtime. Build and link it in the same release graph so a
  // signed package cannot advertise the GStreamer viewer while shipping a
  // daemon that reports media capture as unavailable.
  OPENBURNBAR_MEDIA_CAPTURE_LIBRARY_DIR: mediaNativeLibraryDirectory,
  OPENBURNBAR_MEDIA_CAPTURE_RELEASE: '1',
  // linuxdeploy (Tauri's AppImage bundler) is itself an AppImage and needs FUSE
  // to self-mount; container builds (local toolchain + CI docker) have no FUSE,
  // so tell it to self-extract instead. Harmless outside containers.
  APPIMAGE_EXTRACT_AND_RUN: '1'
});

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

// Keep release failures diagnosable in hosted jobs even when the mounted shard
// directory is unavailable to the failure-reporting step.
function printFailedSteps(steps) {
  for (const step of steps) {
    if (step.exitCode === 0) continue;
    console.error(`linux release step failed: ${step.command}`);
    for (const [label, output] of [['stdout', step.stdout], ['stderr', step.stderr]]) {
      const text = String(output ?? '');
      if (!text) continue;
      console.error(`--- ${label} (tail) ---`);
      console.error(text.slice(-20000));
    }
  }
}

const blockers = [];
const daemonSteps = [];
if (phase === 'prepare' && !args.has('--skip-daemon')) {
  daemonSteps.push(runStep('cargo', [
    'build',
    '--manifest-path',
    irohManifest,
    '--target-dir',
    irohTargetDirectory,
    '--locked',
    '--release',
    '--jobs',
    irohCargoBuildJobs
  ], { env: { ...packageBuildEnv, CARGO_BUILD_JOBS: irohCargoBuildJobs } }));
}
if (phase === 'prepare' && !args.has('--skip-daemon') && daemonSteps.every((step) => step.exitCode === 0)) {
  daemonSteps.push(runStep('cargo', [
    'build',
    '--manifest-path',
    mediaManifest,
    '--target-dir',
    mediaTargetDirectory,
    '--locked',
    '--release',
    '--jobs',
    cargoBuildJobs
  ], { env: packageBuildEnv }));
}
if (phase === 'prepare' && !args.has('--skip-daemon') && daemonSteps.every((step) => step.exitCode === 0)) {
  // Swift 6.1 Linux libswiftObservation.so references swift::threading::fatal which
  // is missing from the shared libswiftCore.so (present only in the static archive).
  // --allow-shlib-undefined lets the link complete; runtime uses matching 6.1 libs.
  // SwiftPM evaluates OpenBurnBarCore/Package.swift in the child process, so the
  // sanitized release environment must reach both products or the manifest will
  // omit OpenBurnBarIrohFFI even though the native runtime is staged.
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
  if (daemonSteps.every((step) => step.exitCode === 0)) {
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
      'OpenBurnBarCLI',
      '-Xlinker',
      '--allow-shlib-undefined'
    ], { env: packageBuildEnv }));
  }
}
writeLog('daemon-build.log', daemonSteps);
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
const irohNativeReady = fs.existsSync(irohNativeLibrary);
const mediaNativeReady = fs.existsSync(mediaNativeLibrary);
const daemonReady = daemonBuildPassed && fs.existsSync(daemonBinary);
const cliReady = daemonBuildPassed && fs.existsSync(cliBinary);
if (!daemonReady) {
  blockers.push({
    kind: 'missing-daemon-artifact',
    message: args.has('--skip-daemon')
      ? 'Required Linux daemon executable is missing at OpenBurnBarDaemon/.build/release/OpenBurnBarDaemon (stage a native binary when using --skip-daemon).'
      : 'Required native Linux daemon executable was not produced by swift build.',
    log: 'logs/daemon-build.log'
  });
}
if (!cliReady) {
  blockers.push({
    kind: 'missing-cli-artifact',
    message: args.has('--skip-daemon')
      ? 'Required Linux OpenBurnBarCLI executable is missing at OpenBurnBarDaemon/.build/release/OpenBurnBarCLI (stage it when using --skip-daemon).'
      : 'Required native Linux OpenBurnBarCLI executable was not produced by swift build.',
    log: 'logs/daemon-build.log'
  });
}
if (!irohNativeReady) {
  blockers.push({
    kind: 'missing-iroh-native-artifact',
    message: args.has('--skip-daemon')
      ? `Required Linux iroh runtime is missing at ${relative(irohNativeLibrary)} (stage it when using --skip-daemon).`
      : 'Required Linux iroh UniFFI runtime was not produced before the Swift daemon build.',
    log: 'logs/daemon-build.log'
  });
}
if (!mediaNativeReady) {
  blockers.push({
    kind: 'missing-media-native-artifact',
    message: args.has('--skip-daemon')
      ? `Required Linux Mercury media runtime is missing at ${relative(mediaNativeLibrary)} (stage it when using --skip-daemon).`
      : 'Required Linux Mercury media runtime was not produced before the Swift daemon build.',
    log: 'logs/daemon-build.log'
  });
}

const buildSteps = [];
// Prepare owns cleanup. Finalize retains the independently made Arch artifact
// while rebuilding and verifying the signed Tauri-native artifacts.
if (phase === 'prepare') {
  fs.rmSync(path.join(appDir, 'src-tauri/target/release/bundle'), { recursive: true, force: true });
}
if (daemonReady && cliReady && irohNativeReady && mediaNativeReady) {
  // Never let an artifact from an earlier architecture/version satisfy this shard.
  const prepareCommands = [
    ['npm', ['ci', '--no-audit', '--no-fund'], { cwd: appDir, env: packageBuildEnv }],
    ['npm', ['run', 'build'], { cwd: appDir, env: packageBuildEnv }],
    // Release artifacts must contain the real Mercury viewer. Development
    // builds intentionally keep the feature optional so a generic checkout
    // can still run with the explicit stub capability.
    ['npm', ['run', 'tauri:build', '--', '--no-bundle', '--features', 'media-gst'], {
      cwd: appDir,
      env: packageBuildEnv
    }],
    ['node', [
      'scripts/linux-port/bundle-signed-linux-packages.mjs',
      '--phase',
      'prepare',
      '--version',
      version,
      '--git-commit',
      git.commit,
      '--state-dir',
      signingStateDir
    ], {
      cwd: repoRoot,
      env: packageBuildEnv
    }]
  ];
  const finalizeCommands = [[
    'node',
    [
      'scripts/linux-port/bundle-signed-linux-packages.mjs',
      '--phase',
      'finalize',
      '--version',
      version,
      '--git-commit',
      git.commit,
      '--state-dir',
      signingStateDir
    ],
    { cwd: repoRoot, env: packageBuildEnv }
  ]];
  const packageCommands = phase === 'prepare' ? prepareCommands : finalizeCommands;
  for (const [command, commandArgs, options] of packageCommands) {
    const step = runStep(command, commandArgs, options);
    buildSteps.push(step);
    if (step.exitCode !== 0) break;
  }
}
writeLog('package-build.log', buildSteps);
for (const step of buildSteps) {
  if (step.exitCode !== 0) {
    blockers.push({
      kind: 'package-build',
      message: `Command failed: ${step.command}`,
      log: 'logs/package-build.log'
    });
  }
}
if (blockers.length > 0) printFailedSteps([...daemonSteps, ...buildSteps]);

if (phase === 'prepare') {
  const preparation = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    version,
    git,
    architecture: linuxArch(),
    signingState: relative(signingStateDir),
    signingRequest: relative(path.join(signingStateDir, 'signing-request.json')),
    blockers
  };
  writeJson(path.join(outDir, 'signing-preparation.json'), preparation);
  console.log(JSON.stringify({ outDir: relative(outDir), preparation }, null, 2));
  process.exit(blockers.length === 0 ? 0 : 1);
}

const releasePublicKey = path.join(repoRoot, 'packaging/linux/openburnbar-linux-ed25519.pub.pem');
const copied = discoverBundleArtifacts().map((artifact) => {
  const dest = copyArtifact(artifact.file, artifactsDir);
  const record = {
    type: artifact.type,
    architecture: linuxArch(),
    file: relative(dest),
    sourceFile: relative(artifact.file),
    size: fileSize(dest),
    sha256: sha256(dest)
  };
  if (['arch', 'deb', 'rpm'].includes(artifact.type)) {
    const attestationSource = path.join(
      appDir,
      'src-tauri/target/release/bundle/attestation',
      `${artifact.type}-${linuxArch()}.installed-manifest.json`
    );
    const signatureSource = `${attestationSource}.sig`;
    if (!fs.existsSync(attestationSource) || !fs.existsSync(signatureSource)) {
      blockers.push({
        kind: 'missing-installed-manifest',
        message: `Required signed installed manifest was not produced for ${artifact.type}:${linuxArch()}.`
      });
      return record;
    }
    const manifestBytes = fs.readFileSync(attestationSource);
    const signatureBytes = fs.readFileSync(signatureSource);
    let installedManifest = null;
    try {
      installedManifest = JSON.parse(manifestBytes.toString('utf8'));
    } catch (error) {
      blockers.push({ kind: 'installed-manifest-json', message: `${artifact.type}:${linuxArch()} manifest is invalid JSON: ${error.message}` });
    }
    if (signatureBytes.length !== 64
        || !verifyEd25519Signature(manifestBytes, signatureBytes, fs.readFileSync(releasePublicKey))) {
      blockers.push({ kind: 'installed-manifest-signature', message: `${artifact.type}:${linuxArch()} installed manifest signature is invalid.` });
    }
    if (installedManifest
        && (installedManifest.gitCommit !== git.commit
          || installedManifest.packageVersion !== version
          || installedManifest.packageArchitecture !== linuxArch()
          || installedManifest.packageFormat !== artifact.type
          || installedManifest.packageName !== (artifact.type === 'arch' ? 'openburnbar' : 'open-burn-bar'))) {
      blockers.push({ kind: 'installed-manifest-binding', message: `${artifact.type}:${linuxArch()} installed manifest identity is not release-bound.` });
    }
    try {
      verifySignedNativePackage({
        format: artifact.type,
        artifact: dest,
        manifestBytes,
        signatureBytes,
        publicKeyPem: fs.readFileSync(releasePublicKey),
        env: packageBuildEnv
      });
    } catch (error) {
      blockers.push({
        kind: 'installed-manifest-package-binding',
        message: `${artifact.type}:${linuxArch()} package does not match its signed installed manifest: ${error.message}`
      });
    }
    const manifestDestination = path.join(
      installedManifestsDir,
      `${artifact.type}-${linuxArch()}.installed-manifest.json`
    );
    const signatureDestination = `${manifestDestination}.sig`;
    fs.copyFileSync(attestationSource, manifestDestination);
    fs.copyFileSync(signatureSource, signatureDestination);
    record.installedManifest = shardRecord(manifestDestination);
    record.installedManifestSignature = shardRecord(signatureDestination);
  }
  return record;
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

function shardRecord(file) {
  return {
    file: path.relative(outDir, file).split(path.sep).join('/'),
    sha256: sha256(file),
    size: fileSize(file)
  };
}
