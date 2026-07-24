import assert from 'node:assert/strict';
import test from 'node:test';
import {
  assertDebianLifecyclePayload,
  compareSemver,
  expectedAssets,
  inspectReleaseAssets,
  releaseCandidates
} from './resolve-linux-previous-release.mjs';

test('semver ordering is numeric and not lexical', () => {
  assert.equal(compareSemver('0.10.0', '0.9.0'), 1);
  assert.equal(compareSemver('1.2.3', '1.2.3'), 0);
  assert.equal(compareSemver('1.2.2', '1.2.3'), -1);
});

test('release candidates exclude current, newer, and draft versions, then sort newest older release first', () => {
  const result = releaseCandidates({
    currentVersion: '2.0.0',
    releases: [
      { tagName: 'linux-v0.9.0', isDraft: false },
      { tagName: 'linux-v1.10.0', isDraft: false },
      { tagName: 'linux-v2.0.0', isDraft: false },
      { tagName: 'linux-v3.0.0', isDraft: false },
      { tagName: 'linux-v9.0.0', isDraft: true },
      { tagName: 'v1.0.0', isDraft: false }
    ]
  });
  assert.deepEqual(result.failures, []);
  assert.deepEqual(result.candidates.map((entry) => entry.version), ['1.10.0', '0.9.0']);
});

test('explicit baseline selection does not silently fall back to another release', () => {
  const result = releaseCandidates({
    currentVersion: '2.0.0',
    requestedVersion: '1.2.3',
    releases: [{ tagName: 'linux-v1.1.0', isDraft: false }, { tagName: 'linux-v0.9.0', isDraft: false }]
  });
  assert.deepEqual(result.candidates, []);
  assert.match(result.failures.join('\n'), /linux-v1\.2\.3/u);
});

test('partial or legacy release assets are rejected before package download', () => {
  const result = inspectReleaseAssets({
    version: '0.1.0',
    assets: [
      'OpenBurnBar_0.1.0_arm64.deb',
      'OpenBurnBar-0.1.0-1.aarch64.rpm',
      'openburnbar-daemon-0.1.0-linux-aarch64'
    ]
  });
  assert.equal(result.passed, false);
  assert.ok(result.failures.some((failure) => /x86_64.*amd64\.deb/u.test(failure)));
  assert.ok(result.failures.some((failure) => /canonical Arch package/u.test(failure)));
});

test('complete release asset matrix is accepted for both architectures', () => {
  const assets = [];
  for (const architecture of ['aarch64', 'x86_64']) {
    const expected = expectedAssets('1.2.3', architecture);
    assets.push(
      expected.deb,
      `openburnbar-1.2.3-1-${architecture}.pkg.tar.zst`,
      `openburnbar-1.2.3-1-${architecture}.pkg.tar.zst.ed25519.sig`,
      expected.installedManifest,
      expected.installedManifestSignature,
      expected.productProof,
      expected.productProofSignature
    );
  }
  assert.equal(inspectReleaseAssets({ version: '1.2.3', assets }).passed, true);
});

test('Debian payload inspection requires exact identity and the daemon launcher', () => {
  const calls = [];
  const run = (command, args) => {
    calls.push([command, args]);
    if (args[0] === '-f' && args[2] === 'Package') return { exitCode: 0, stdout: 'open-burn-bar\n', stderr: '' };
    if (args[0] === '-f' && args[2] === 'Version') return { exitCode: 0, stdout: '1.2.3\n', stderr: '' };
    if (args[0] === '-f' && args[2] === 'Architecture') return { exitCode: 0, stdout: 'amd64\n', stderr: '' };
    return {
      exitCode: 0,
      stdout: '-rwxr-xr-x root/root 123 2026-01-01 00:00 ./usr/libexec/openburnbar-daemon-launch\n',
      stderr: ''
    };
  };
  assert.deepEqual(assertDebianLifecyclePayload({ packagePath: '/tmp/candidate.deb', version: '1.2.3', architecture: 'x86_64', run }), { passed: true });
  assert.equal(calls.length, 4);

  const missingLauncher = (command, args) => args[0] === '-f' && args[2] === 'Package'
    ? { exitCode: 0, stdout: 'open-burn-bar\n', stderr: '' }
    : args[0] === '-f' && args[2] === 'Version'
      ? { exitCode: 0, stdout: '1.2.3\n', stderr: '' }
      : args[0] === '-f' && args[2] === 'Architecture'
        ? { exitCode: 0, stdout: 'amd64\n', stderr: '' }
        : { exitCode: 0, stdout: './usr/bin/openburnbar-linux-desktop\n', stderr: '' };
  const rejected = assertDebianLifecyclePayload({ packagePath: '/tmp/candidate.deb', version: '1.2.3', architecture: 'x86_64', run: missingLauncher });
  assert.equal(rejected.passed, false);
  assert.match(rejected.reason, /missing .*daemon-launch/u);
});
