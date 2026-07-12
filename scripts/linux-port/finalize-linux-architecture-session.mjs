#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { readJson, relative, repoRoot, writeJson } from './lib/linux-release-common.mjs';
import { requiredLifecycleSteps } from './lib/linux-package-session.mjs';

const outDir = path.resolve(process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? path.join(repoRoot, '.linux-shard'));
const sessionDir = path.join(outDir, 'session');
const closure = readJson(path.join(outDir, 'architecture-closure.json'));

function optionalJson(name) {
  const file = path.join(sessionDir, name);
  if (!fs.existsSync(file)) return null;
  try {
    return readJson(file);
  } catch {
    return null;
  }
}

const desktop = optionalJson('linux-desktop-session-report.json');
const daemonOracle = optionalJson('daemon-session-oracle.json');
const daemonHealth = optionalJson('daemon-health-readback.json');
const updateRollback = optionalJson('package-update-rollback.json');
const packageSmoke = optionalJson('../smoke/architecture-smoke.json');
const archPackageSmoke = optionalJson('../smoke/arch-package-smoke.json');
const archArtifacts = (closure.artifacts ?? []).filter((artifact) => artifact.type === 'arch');
const archArtifact = archArtifacts.length === 1 ? archArtifacts[0] : null;
const shellVersion = desktop?.package?.shellVersionReadback ?? '';
const daemonVersion = daemonHealth?.response?.result?.daemonVersion ?? '';
const lifecycle = {
  guiLaunch: desktop?.package?.uninstallVerified === true
    ? { status: 'passed', executable: desktop.package.executable, profile: desktop.profile }
    : { status: 'blocked', reason: 'Installed GUI launch and uninstall session did not complete.' },
  daemonLaunch: daemonOracle?.status === 'ready'
      && daemonOracle?.daemonBinary === '/usr/bin/openburnbar-daemon'
      && daemonHealth?.passed === true
    ? { status: 'passed', executable: daemonOracle.daemonBinary, mode: daemonOracle.mode }
    : { status: 'blocked', reason: 'Package-owned daemon health readback is absent or failed.' },
  versionReadback: shellVersion.includes(closure.version) && daemonVersion.includes(closure.version)
    ? { status: 'passed', shellVersion, daemonVersion }
    : { status: 'blocked', reason: 'Shell and daemon version readback do not match the shard version.' },
  update: updateRollback?.lifecycle?.update ?? { status: 'blocked', reason: 'Update evidence is missing.' },
  rollback: updateRollback?.lifecycle?.rollback ?? { status: 'blocked', reason: 'Rollback evidence is missing.' },
  dataPreservation: updateRollback?.lifecycle?.dataPreservation
    ?? { status: 'blocked', reason: 'Data-preservation evidence is missing.' }
};
const blockers = [];
if (packageSmoke?.passed !== true) blockers.push('Architecture package inspection/install/uninstall smoke is not green.');
if (archPackageSmoke?.passed !== true
    || archArtifact === null
    || archPackageSmoke.architecture !== closure.architecture
    || archPackageSmoke.version !== closure.version
    || archPackageSmoke.gitCommit !== closure.git?.commit
    || archPackageSmoke.packageSha256 !== archArtifact?.sha256
    || archPackageSmoke.installedManifestSha256 !== archArtifact?.installedManifest?.sha256) {
  blockers.push('Arch pacman install/ownership/uninstall smoke is missing, failed, or release-unbound.');
}
if (desktop?.accessibility?.keyboardFocus?.pass !== true) blockers.push('Installed keyboard focus evidence is not green.');
if (desktop?.accessibility?.zoom?.pass !== true) blockers.push('Installed 200% zoom evidence is not green.');
for (const step of requiredLifecycleSteps) {
  if (lifecycle[step].status !== 'passed') blockers.push(`${step}: ${lifecycle[step].reason ?? 'not passed'}`);
}
const report = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  architecture: closure.architecture,
  version: closure.version,
  gitCommit: closure.git?.commit,
  packageSmokePassed: packageSmoke?.passed === true,
  lifecycle,
  evidence: {
    desktopSession: relative(path.join(sessionDir, 'linux-desktop-session-report.json')),
    daemonHealth: relative(path.join(sessionDir, 'daemon-health-readback.json')),
    updateRollback: relative(path.join(sessionDir, 'package-update-rollback.json')),
    archPackageSmoke: relative(path.join(outDir, 'smoke/arch-package-smoke.json'))
  },
  blockers,
  passed: blockers.length === 0
};
writeJson(path.join(outDir, 'architecture-session.json'), report);
console.log(JSON.stringify(report, null, 2));
// A blocked prior-release lifecycle is promotion input, not a shard build error.
process.exit(0);
