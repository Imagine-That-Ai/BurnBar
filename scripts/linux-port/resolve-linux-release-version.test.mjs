import assert from 'node:assert/strict';
import test from 'node:test';
import { resolveLinuxReleaseVersion } from './resolve-linux-release-version.mjs';

const versions = { packageVersion: '1.2.3', tauriVersion: '1.2.3' };

test('linux tag resolves strict semver and permits publishing', () => {
  assert.deepEqual(resolveLinuxReleaseVersion({ eventName: 'push', ref: 'refs/tags/linux-v1.2.3', ...versions }), {
    passed: true,
    version: '1.2.3',
    tag: 'linux-v1.2.3',
    publishAllowed: true,
    failures: []
  });
});

test('manual version resolves but a branch dispatch cannot publish', () => {
  const result = resolveLinuxReleaseVersion({
    eventName: 'workflow_dispatch',
    ref: 'refs/heads/main',
    inputVersion: '1.2.3',
    ...versions
  });
  assert.equal(result.passed, true);
  assert.equal(result.publishAllowed, false);
});

test('manual dispatch defaults to the checked-in package version', () => {
  const result = resolveLinuxReleaseVersion({
    eventName: 'workflow_dispatch',
    ref: 'refs/heads/main',
    ...versions
  });
  assert.equal(result.passed, true);
  assert.equal(result.version, '1.2.3');
  assert.equal(result.tag, 'linux-v1.2.3');
  assert.equal(result.publishAllowed, false);
});

test('tagged manual dispatch can use the package default and publish', () => {
  const result = resolveLinuxReleaseVersion({
    eventName: 'workflow_dispatch',
    ref: 'refs/tags/linux-v1.2.3',
    ...versions
  });
  assert.equal(result.passed, true);
  assert.equal(result.version, '1.2.3');
  assert.equal(result.publishAllowed, true);
});

test('manual dispatch without input or package version fails closed', () => {
  const result = resolveLinuxReleaseVersion({
    eventName: 'workflow_dispatch',
    ref: 'refs/heads/main',
    tauriVersion: '1.2.3'
  });
  assert.equal(result.passed, false);
  assert.equal(result.version, null);
  assert.ok(result.failures.some((failure) => /package\.json version is unavailable/u.test(failure)));
});

test('legacy v tag is rejected', () => {
  const result = resolveLinuxReleaseVersion({ eventName: 'push', ref: 'refs/tags/v1.2.3', ...versions });
  assert.equal(result.passed, false);
});

test('empty tag-triggered input cannot produce a version', () => {
  const result = resolveLinuxReleaseVersion({ eventName: 'push', ref: 'refs/heads/main', ...versions });
  assert.equal(result.passed, false);
  assert.equal(result.version, null);
});

test('manual tag and input disagreement fails', () => {
  const result = resolveLinuxReleaseVersion({
    eventName: 'workflow_dispatch',
    ref: 'refs/tags/linux-v1.2.3',
    inputVersion: '1.2.4',
    packageVersion: '1.2.4',
    tauriVersion: '1.2.4'
  });
  assert.equal(result.passed, false);
  assert.ok(result.failures.some((failure) => /does not match/.test(failure)));
});

test('package or Tauri version drift fails', () => {
  const result = resolveLinuxReleaseVersion({
    eventName: 'push',
    ref: 'refs/tags/linux-v1.2.3',
    packageVersion: '1.2.2',
    tauriVersion: '1.2.4'
  });
  assert.equal(result.passed, false);
  assert.equal(result.failures.length, 2);
});

test('prerelease and malformed versions are rejected', () => {
  for (const version of ['1.2', 'v1.2.3', '1.2.3-beta.1', '01.2.3']) {
    const result = resolveLinuxReleaseVersion({
      eventName: 'workflow_dispatch',
      ref: 'refs/heads/main',
      inputVersion: version,
      packageVersion: version,
      tauriVersion: version
    });
    assert.equal(result.passed, false, version);
  }
});
