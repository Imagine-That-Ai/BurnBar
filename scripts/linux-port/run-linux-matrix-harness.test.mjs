import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { createEnvironmentCoverageReport } from './lib/environment-coverage-report.mjs';
import {
  validateEnvironmentEvidenceIdentity,
  validateEnvironmentEvidenceInput
} from './lib/environment-evidence-identity.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const script = path.join(repoRoot, 'scripts/linux-port/run-linux-matrix-harness.mjs');

const GNOME_X11_X86 = {
  id: 'ubuntu-24.04-gnome-x11-x86_64',
  os: 'Ubuntu 24.04',
  desktop: 'GNOME',
  session: 'X11',
  architecture: 'x86_64'
};

function evidence(identity = {}) {
  return { identity };
}

test('accepts an exact GNOME X11 x86_64 evidence identity', () => {
  const result = validateEnvironmentEvidenceIdentity(GNOME_X11_X86, evidence({
    environmentId: GNOME_X11_X86.id,
    architecture: 'x64',
    session: 'X11',
    desktop: 'GNOME:GNOME'
  }));

  assert.deepEqual(result, { passed: true, errors: [] });
});

test('rejects an architecture substitution even when the environment id matches', () => {
  const result = validateEnvironmentEvidenceIdentity(GNOME_X11_X86, evidence({
    environmentId: GNOME_X11_X86.id,
    architecture: 'arm64',
    session: 'X11',
    desktop: 'GNOME'
  }));

  assert.equal(result.passed, false);
  assert.ok(result.errors.some((error) => /architecture=aarch64 expected=x86_64/u.test(error)));
});

test('rejects desktop or session substitutions and malformed identity fields', () => {
  const substituted = validateEnvironmentEvidenceIdentity(GNOME_X11_X86, evidence({
    environmentId: GNOME_X11_X86.id,
    architecture: 'x86_64',
    session: 'Wayland',
    desktop: 'KDE Plasma'
  }));
  assert.equal(substituted.passed, false);
  assert.ok(substituted.errors.some((error) => /session=wayland expected=x11/u.test(error)));
  assert.ok(substituted.errors.some((error) => /desktop=KDE Plasma expected=GNOME/u.test(error)));

  const malformed = validateEnvironmentEvidenceIdentity(GNOME_X11_X86, evidence({
    environmentId: GNOME_X11_X86.id,
    architecture: 'x86_64',
    session: 'X11',
    desktop: 'GNOME',
    kernel: '6.8'
  }));
  assert.deepEqual(malformed, {
    passed: false,
    errors: ['identity fields must be exactly: architecture, desktop, environmentId, session']
  });
});

test('input validation binds passed status and commit to the row identity', () => {
  const expectedHead = 'a'.repeat(40);
  const result = validateEnvironmentEvidenceInput(GNOME_X11_X86, {
    passed: true,
    commit: expectedHead,
    identity: {
      environmentId: GNOME_X11_X86.id,
      architecture: 'x86_64',
      session: 'X11',
      desktop: 'GNOME'
    }
  }, expectedHead);
  assert.deepEqual(result, { passed: true, commit: expectedHead, errors: [] });

  const stale = validateEnvironmentEvidenceInput(GNOME_X11_X86, {
    passed: true,
    commit: 'b'.repeat(40),
    identity: {
      environmentId: GNOME_X11_X86.id,
      architecture: 'arm64',
      session: 'Wayland',
      desktop: 'KDE Plasma'
    }
  }, expectedHead);
  assert.equal(stale.passed, false);
  assert.ok(stale.errors.some((error) => /commit=/u.test(error)));
  assert.ok(stale.errors.some((error) => /architecture=aarch64/u.test(error)));
  assert.ok(stale.errors.some((error) => /session=wayland/u.test(error)));
});

test('passed environment coverage uses the ledger admission schema and exact artifact hashes', () => {
  const head = 'a'.repeat(40);
  const installed = { path: 'evidence/installed.json', sha256: '1'.repeat(64), passed: true, commit: head };
  const accessibility = { path: 'evidence/accessibility.json', sha256: '2'.repeat(64), passed: true, commit: head };
  const report = createEnvironmentCoverageReport({
    generatedAt: '2026-07-12T00:00:00.000Z',
    environmentId: 'test-linux',
    git: { commit: head, dirty: false },
    declared: { id: 'test-linux' },
    detected: { platform: 'linux' },
    checks: [{ id: 'installed', passed: true, detail: 'ok' }],
    installedEvidence: installed,
    accessibilityEvidence: accessibility
  });

  assert.equal(report.targetHead, head);
  assert.equal(report.status, 'passed');
  assert.deepEqual(report.artifacts, [
    { path: accessibility.path, sha256: accessibility.sha256 },
    { path: installed.path, sha256: installed.sha256 }
  ]);
  assert.deepEqual(report.blocked, []);
});

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
    assert.match(report.targetHead, /^[a-f0-9]{40,64}$/u);
    assert.equal(report.status, 'blocked');
    assert.deepEqual(report.artifacts, []);
    assert.ok(report.blocked.some((item) => item.capability === 'installed-package-evidence'));
    assert.ok(report.blocked.some((item) => item.capability === 'installed-accessibility-evidence'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
