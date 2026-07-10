#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { manifestPath, readJson, repoRoot, writeJson } from './lib/linux-release-common.mjs';

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
if (fs.existsSync(path.join(repoRoot, 'website/public/downloads/latest-linux.json'))) {
  failures.push('website/public/downloads/latest-linux.json must not be checked in before release verification is green');
}
const contractTest = spawnSync(process.execPath, ['--test', 'scripts/linux-port/resolve-linux-release-ref.test.mjs'], {
  cwd: repoRoot,
  encoding: 'utf8'
});
if (contractTest.status !== 0) {
  failures.push(`Linux release binding contract failed:\n${contractTest.stdout}${contractTest.stderr}`.trim());
}
const report = { generatedAt: new Date().toISOString(), passed: failures.length === 0, failures };
writeJson(path.join(repoRoot, 'docs/linux-port/evidence/mission-001-release/release-config-validation.json'), report);
console.log(JSON.stringify(report, null, 2));
process.exit(failures.length === 0 ? 0 : 1);
