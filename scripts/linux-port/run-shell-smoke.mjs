#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { MISSION_ROOT, SHELL_EVIDENCE_DIR, writeRunManifest } from './shell-evidence-manifest.mjs';

const root = MISSION_ROOT;
const appDir = path.join(root, 'apps/linux-desktop');
const outDir = SHELL_EVIDENCE_DIR;
const verifyScript = path.join(root, 'scripts/linux-port/verify-shell-evidence.mjs');
fs.mkdirSync(outDir, { recursive: true });

writeRunManifest({ step: 'run-shell-smoke', startedAt: new Date().toISOString() });
fs.writeFileSync(path.join(outDir, 'smoke-transcript.txt'), `mission_worktree=${root}\n`);

function run(cmd, args, cwd, env = process.env) {
  const r = spawnSync(cmd, args, { cwd, encoding: 'utf8', env });
  return { cmd: [cmd, ...args].join(' '), code: r.status ?? 1, stdout: r.stdout, stderr: r.stderr };
}

const steps = [];
steps.push(run('npm', ['install', '--no-audit', '--no-fund'], appDir));
steps.push(run('npm', ['test'], appDir));
steps.push(run('npm', ['run', 'build'], appDir));
steps.push(run('node', [path.join(root, 'scripts/linux-port/run-shell-evidence.mjs')], root));
steps.push(run('node', [path.join(root, 'scripts/linux-port/run-shell-desktop-session.mjs')], root));
steps.push(run('node', [path.join(root, 'scripts/linux-port/run-perf-budget.mjs')], root));

const transcript = steps
  .map((s, i) => `### step ${i + 1}\nmission_worktree=${root}\n${s.cmd}\nexit_code=${s.code}\n${s.stdout}\n${s.stderr}`)
  .join('\n\n');

fs.appendFileSync(path.join(outDir, 'smoke-transcript.txt'), transcript + '\n');
const failed = steps.find((s) => s.code !== 0);

const verify = spawnSync(process.execPath, [verifyScript, 'full'], { cwd: root, encoding: 'utf8' });
if (verify.stdout) process.stdout.write(verify.stdout);
if (verify.stderr) process.stderr.write(verify.stderr);

if (failed) process.exit(failed.code);
process.exit(verify.status ?? 1);