#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {
  manifestPath,
  readJson,
  reanchorEvidenceDir,
  repoRoot,
  writeJson
} from './lib/linux-release-common.mjs';

const manifest = readJson(manifestPath);
const failures = [];
for (const key of ['product', 'appId', 'primaryArtifact', 'requiredArtifacts', 'tailMetadata', 'updateMetadata']) {
  if (!manifest[key]) failures.push(`manifest missing ${key}`);
}
for (const artifact of ['appimage', 'deb', 'rpm']) {
  if (!manifest.requiredArtifacts?.includes(artifact)) failures.push(`manifest does not require ${artifact}`);
}
for (const [kind, relPath] of Object.entries(manifest.tailMetadata ?? {})) {
  if (!fs.existsSync(path.join(repoRoot, relPath))) failures.push(`${kind} metadata missing at ${relPath}`);
}
// Unit ExecStart requires the launch script to ship with packages (203/EXEC).
const launchRel = manifest.tailMetadata?.daemonLaunchScript;
if (!launchRel) {
  failures.push('manifest.tailMetadata.daemonLaunchScript is required');
} else {
  const launchFull = path.join(repoRoot, launchRel);
  if (!fs.existsSync(launchFull)) {
    failures.push(`daemon launch script missing at ${launchRel}`);
  } else {
    const mode = fs.statSync(launchFull).mode & 0o111;
    if (!mode) failures.push(`${launchRel} must be executable`);
    const unit = fs.readFileSync(path.join(repoRoot, manifest.tailMetadata.systemdUserService), 'utf8');
    if (!unit.includes('/usr/libexec/openburnbar-daemon-launch')) {
      failures.push('systemd unit must ExecStart=/usr/libexec/openburnbar-daemon-launch');
    }
  }
}
if (!manifest.installPaths?.daemonLaunch) {
  failures.push('manifest.installPaths.daemonLaunch is required');
}
if (fs.existsSync(path.join(repoRoot, 'website/public/downloads/latest-linux.json'))) {
  failures.push('website/public/downloads/latest-linux.json must not be checked in before release verification is green');
}
const report = { generatedAt: new Date().toISOString(), passed: failures.length === 0, failures };
// Never rewrite sealed mission-001-release evidence (same rule as parity-ledger validator).
fs.mkdirSync(reanchorEvidenceDir, { recursive: true });
writeJson(path.join(reanchorEvidenceDir, 'release-config-validation.json'), report);
console.log(JSON.stringify(report, null, 2));
process.exit(failures.length === 0 ? 0 : 1);
