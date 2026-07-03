#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const outDir = path.join(root, 'docs/linux-port/evidence/mission-001-shell-ux');
fs.mkdirSync(outDir, { recursive: true });

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

const result = spawnSync('docker', dockerArgs, {
  cwd: root,
  encoding: 'utf8',
  env: { ...process.env, OB_EVIDENCE_OUT: '/evidence' }
});

const transcript = [
  `docker ${dockerArgs.join(' ')}`,
  `exit_code=${result.status ?? 1}`,
  result.stdout,
  result.stderr
].join('\n');

fs.writeFileSync(path.join(outDir, 'linux-desktop-session-wrapper-transcript.txt'), transcript + '\n');
process.stdout.write(result.stdout);
process.stderr.write(result.stderr);
process.exit(result.status ?? 1);
