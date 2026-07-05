#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { readJson, releaseEvidenceDir, repoRoot, runStep, writeJson } from './lib/linux-release-common.mjs';

const outDir = path.resolve(process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? releaseEvidenceDir);
const closurePath = path.join(outDir, 'package-closure.json');
const smokeDir = path.join(outDir, 'smoke');
fs.mkdirSync(smokeDir, { recursive: true });

if (!fs.existsSync(closurePath)) {
  console.error('package-closure.json missing; run build-linux-release first.');
  process.exit(1);
}

const closure = readJson(closurePath);
const steps = [];
for (const artifact of closure.artifacts ?? []) {
  const full = path.join(repoRoot, artifact.file);
  if (artifact.type === 'deb') {
    steps.push(runStep('dpkg-deb', ['--info', full]));
    steps.push(runStep('dpkg-deb', ['--contents', full]));
    steps.push(runStep('dpkg', ['-i', full]));
    steps.push(runStep('dpkg', ['-r', 'openburnbar']));
  } else if (artifact.type === 'rpm') {
    steps.push(runStep('rpm', ['-qip', full]));
    steps.push(runStep('rpm', ['-qlp', full]));
    steps.push(runStep('rpm', ['-i', '--nodeps', full]));
    steps.push(runStep('rpm', ['-e', 'openburnbar']));
  } else if (artifact.type === 'appimage') {
    fs.chmodSync(full, 0o755);
    steps.push(runStep(full, ['--appimage-extract']));
    steps.push(runStep(full, ['--version']));
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

const failed = steps.find((step) => step.exitCode !== 0);
console.log(JSON.stringify({ steps: steps.length, failed: failed ?? null, update }, null, 2));
process.exit(failed ? failed.exitCode : 0);
