#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {
  readJson,
  repoRoot,
  runStep,
  writeJson
} from './lib/linux-release-common.mjs';
import { installedPackageVerificationStep } from './lib/linux-package-smoke-installed.mjs';
import {
  archPackageRemovalCandidates,
  inspectArchPackageDependencies,
  remainingFilesystemEntriesNoFollow
} from './lib/linux-native-package.mjs';

const outDir = path.resolve(process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? path.join(repoRoot, '.linux-shard'));
const closure = readJson(path.join(outDir, 'architecture-closure.json'));
const artifacts = (closure.artifacts ?? []).filter((entry) => entry.type === 'arch');
if (artifacts.length !== 1) throw new Error(`Arch smoke requires exactly one artifact, found ${artifacts.length}`);
const artifact = artifacts[0];
const full = readRecordedFile(artifact, 'Arch package artifact').file;
const steps = [];
const dependencies = inspectArchPackageDependencies(full);
const dependencyPackages = [...new Set(dependencies.map((dependency) => {
  const match = /^([a-z0-9@._+:-]+)/u.exec(dependency);
  if (!match) throw new Error(`Arch dependency cannot be installed safely: ${dependency}`);
  return match[1];
}))];

steps.push(runStep('pacman', ['-Qip', full]));
steps.push(runStep('pacman', ['-Qlp', full]));
steps.push(runStep('pacman', ['-Syu', '--noconfirm', '--needed', ...dependencyPackages]));
steps.push(runStep('pacman', ['-T', ...dependencies]));
const install = runStep('pacman', ['-U', '--noconfirm', full]);
steps.push(install);
let packageOwnedFiles = [];
if (install.exitCode === 0) {
  steps.push(installedPackageVerificationStep({
    artifact,
    readSubject: (record, label) => readRecordedFile(record, label).bytes
  }));
  const desktop = runStep('/usr/bin/openburnbar-linux-desktop', ['--version'], {
    env: isolatedRuntimeEnvironment()
  });
  steps.push(desktop);
  steps.push(assertionStep(
    'installed package-native desktop version readback',
    desktop.exitCode === 0 && desktop.stdout.includes(closure.version),
    desktop.stdout,
    desktop.stderr
  ));
  steps.push(installedFileStep('/usr/lib/openburnbar/appdir/AppRun', {
    executable: true,
    allowSymlink: true
  }));
  steps.push(installedFileStep('/usr/share/icons/hicolor/256x256/apps/dev.openburnbar.OpenBurnBar.png'));
  steps.push(runStep('/usr/bin/openburnbar-daemon', ['--help'], {
    env: isolatedRuntimeEnvironment()
  }));
  steps.push(runStep('/usr/libexec/openburnbar-daemon-launch', ['--help'], {
    env: isolatedRuntimeEnvironment()
  }));
  const ownership = runStep('pacman', ['-Qlq', 'openburnbar']);
  steps.push(ownership);
  if (ownership.exitCode === 0) {
    packageOwnedFiles = archPackageRemovalCandidates(ownership.stdout);
  }
}
const uninstall = runStep('pacman', ['-R', '--noconfirm', 'openburnbar']);
steps.push(uninstall);
if (install.exitCode === 0 && uninstall.exitCode === 0) {
  const query = runStep('pacman', ['-Q', 'openburnbar']);
  steps.push(assertionStep(
    'pacman -Q openburnbar expects package absence',
    query.exitCode !== 0,
    query.stdout,
    query.stderr
  ));
  const remaining = remainingFilesystemEntriesNoFollow(packageOwnedFiles);
  steps.push(assertionStep(
    'package-owned filesystem entries removed',
    remaining.length === 0,
    remaining.length === 0 ? `${packageOwnedFiles.length} package-owned files removed\n` : '',
    remaining.length === 0 ? '' : `remaining package-owned files:\n${remaining.join('\n')}\n`
  ));
}
const failed = steps.filter((entry) => entry.exitCode !== 0);
const report = {
  schemaVersion: 1,
  architecture: closure.architecture,
  version: closure.version,
  gitCommit: closure.git?.commit,
  packageSha256: artifact.sha256,
  packageManager: 'pacman',
  installedManifestSha256: artifact.installedManifest?.sha256,
  steps,
  failedCount: failed.length,
  passed: failed.length === 0
};
const reportFile = path.join(outDir, 'smoke/arch-package-smoke.json');
writeJson(reportFile, report);
console.log(JSON.stringify(report, null, 2));
process.exit(report.passed ? 0 : 1);

function isolatedRuntimeEnvironment() {
  const root = path.join(outDir, 'smoke/arch-runtime');
  fs.rmSync(root, { recursive: true, force: true });
  for (const directory of ['config', 'data', 'run']) {
    fs.mkdirSync(path.join(root, directory), { recursive: true });
  }
  return {
    ...process.env,
    HOME: root,
    XDG_CONFIG_HOME: path.join(root, 'config'),
    XDG_DATA_HOME: path.join(root, 'data'),
    XDG_RUNTIME_DIR: path.join(root, 'run')
  };
}

function assertionStep(command, passed, stdout = '', stderr = '') {
  return { command, cwd: '.', exitCode: passed ? 0 : 1, stdout, stderr };
}

function installedFileStep(file, { executable = false, allowSymlink = false } = {}) {
  let passed = false;
  try {
    const link = fs.lstatSync(file);
    const target = fs.statSync(file);
    passed = target.isFile() && (allowSymlink || !link.isSymbolicLink())
      && (!executable || (target.mode & 0o111) !== 0);
  } catch {
    passed = false;
  }
  return assertionStep(
    `installed regular file ${file}`,
    passed,
    passed ? `${file}\n` : '',
    passed ? '' : `${file} is missing, not a file, unexpectedly symlinked, or has the wrong mode\n`
  );
}

function readRecordedFile(record, label) {
  if (record === null || typeof record !== 'object' || Array.isArray(record)
      || typeof (record.file ?? record.path) !== 'string'
      || !/^[a-f0-9]{64}$/u.test(record.sha256 ?? '')
      || !Number.isSafeInteger(record.size) || record.size < 0) {
    throw new Error(`${label} record is invalid`);
  }
  const file = path.resolve(repoRoot, record.file ?? record.path);
  const relative = path.relative(repoRoot, file);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} escapes the repository`);
  }
  let current = repoRoot;
  for (const component of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    if (fs.lstatSync(current).isSymbolicLink()) throw new Error(`${label} traverses a symlink`);
  }
  const bytes = fs.readFileSync(file);
  if (bytes.length !== record.size || crypto.createHash('sha256').update(bytes).digest('hex') !== record.sha256) {
    throw new Error(`${label} does not match its architecture closure record`);
  }
  return { file, bytes };
}
