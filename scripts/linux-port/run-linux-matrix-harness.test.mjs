import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const script = path.join(repoRoot, 'scripts/linux-port/run-linux-matrix-harness.mjs');
const supportedEnvironment = 'ubuntu-24.04-gnome-x11-x86_64';

function currentCommit() {
  const result = spawnSync('git', ['rev-parse', 'HEAD'], {
    cwd: repoRoot,
    encoding: 'utf8'
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function writeEvidence(root, name, evidence) {
  const file = path.join(root, name);
  fs.writeFileSync(file, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
  return file;
}

function completeNativeEvidence(commit, environmentId = supportedEnvironment) {
  return {
    passed: true,
    git: { commit },
    environmentId,
    nativeShell: {
      trayHost: true,
      trayActions: true,
      compactStatusWindow: true,
      statusWindowAccessibility: true,
      notificationServer: true,
      notificationActions: true,
      notificationRelaunchRoute: true,
      deepLinkRelaunch: true,
      globalPanicShortcut: true,
      loginStart: true,
      trayHostLossRecovery: true
    }
  };
}

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
    assert.ok(report.blocked.some((item) => item.capability === 'native-shell-evidence'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('fails closed when native-shell evidence omits required installed behaviors', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-matrix-'));
  const output = path.join(root, 'row.json');
  try {
    const commit = currentCommit();
    const genericEvidence = writeEvidence(root, 'generic.json', {
      passed: true,
      git: { commit },
      environmentId: supportedEnvironment
    });
    const partialNativeEvidence = writeEvidence(root, 'native-partial.json', {
      passed: true,
      git: { commit },
      environmentId: supportedEnvironment,
      nativeShell: {
        trayHost: true
      }
    });

    const result = spawnSync(
      process.execPath,
      [script, '--environment', supportedEnvironment],
      {
        cwd: repoRoot,
        encoding: 'utf8',
        env: {
          ...process.env,
          OPENBURNBAR_LINUX_MATRIX_OUT: output,
          OPENBURNBAR_LINUX_INSTALLED_EVIDENCE: genericEvidence,
          OPENBURNBAR_LINUX_ACCESSIBILITY_EVIDENCE: genericEvidence,
          OPENBURNBAR_LINUX_NATIVE_SHELL_EVIDENCE: partialNativeEvidence
        }
      }
    );

    assert.equal(result.status, 1);
    const report = JSON.parse(fs.readFileSync(output, 'utf8'));
    const nativeCheck = report.checks.find((item) => item.id === 'native-shell-evidence');
    assert.equal(nativeCheck?.passed, false);
    assert.match(nativeCheck?.detail ?? '', /notification-actions/);
    assert.match(nativeCheck?.detail ?? '', /tray-host-loss-recovery/);
    assert.equal(report.evidenceInputs.nativeShellEvidence.missing.includes('tray-host'), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('accepts commit and environment matched native-shell matrix evidence', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-matrix-'));
  const output = path.join(root, 'row.json');
  try {
    const commit = currentCommit();
    const evidence = writeEvidence(root, 'complete.json', completeNativeEvidence(commit));

    const result = spawnSync(
      process.execPath,
      [script, '--environment', supportedEnvironment],
      {
        cwd: repoRoot,
        encoding: 'utf8',
        env: {
          ...process.env,
          OPENBURNBAR_LINUX_MATRIX_OUT: output,
          OPENBURNBAR_LINUX_INSTALLED_EVIDENCE: evidence,
          OPENBURNBAR_LINUX_ACCESSIBILITY_EVIDENCE: evidence,
          OPENBURNBAR_LINUX_NATIVE_SHELL_EVIDENCE: evidence
        }
      }
    );

    assert.ok([0, 1].includes(result.status), result.stderr);
    const report = JSON.parse(fs.readFileSync(output, 'utf8'));
    const nativeCheck = report.checks.find((item) => item.id === 'native-shell-evidence');
    assert.equal(nativeCheck?.passed, true);
    assert.deepEqual(report.evidenceInputs.nativeShellEvidence.missing, []);
    assert.ok(report.nativeShellEvidenceRequirements.some((requirement) => requirement.id === 'login-start'));
    assert.ok(report.nativeShellEvidenceRequirements.some((requirement) => requirement.id === 'global-panic-shortcut'));
    assert.equal(report.blocked.some((item) => item.capability === 'native-shell-evidence'), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
