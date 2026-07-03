#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { MISSION_ROOT, SHELL_EVIDENCE_DIR, writeRunManifest } from './shell-evidence-manifest.mjs';

const root = MISSION_ROOT;
const outDir = SHELL_EVIDENCE_DIR;
fs.mkdirSync(outDir, { recursive: true });
const hostMission = root;
writeRunManifest({ step: 'run-shell-desktop-session', startedAt: new Date().toISOString() });

const dockerArgs = [
  'run',
  '--rm',
  '--mount',
  `type=bind,src=${root},dst=/workspace,readonly`,
  '--mount',
  `type=bind,src=${outDir},dst=/evidence`,
  '-w',
  '/workspace',
  'openburnbar-linux-toolchain:mission-001',
  'bash',
  '/workspace/scripts/linux-port/linux-desktop-session.sh'
];

if (process.env.OB_REUSE_EXISTING_DEB === '1') {
  const imageIndex = dockerArgs.indexOf('openburnbar-linux-toolchain:mission-001');
  dockerArgs.splice(imageIndex, 0, '-e', 'OB_REUSE_EXISTING_DEB=1');
}
const imageIndexHost = dockerArgs.indexOf('openburnbar-linux-toolchain:mission-001');
dockerArgs.splice(imageIndexHost, 0, '-e', `OB_MISSION_WORKTREE_HOST=${hostMission}`);
if (process.env.OB_ACCEPT_SHELL_DAEMON_FIXTURE === '1') {
  const imageIndex = dockerArgs.indexOf('openburnbar-linux-toolchain:mission-001');
  dockerArgs.splice(imageIndex, 0, '-e', 'OB_ACCEPT_SHELL_DAEMON_FIXTURE=1');
}

const result = spawnSync('docker', dockerArgs, {
  cwd: root,
  encoding: 'utf8',
  env: { ...process.env, OB_EVIDENCE_OUT: '/evidence' }
});

const transcript = [
  `mission_worktree=${root}`,
  `docker ${dockerArgs.join(' ')}`,
  `exit_code=${result.status ?? 1}`,
  result.stdout,
  result.stderr
].join('\n');

fs.writeFileSync(path.join(outDir, 'linux-desktop-session-wrapper-transcript.txt'), transcript + '\n');
process.stdout.write(result.stdout);
process.stderr.write(result.stderr);

if ((result.status ?? 1) !== 0) {
  process.exit(result.status ?? 1);
}

const verify = spawnSync(process.execPath, [path.join(root, 'scripts/linux-port/verify-shell-evidence.mjs'), 'desktop'], {
  cwd: root,
  encoding: 'utf8'
});
if (verify.stdout) process.stdout.write(verify.stdout);
if (verify.stderr) process.stderr.write(verify.stderr);
process.exit(verify.status ?? 1);