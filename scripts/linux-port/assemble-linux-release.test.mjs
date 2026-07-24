import assert from 'node:assert/strict';
import test from 'node:test';
import { validateArchitectureShardSet } from './lib/linux-release-shards.mjs';
import { isArchitectureSessionBaselineBlocked } from './lib/linux-package-session.mjs';

const manifest = {
  requiredArtifacts: ['appimage', 'arch', 'deb', 'rpm', 'daemon'],
  supportedArchitectures: ['aarch64', 'x86_64']
};
const version = '1.2.3';
const commit = '0123456789abcdef0123456789abcdef01234567';

function session(architecture, lifecycleStatus = 'blocked') {
  const reason = 'No previous same-architecture Linux .deb was supplied; update, rollback, and data-preservation promotion gates remain blocked.';
  return {
    architecture,
    lifecycle: {
      guiLaunch: { status: 'passed' },
      daemonLaunch: { status: 'passed' },
      versionReadback: { status: 'passed' },
      update: { status: lifecycleStatus, ...(lifecycleStatus === 'blocked' ? { reason } : {}) },
      rollback: { status: lifecycleStatus, ...(lifecycleStatus === 'blocked' ? { reason } : {}) },
      dataPreservation: { status: lifecycleStatus, ...(lifecycleStatus === 'blocked' ? { reason } : {}) }
    }
  };
}

test('only an explicit missing-baseline lifecycle block is eligible for prerelease assembly', () => {
  const sessions = [session('aarch64'), session('x86_64')];
  assert.equal(isArchitectureSessionBaselineBlocked({ manifest, sessions }), true);
  sessions[1].lifecycle.update.reason = 'The previous package failed its runtime probe.';
  assert.equal(isArchitectureSessionBaselineBlocked({ manifest, sessions }), false);
  sessions[1].lifecycle.update.reason = 'No previous same-architecture Linux .deb was supplied; update, rollback, and data-preservation promotion gates remain blocked.';
  sessions[1].lifecycle.guiLaunch.status = 'blocked';
  assert.equal(isArchitectureSessionBaselineBlocked({ manifest, sessions }), false);
});

function shard(architecture) {
  return {
    schemaVersion: 1,
    version,
    architecture,
    git: { commit, dirty: false },
    blockers: [],
    artifacts: manifest.requiredArtifacts.map((type) => ({ type, architecture }))
  };
}

test('complete native architecture shard matrix passes', () => {
  assert.deepEqual(validateArchitectureShardSet({
    manifest,
    shards: [shard('aarch64'), shard('x86_64')],
    version,
    commit
  }), []);
});

test('missing architecture and artifact fail closed', () => {
  const aarch64 = shard('aarch64');
  aarch64.artifacts.pop();
  const failures = validateArchitectureShardSet({ manifest, shards: [aarch64], version, commit });
  assert.ok(failures.some((failure) => /missing architecture shard: x86_64/.test(failure)));
  assert.ok(failures.some((failure) => /missing required shard artifact: daemon:aarch64/.test(failure)));
});

test('duplicate, cross-commit, dirty, and unexpected shards fail closed', () => {
  const first = shard('aarch64');
  const duplicate = shard('aarch64');
  duplicate.git.commit = 'f'.repeat(40);
  duplicate.git.dirty = true;
  duplicate.artifacts.push({ type: 'tarball', architecture: 'x86_64' });
  const failures = validateArchitectureShardSet({
    manifest,
    shards: [first, duplicate, shard('x86_64')],
    version,
    commit
  });
  for (const pattern of [
    /duplicate architecture shard/,
    /commit does not match/,
    /dirty checkout/,
    /cross-architecture/,
    /unexpected shard artifact/
  ]) assert.ok(failures.some((failure) => pattern.test(failure)), pattern);
});
