#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const appDir = path.join(root, 'apps/linux-desktop');
const outDir = path.join(root, 'docs/linux-port/evidence/mission-001-shell-ux');
fs.mkdirSync(outDir, { recursive: true });

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
  .map((s, i) => `### step ${i + 1}\n${s.cmd}\nexit_code=${s.code}\n${s.stdout}\n${s.stderr}`)
  .join('\n\n');

fs.writeFileSync(path.join(outDir, 'smoke-transcript.txt'), transcript + '\n');
const failed = steps.find((s) => s.code !== 0);
process.exit(failed ? failed.code : 0);
