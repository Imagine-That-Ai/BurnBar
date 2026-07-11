import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const script = path.join(repoRoot, 'scripts/linux-port/run-linux-matrix-harness.mjs');

test('rejects unknown support environment identifiers', () => {
  const result = spawnSync(process.execPath, [script, '--environment', 'not-a-supported-row'], {
    cwd: repoRoot,
    encoding: 'utf8'
  });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /Unknown Linux support environment/);
});

test('writes the requested row but fails closed without installed evidence', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-matrix-'));
  const output = path.join(root, 'row.json');
  try {
    const result = spawnSync(
      process.execPath,
      [script, '--environment', 'ubuntu-24.04-gnome-x11-x86_64'],
      {
        cwd: repoRoot,
        encoding: 'utf8',
        env: {
          ...process.env,
          OPENBURNBAR_LINUX_MATRIX_OUT: output
        }
      }
    );
    assert.equal(result.status, 1);
    const report = JSON.parse(fs.readFileSync(output, 'utf8'));
    assert.equal(report.environmentId, 'ubuntu-24.04-gnome-x11-x86_64');
    assert.equal(report.status, 'blocked');
    assert.ok(report.blocked.some((item) => item.capability === 'installed-package-evidence'));
    assert.ok(report.blocked.some((item) => item.capability === 'installed-accessibility-evidence'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
