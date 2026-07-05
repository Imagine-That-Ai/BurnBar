#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const outDir = process.env.OB_EVIDENCE_OUT
  ? path.resolve(process.env.OB_EVIDENCE_OUT)
  : path.join(root, 'docs/linux-port/evidence/mission-001-shell-ux');
fs.mkdirSync(outDir, { recursive: true });
const desktopSessionTimeoutMs = Number.parseInt(process.env.OB_SHELL_DESKTOP_TIMEOUT_MS || '1500000', 10);

function normalizeTranscript(text) {
  return text
    .replace(/\r/g, '')
    .split('\n')
    .map((line) => line.replace(/[ \t]+$/u, ''))
    .join('\n');
}

function normalizeTranscriptFile(filePath) {
  if (!fs.existsSync(filePath)) {
    return;
  }
  const current = fs.readFileSync(filePath, 'utf8');
  fs.writeFileSync(filePath, normalizeTranscript(current));
}

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
  env: { ...process.env, OB_EVIDENCE_OUT: '/evidence' },
  timeout: desktopSessionTimeoutMs
});
const timedOut = result.error?.code === 'ETIMEDOUT';

const transcript = [
  `docker ${dockerArgs.join(' ')}`,
  `exit_code=${timedOut ? 124 : result.status ?? 1}`,
  `timed_out=${timedOut ? 'true' : 'false'}`,
  `timeout_ms=${desktopSessionTimeoutMs}`,
  result.stdout ?? '',
  `${result.stderr ?? ''}${timedOut ? `\ncommand timed out after ${desktopSessionTimeoutMs}ms\n` : ''}`
].join('\n');

fs.writeFileSync(
  path.join(outDir, 'linux-desktop-session-wrapper-transcript.txt'),
  normalizeTranscript(transcript) + '\n'
);
normalizeTranscriptFile(path.join(outDir, 'linux-deb-install-run-transcript.txt'));
normalizeTranscriptFile(path.join(outDir, 'linux-tauri-build-transcript.txt'));
process.stdout.write(result.stdout ?? '');
process.stderr.write(result.stderr ?? '');
if (timedOut) {
  process.stderr.write(`command timed out after ${desktopSessionTimeoutMs}ms\n`);
}
process.exit(timedOut ? 124 : result.status ?? 1);
