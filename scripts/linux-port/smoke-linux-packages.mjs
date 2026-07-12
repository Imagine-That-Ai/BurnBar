#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { readJson, releaseEvidenceDir, repoRoot, runStep, writeJson } from './lib/linux-release-common.mjs';
import { findAppImageFilesystemOffset } from './lib/appimage-filesystem.mjs';
import {
  linuxAppImagePeerExecutableRelativePath,
  linuxAppImagePeerManifestName,
  linuxAppImagePeerSignatureName,
  verifyLinuxAppImagePeerManifest
} from './lib/linux-appimage-peer-manifest.mjs';
import { installedPackageVerificationStep } from './lib/linux-package-smoke-installed.mjs';

const outDir = path.resolve(process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? releaseEvidenceDir);
const shardMode = process.argv.includes('--architecture-shard');
const closurePath = path.join(outDir, shardMode ? 'architecture-closure.json' : 'package-closure.json');
const smokeDir = path.join(outDir, 'smoke');
fs.mkdirSync(smokeDir, { recursive: true });

if (!fs.existsSync(closurePath)) {
  console.error(`${path.basename(closurePath)} missing; run build-linux-release first.`);
  process.exit(1);
}

const closure = readJson(closurePath);
const steps = [];

function assertContains(command, haystack, needle, stderr) {
  const ok = typeof haystack === 'string' && haystack.includes(needle);
  steps.push({
    command,
    cwd: '.',
    exitCode: ok ? 0 : 1,
    stdout: ok ? `found ${needle}` : '',
    stderr: ok ? '' : stderr
  });
  return ok;
}

function runtimeProbeEnv(label) {
  const root = path.join(smokeDir, 'runtime-probes', label);
  fs.rmSync(root, { recursive: true, force: true });
  fs.mkdirSync(root, { recursive: true });
  return {
    ...process.env,
    HOME: root,
    XDG_CONFIG_HOME: path.join(root, 'config'),
    XDG_DATA_HOME: path.join(root, 'data'),
    XDG_RUNTIME_DIR: path.join(root, 'run')
  };
}

