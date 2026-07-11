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
  writeJson
} from './lib/linux-release-common.mjs';

const args = new Set(process.argv.slice(2));
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
const daemonBinary = path.join(repoRoot, 'OpenBurnBarDaemon/.build/release/OpenBurnBarDaemon');
const irohManifest = path.join(repoRoot, 'crates/openburnbar-iroh/Cargo.toml');
const irohTargetDirectory = path.join(repoRoot, 'crates/openburnbar-iroh/target-linux-release');
const irohNativeLibraryDirectory = path.join(irohTargetDirectory, 'release');
const irohNativeLibrary = path.join(irohNativeLibraryDirectory, 'libopenburnbar_iroh.so');
fs.mkdirSync(logsDir, { recursive: true });
fs.mkdirSync(artifactsDir, { recursive: true });

const cargoBuildJobs = process.env.OPENBURNBAR_LINUX_CARGO_BUILD_JOBS?.trim() || '4';
const irohCargoBuildJobs = process.env.OPENBURNBAR_LINUX_IROH_BUILD_JOBS?.trim() || '1';
const swiftBuildJobs = process.env.OPENBURNBAR_LINUX_SWIFT_BUILD_JOBS?.trim() || '4';
const packageBuildEnv = {
  ...process.env,
  CARGO_BUILD_JOBS: cargoBuildJobs,
  OPENBURNBAR_LINUX_IROH_LIBRARY_DIR: irohNativeLibraryDirectory,
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
if (!args.has('--skip-daemon')) {
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
if (!args.has('--skip-daemon') && daemonSteps.every((step) => step.exitCode === 0)) {
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
  ]));
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
const daemonReady = daemonBuildPassed && fs.existsSync(daemonBinary);
if (!daemonReady) {
  blockers.push({
    kind: 'missing-daemon-artifact',
    message: args.has('--skip-daemon')
      ? 'Required Linux daemon executable is missing at OpenBurnBarDaemon/.build/release/OpenBurnBarDaemon (stage a native binary when using --skip-daemon).'
      : 'Required native Linux daemon executable was not produced by swift build.',
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

const buildSteps = [];
if (!args.has('--skip-tauri') && daemonReady && irohNativeReady) {
  // Never let an artifact from an earlier architecture/version satisfy this shard.
  fs.rmSync(path.join(appDir, 'src-tauri/target/release/bundle'), { recursive: true, force: true });
  const packageCommands = [
    ['npm', ['ci', '--no-audit', '--no-fund'], { cwd: appDir }],
    ['npm', ['run', 'build'], { cwd: appDir }],
    ['npm', ['run', 'tauri:build', '--', '--bundles', 'deb,rpm,appimage'], {
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

const copied = discoverBundleArtifacts().map((artifact) => {
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
