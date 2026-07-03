#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  MISSION_ROOT,
  SHELL_EVIDENCE_DIR,
  REQUIRED_JSON_ARTIFACTS,
  writeRunManifest
} from './shell-evidence-manifest.mjs';

const root = MISSION_ROOT;
const appDir = path.join(root, 'apps/linux-desktop');
const outDir = SHELL_EVIDENCE_DIR;
fs.mkdirSync(outDir, { recursive: true });

writeRunManifest({ step: 'run-shell-evidence', startedAt: new Date().toISOString() });

const env = { ...process.env, OB_EVIDENCE_OUT: outDir };
const r = spawnSync('npm', ['test'], { cwd: appDir, encoding: 'utf8', env });
const transcript = [
  '### shell evidence harness',
  `mission_worktree=${root}`,
  `OB_EVIDENCE_OUT=${outDir}`,
  'npm test',
  `exit_code=${r.status ?? 1}`,
  r.stdout,
  r.stderr
].join('\n');
fs.writeFileSync(path.join(outDir, 'shell-evidence-harness-transcript.txt'), transcript + '\n');

const missing = REQUIRED_JSON_ARTIFACTS.filter((a) => !fs.existsSync(path.join(outDir, a)));
if (missing.length) {
  console.error('Missing evidence artifacts:', missing.join(', '));
  process.exit(1);
}

const verify = spawnSync(process.execPath, [path.join(root, 'scripts/linux-port/verify-shell-evidence.mjs'), 'json'], {
  cwd: root,
  encoding: 'utf8'
});
if (verify.stdout) process.stdout.write(verify.stdout);
if (verify.stderr) process.stderr.write(verify.stderr);
process.exit((r.status ?? 1) !== 0 ? (r.status ?? 1) : (verify.status ?? 1));