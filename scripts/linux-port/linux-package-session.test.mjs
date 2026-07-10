import assert from 'node:assert/strict';
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