function readShardSubject(record, label) {
  if (record === null || typeof record !== 'object' || Array.isArray(record)
      || typeof (record.file ?? record.path) !== 'string'
      || !/^[a-f0-9]{64}$/u.test(record.sha256 ?? '')
      || !Number.isInteger(record.size) || record.size < 0) {
    throw new Error(`${label} record is missing or invalid`);
  }
  const absolute = path.resolve(outDir, record.file ?? record.path);
  const relative = path.relative(outDir, absolute);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} is outside the architecture shard`);
  }
  let current = outDir;
  for (const component of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    if (fs.lstatSync(current).isSymbolicLink()) throw new Error(`${label} traverses a symlink`);
  }
  const stat = fs.lstatSync(absolute);
  if (!stat.isFile() || stat.size !== record.size) throw new Error(`${label} is not the recorded regular file`);
  const bytes = fs.readFileSync(absolute);
  const digest = crypto.createHash('sha256').update(bytes).digest('hex');
  if (digest !== record.sha256) throw new Error(`${label} SHA-256 does not match the architecture closure`);
  return bytes;
}

for (const artifact of closure.artifacts ?? []) {
  const full = path.join(repoRoot, artifact.file);
  if (!fs.existsSync(full)) {
    steps.push({
      command: `assert artifact exists ${artifact.type}`,
      cwd: '.',
      exitCode: 1,
      stdout: '',
      stderr: `missing artifact file: ${artifact.file}`
    });
    continue;
  }
  if (artifact.type === 'deb') {
    steps.push(runStep('dpkg-deb', ['--info', full]));
    const contents = runStep('dpkg-deb', ['--contents', full]);
    steps.push(contents);
    // Unit ExecStart=/usr/libexec/openburnbar-daemon-launch must ship in the package.
    assertContains(
      'assert deb contains openburnbar-daemon-launch',
      contents.stdout,
      'openburnbar-daemon-launch',
      'deb package missing /usr/libexec/openburnbar-daemon-launch (203/EXEC risk)'
    );
    assertContains(
      'assert deb contains openburnbar-daemon binary',
      contents.stdout,
      'usr/bin/openburnbar-daemon',
      'deb package missing /usr/bin/openburnbar-daemon'
    );
    assertContains(
      'assert deb contains openburnbar-daemon.service',
      contents.stdout,
      'openburnbar-daemon.service',
      'deb package missing systemd user unit'
    );
    assertContains(
      'assert deb contains Swift runtime under usr/lib/openburnbar/swift',
      contents.stdout,
      'usr/lib/openburnbar/swift',
      'deb package missing Swift runtime at /usr/lib/openburnbar/swift'
    );
    assertContains(
      'assert deb contains SQLCipher runtime under usr/lib/openburnbar/native',
      contents.stdout,
      'usr/lib/openburnbar/native/libsqlcipher.so.0',
      'deb package missing SQLCipher runtime at /usr/lib/openburnbar/native'
    );
    assertContains(
      'assert deb contains iroh runtime under usr/lib/openburnbar/native',
      contents.stdout,
      'usr/lib/openburnbar/native/libopenburnbar_iroh.so',
      'deb package missing iroh runtime at /usr/lib/openburnbar/native'
    );
    for (const attestationPath of [
      'usr/share/openburnbar/attestation/installed-manifest.json',
      'usr/share/openburnbar/attestation/installed-manifest.json.sig',
      'usr/share/openburnbar/attestation/release-ed25519.pub.pem'
    ]) {
      assertContains(
        `assert deb contains ${attestationPath}`,
        contents.stdout,
        attestationPath,
        `deb package missing /${attestationPath}`
      );
    }
    // Prefer sudo when non-root (guest packaging smoke).
    const dpkgInstall = runStep('sudo', ['dpkg', '-i', full]);
    if (dpkgInstall.exitCode !== 0) {
      steps.push(runStep('dpkg', ['-i', full]));
    } else {
      steps.push(dpkgInstall);
    }
    steps.push(installedPackageVerificationStep({ artifact, readSubject: readShardSubject }));
    steps.push(runStep('/usr/libexec/openburnbar-daemon-launch', ['--help'], {
      env: runtimeProbeEnv(`deb-${artifact.architecture}`)
    }));
    // Derive the real package name from the artifact so uninstall targets the
    // exact installed package (Tauri names it `open-burn-bar`, not `openburnbar`).
    const debName = runStep('dpkg-deb', ['-f', full, 'Package']).stdout.trim() || 'open-burn-bar';
    const dpkgRemove = runStep('sudo', ['dpkg', '-r', debName]);
    if (dpkgRemove.exitCode !== 0) {
      steps.push(runStep('dpkg', ['-r', debName]));
    } else {
      steps.push(dpkgRemove);
    }
  } else if (artifact.type === 'rpm') {
    steps.push(runStep('rpm', ['-qip', full]));
    const listing = runStep('rpm', ['-qlp', full]);
    steps.push(listing);
    assertContains(
      'assert rpm contains openburnbar-daemon-launch',
      listing.stdout,
      'openburnbar-daemon-launch',
      'rpm package missing /usr/libexec/openburnbar-daemon-launch (203/EXEC risk)'
    );
    assertContains(
      'assert rpm contains openburnbar-daemon binary',
      listing.stdout,
      '/usr/bin/openburnbar-daemon',
      'rpm package missing /usr/bin/openburnbar-daemon'
    );
    assertContains(
      'assert rpm contains Swift runtime under /usr/lib/openburnbar/swift',
      listing.stdout,
      '/usr/lib/openburnbar/swift',
      'rpm package missing Swift runtime at /usr/lib/openburnbar/swift'
    );
    assertContains(
      'assert rpm contains SQLCipher runtime under /usr/lib/openburnbar/native',
      listing.stdout,
      '/usr/lib/openburnbar/native/libsqlcipher.so.0',
      'rpm package missing SQLCipher runtime at /usr/lib/openburnbar/native'
    );
    assertContains(
      'assert rpm contains iroh runtime under /usr/lib/openburnbar/native',
      listing.stdout,
      '/usr/lib/openburnbar/native/libopenburnbar_iroh.so',
      'rpm package missing iroh runtime at /usr/lib/openburnbar/native'
    );
    for (const attestationPath of [
      '/usr/share/openburnbar/attestation/installed-manifest.json',
      '/usr/share/openburnbar/attestation/installed-manifest.json.sig',
      '/usr/share/openburnbar/attestation/release-ed25519.pub.pem'
    ]) {
      assertContains(
        `assert rpm contains ${attestationPath}`,
        listing.stdout,
        attestationPath,
        `rpm package missing ${attestationPath}`
      );
    }
    const rpmInstall = runStep('sudo', ['rpm', '-i', '--nodeps', '--force', full]);
    if (rpmInstall.exitCode !== 0) {
      steps.push(runStep('rpm', ['-i', '--nodeps', '--force', full]));
    } else {
      steps.push(rpmInstall);
    }
    steps.push(installedPackageVerificationStep({ artifact, readSubject: readShardSubject }));
    steps.push(runStep('/usr/libexec/openburnbar-daemon-launch', ['--help'], {
      env: runtimeProbeEnv(`rpm-${artifact.architecture}`)
    }));
    const rpmName = runStep('rpm', ['-qp', '--queryformat', '%{NAME}', full]).stdout.trim() || 'open-burn-bar';
    const rpmErase = runStep('sudo', ['rpm', '-e', rpmName]);
    if (rpmErase.exitCode !== 0) {
      steps.push(runStep('rpm', ['-e', rpmName]));
    } else {
      steps.push(rpmErase);
    }
  } else if (artifact.type === 'appimage') {
    fs.chmodSync(full, 0o755);
    const appDir = path.join(repoRoot, 'squashfs-root');
    fs.rmSync(appDir, { recursive: true, force: true });
    let filesystemOffset = null;
    try {
      filesystemOffset = findAppImageFilesystemOffset(full);
    } catch (error) {
      steps.push({
        command: `locate AppImage SquashFS filesystem ${artifact.architecture}`,
        cwd: '.',
        exitCode: 1,
        stdout: '',
        stderr: error.message
      });
    }
    const extract = filesystemOffset === null
      ? null
      : runStep('unsquashfs', [
        '-quiet',
        '-no-progress',
        '-dest',
        appDir,
        '-offset',
        String(filesystemOffset),
        full
      ]);
    if (extract) steps.push(extract);
    if (extract?.exitCode === 0) {
      for (const requiredPath of [
        'usr/bin/openburnbar-daemon',
        'usr/libexec/openburnbar-daemon-launch',
        'usr/lib/openburnbar/swift',
        'usr/lib/openburnbar/native/libsqlcipher.so.0',
        'usr/lib/openburnbar/native/libopenburnbar_iroh.so',
        `usr/share/openburnbar/${linuxAppImagePeerManifestName}`,
        `usr/share/openburnbar/${linuxAppImagePeerSignatureName}`
      ]) {
        const present = fs.existsSync(path.join(appDir, requiredPath));
        steps.push({
          command: `assert AppImage contains ${requiredPath}`,
          cwd: '.',
          exitCode: present ? 0 : 1,
          stdout: present ? `found ${requiredPath}` : '',
          stderr: present ? '' : `AppImage missing ${requiredPath}`
        });
      }
      try {
        const manifest = verifyLinuxAppImagePeerManifest({
          manifestBytes: fs.readFileSync(path.join(appDir, `usr/share/openburnbar/${linuxAppImagePeerManifestName}`)),
          signature: fs.readFileSync(path.join(appDir, `usr/share/openburnbar/${linuxAppImagePeerSignatureName}`)),
          executable: path.join(appDir, linuxAppImagePeerExecutableRelativePath),
          publicKeyPem: fs.readFileSync(path.join(repoRoot, 'packaging/linux/openburnbar-linux-ed25519.pub.pem'))
        });
        steps.push({
          command: `verify signed AppImage peer manifest ${artifact.architecture}`,
          cwd: '.',
          exitCode: 0,
          stdout: `verified ${manifest.executableRelativePath} ${manifest.executableSHA256}`,
          stderr: ''
        });
      } catch (error) {
        steps.push({
          command: `verify signed AppImage peer manifest ${artifact.architecture}`,
          cwd: '.',
          exitCode: 1,
          stdout: '',
          stderr: error.message
        });
      }
      steps.push(runStep(path.join(appDir, 'usr/libexec/openburnbar-daemon-launch'), ['--help'], {
        env: {
          ...runtimeProbeEnv(`appimage-${artifact.architecture}`),
          APPDIR: appDir
        }
      }));
    }
    // Native CI exercises the AppImage runtime. Cross-architecture local shards
    // can explicitly probe the extracted AppRun while retaining byte-level
    // SquashFS and payload verification above.
    const runtimeProbe = process.env.OPENBURNBAR_APPIMAGE_RUNTIME_PROBE?.trim() || 'appimage';
    if (runtimeProbe === 'appimage') {
      steps.push(runStep(full, ['--appimage-extract-and-run', '--version']));
    } else if (runtimeProbe === 'extracted' && extract?.exitCode === 0) {
      steps.push(runStep(path.join(appDir, 'AppRun'), ['--version'], {
        env: { ...runtimeProbeEnv(`appimage-runtime-${artifact.architecture}`), APPDIR: appDir }
      }));
    } else {
      steps.push({
        command: 'validate OPENBURNBAR_APPIMAGE_RUNTIME_PROBE',
        cwd: '.',
        exitCode: 1,
        stdout: '',
        stderr: `invalid or unavailable AppImage runtime probe: ${runtimeProbe}`
      });
    }
    // Remove the extraction dir so the release verifier's clean-worktree check
    // binds to the committed release commit.
    fs.rmSync(path.join(repoRoot, 'squashfs-root'), { recursive: true, force: true });
  } else if (artifact.type === 'daemon') {
    fs.chmodSync(full, 0o755);
    const help = runStep(full, ['--help']);
    steps.push(help);
    assertContains(
      'assert daemon binary responds to --help',
      `${help.stdout}\n${help.stderr}`,
      'socket-path',
      'daemon binary --help did not print expected usage'
    );
  }
}

const installLog = steps
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
fs.writeFileSync(path.join(smokeDir, 'package-install-uninstall.log'), `${installLog}\n`, 'utf8');

const update = {
  generatedAt: new Date().toISOString(),
  status: 'blocked',
  reason: 'No previous stable Linux artifact exists yet; first promotable Linux release must attach previous/prerelease artifacts before this smoke can pass.',
  requiredFlow: [
    'install previous stable or prerelease package',
    'verify daemon and shell launch',
    'apply latest-linux candidate update',
    'verify version/commit move forward',
    'roll back to previous artifact and verify user data remains'
  ]
};
writeJson(path.join(smokeDir, 'package-update-rollback.json'), update);
fs.writeFileSync(path.join(smokeDir, 'package-update-rollback.log'), `${JSON.stringify(update, null, 2)}\n`, 'utf8');

const failed = steps.filter((step) => step.exitCode !== 0);
if (shardMode) {
  const architectureSummary = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    architecture: closure.architecture,
    steps: steps.length,
    failedCount: failed.length,
    failed: failed.slice(0, 20),
    passed: failed.length === 0
  };
  writeJson(path.join(smokeDir, 'architecture-smoke.json'), architectureSummary);
  console.log(JSON.stringify(architectureSummary, null, 2));
  process.exit(architectureSummary.passed ? 0 : 1);
}
const lifecycle = {
  guiLaunch: {
    status: 'blocked',
    reason: 'Package inspection and --version do not prove a painted interactive GUI launch.'
  },
  daemonLaunch: {
    status: 'blocked',
    reason: 'Daemon --help does not prove package-owned service launch and health.'
  },
  versionReadback: {
    status: 'blocked',
    reason: 'Smoke does not yet read both package version and source commit from the running GUI and daemon.'
  },
  update: { status: update.status, reason: update.reason },
  rollback: { status: update.status, reason: update.reason },
  dataPreservation: { status: update.status, reason: update.reason }
};
const lifecyclePassed = Object.values(lifecycle).every((step) => step.status === 'passed');
const summary = {
  steps: steps.length,
  failedCount: failed.length,
  failed: failed.slice(0, 20),
  update,
  lifecycle,
  passed: failed.length === 0 && lifecyclePassed
};
writeJson(path.join(smokeDir, 'package-smoke-summary.json'), summary);
console.log(JSON.stringify(summary, null, 2));
// Fail closed: any assert/install failure is a hard smoke failure.
process.exit(summary.passed ? 0 : 1);
