import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import {
  aggregateArchitectureLifecycle,
  requiredLifecycleSteps,
  validateArchitectureSessionSet
} from './lib/linux-package-session.mjs';

const manifest = { supportedArchitectures: ['aarch64', 'x86_64'] };
const version = '1.2.3';
const commit = 'a'.repeat(40);
function session(architecture, status = 'passed') {
  return {
    schemaVersion: 1,
    architecture,
    version,
    gitCommit: commit,
    lifecycle: Object.fromEntries(requiredLifecycleSteps.map((step) => [step, { status }])),
    passed: status === 'passed'
  };
}

test('two green architecture sessions produce a green lifecycle', () => {
  const sessions = [session('aarch64'), session('x86_64')];
  assert.deepEqual(validateArchitectureSessionSet({ manifest, sessions, version, commit }), []);
  const aggregate = aggregateArchitectureLifecycle({ manifest, sessions });
  assert.equal(aggregate.passed, true);
  assert.equal(aggregate.failedCount, 0);
});

test('missing and blocked architecture sessions fail closed', () => {
  const blocked = session('aarch64');
  blocked.lifecycle.rollback = { status: 'blocked', reason: 'previous package missing' };
  blocked.passed = false;
  const sessions = [blocked];
  const failures = validateArchitectureSessionSet({ manifest, sessions, version, commit });
  assert.ok(failures.some((failure) => /rollback/.test(failure)));
  assert.ok(failures.some((failure) => /missing architecture session: x86_64/.test(failure)));
  const aggregate = aggregateArchitectureLifecycle({ manifest, sessions });
  assert.equal(aggregate.passed, false);
  assert.equal(aggregate.lifecycle.rollback.status, 'blocked');
});

test('cross-commit, duplicate, and version drift are rejected', () => {
  const first = session('aarch64');
  const duplicate = session('aarch64');
  duplicate.version = '9.9.9';
  duplicate.gitCommit = 'b'.repeat(40);
  const failures = validateArchitectureSessionSet({
    manifest,
    sessions: [first, duplicate, session('x86_64')],
    version,
    commit
  });
  for (const pattern of [/duplicate/, /version does not match/, /commit does not match/, /missing or extra/]) {
    assert.ok(failures.some((failure) => pattern.test(failure)), pattern);
  }
});

test('architecture finalizer consumes the architecture smoke report', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'openburnbar-linux-session-'));
  const sessionDir = path.join(root, 'session');
  const smokeDir = path.join(root, 'smoke');
  mkdirSync(sessionDir, { recursive: true });
  mkdirSync(smokeDir, { recursive: true });
  const json = (file, value) => writeFileSync(file, `${JSON.stringify(value)}\n`);

  try {
    json(path.join(root, 'architecture-closure.json'), {
      schemaVersion: 1,
      architecture: 'aarch64',
      version,
      git: { commit }
    });
    json(path.join(smokeDir, 'architecture-smoke.json'), { passed: true });
    json(path.join(sessionDir, 'linux-desktop-session-report.json'), {
      profile: 'test',
      package: {
        uninstallVerified: true,
        executable: '/usr/bin/openburnbar-linux-desktop',
        shellVersionReadback: `OpenBurnBar ${version}`
      },
      accessibility: { keyboardFocus: { pass: true }, zoom: { pass: true } }
    });
    json(path.join(sessionDir, 'daemon-session-oracle.json'), {
      status: 'ready',
      daemonBinary: '/usr/bin/openburnbar-daemon',
      mode: 'openburnbar-daemon-af-unix'
    });
    json(path.join(sessionDir, 'daemon-health-readback.json'), {
      passed: true,
      response: { result: { daemonVersion: version } }
    });
    json(path.join(sessionDir, 'package-update-rollback.json'), {
      lifecycle: Object.fromEntries(
        ['update', 'rollback', 'dataPreservation'].map((step) => [step, { status: 'passed' }])
      )
    });

    const result = spawnSync(
      process.execPath,
      [path.resolve('scripts/linux-port/finalize-linux-architecture-session.mjs')],
      { encoding: 'utf8', env: { ...process.env, OPENBURNBAR_LINUX_RELEASE_OUT: root } }
    );
    assert.equal(result.status, 0, result.stderr);
    const report = JSON.parse(readFileSync(path.join(root, 'architecture-session.json'), 'utf8'));
    assert.equal(report.packageSmokePassed, true);
    assert.equal(report.passed, true);
    assert.deepEqual(report.blockers, []);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
