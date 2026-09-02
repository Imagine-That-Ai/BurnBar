#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const evidenceOutput = process.env.OB_EVIDENCE_OUT ?? process.env.OPENBURNBAR_LINUX_EVIDENCE_OUT;
const outDir = evidenceOutput
  ? path.resolve(evidenceOutput)
  : path.join(root, 'docs/linux-port/evidence/mission-001-shell-ux');
fs.mkdirSync(outDir, { recursive: true });
// A fresh arm64 session compiles the Swift daemon/CLI before starting the
// packaged desktop. Keep enough headroom for that native build plus the full
// AT-SPI route/tray/accessibility matrix; the workflow job itself remains
// bounded by its 75-minute timeout.
const requestedTimeoutMs = Number.parseInt(process.env.OB_SHELL_DESKTOP_TIMEOUT_MS || '3600000', 10);
const desktopSessionTimeoutMs = Number.isSafeInteger(requestedTimeoutMs) && requestedTimeoutMs > 0
  ? requestedTimeoutMs
  : 3_600_000;

function normalizeTranscript(text) {
  return text
    .replace(/\r/g, '')
    .split('\n')
    .map((line) => line.replace(/[ \t]+$/u, ''))
    .join('\n');
}

function normalizeTranscriptFile(filePath) {
  let current;
  try {
    current = fs.readFileSync(filePath, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') {
      return;
    }
    throw error;
  }
  try {
    fs.writeFileSync(filePath, normalizeTranscript(current));
  } catch (error) {
    // The desktop session runs as root inside the toolchain container, so a
    // bind-mounted transcript can be readable but not writable by the host
    // runner. The raw transcript is still valid evidence; normalization is
    // best-effort and must not turn a passed desktop session into a false
    // shell-smoke failure.
    if (error.code === 'EACCES' || error.code === 'EPERM') {
      process.stderr.write(`unable to normalize ${filePath}: ${error.code}; retaining raw transcript\n`);
      return;
    }
    throw error;
  }
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
const exitCode = timedOut ? 124 : result.status ?? 1;
const dockerInvocationFailed = [125, 126, 127].includes(result.status);
const processInvocationFailed = result.status === null && Boolean(result.error || result.signal);
const failure = exitCode === 0
  ? { failureClass: null, reasonCode: null }
  : timedOut
    ? { failureClass: 'infra', reasonCode: 'desktop-session-timeout' }
    : result.error?.code === 'ENOENT' || dockerInvocationFailed
      ? { failureClass: 'infra', reasonCode: 'docker-unavailable' }
      : processInvocationFailed
        ? { failureClass: 'infra', reasonCode: 'desktop-session-failed' }
        : { failureClass: 'product', reasonCode: 'desktop-session-failed' };
const { failureClass, reasonCode } = failure;

const transcript = [
  `docker ${dockerArgs.join(' ')}`,
  `exit_code=${exitCode}`,
  `timed_out=${timedOut ? 'true' : 'false'}`,
  `timeout_ms=${desktopSessionTimeoutMs}`,
  `status=${exitCode === 0 ? 'passed' : failureClass === 'infra' ? 'infra-failed' : 'failed'}`,
  `failure_class=${failureClass ?? 'none'}`,
  `reason_code=${reasonCode ?? 'none'}`,
  result.stdout ?? '',
  `${result.stderr ?? ''}${timedOut ? `\ncommand timed out after ${desktopSessionTimeoutMs}ms\n` : ''}`
].join('\n');

fs.writeFileSync(
  path.join(outDir, 'linux-desktop-session-wrapper-transcript.txt'),
  normalizeTranscript(transcript) + '\n'
);
fs.writeFileSync(
  path.join(outDir, 'linux-desktop-session-wrapper-result.json'),
  JSON.stringify({
    schemaVersion: 1,
    status: exitCode === 0 ? 'passed' : failureClass === 'infra' ? 'infra-failed' : 'failed',
    failureClass,
    reasonCode,
    exitCode,
    timedOut,
    timeoutMs: desktopSessionTimeoutMs
  }, null, 2) + '\n'
);
normalizeTranscriptFile(path.join(outDir, 'linux-deb-install-run-transcript.txt'));
normalizeTranscriptFile(path.join(outDir, 'linux-tauri-build-transcript.txt'));
process.stdout.write(result.stdout ?? '');
process.stderr.write(result.stderr ?? '');
if (timedOut) {
  process.stderr.write(`command timed out after ${desktopSessionTimeoutMs}ms\n`);
}
process.exit(exitCode);
