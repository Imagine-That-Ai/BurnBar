#!/usr/bin/env node
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { resolveLinuxReleaseBinding } from './resolve-linux-release-ref.mjs';
import { verifyEd25519Signature } from './lib/linux-release-common.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

const valid = {
  eventName: 'push',
  ref: 'refs/tags/linux-v1.2.3-rc.1',
  refName: 'linux-v1.2.3-rc.1',
  headCommit: 'a'.repeat(40),
  tagCommit: 'a'.repeat(40),
  manifestVersion: '1.2.3-rc.1',
  reachableFromMain: true
};

test('resolves one tag-bound release identity for tag pushes', () => {
  assert.deepEqual(resolveLinuxReleaseBinding(valid), {
    version: '1.2.3-rc.1',
    tag: 'linux-v1.2.3-rc.1',
    ref: 'refs/tags/linux-v1.2.3-rc.1',
    commit: 'a'.repeat(40),
    prerelease: true,
    expectedCosignIdentity: 'https://github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-release.yml@refs/tags/linux-v1.2.3-rc.1'
  });
});

test('manual dispatch uses the selected Linux tag without changing identity', () => {
  const result = resolveLinuxReleaseBinding({
    ...valid,
    eventName: 'workflow_dispatch',
    ref: 'refs/tags/linux-v1.2.3',
    refName: 'linux-v1.2.3',
    manifestVersion: '1.2.3'
  });
  assert.equal(result.prerelease, false);
  assert.equal(result.commit, valid.headCommit);
});

test('build metadata containing a hyphen does not make a stable release a prerelease', () => {
  const result = resolveLinuxReleaseBinding({
    ...valid,
    ref: 'refs/tags/linux-v1.2.3+build-alpha',
    refName: 'linux-v1.2.3+build-alpha',
    manifestVersion: '1.2.3+build-alpha'
  });
  assert.equal(result.prerelease, false);
});

for (const [name, override, message] of [
  ['Apple release tag', { ref: 'refs/tags/v1.2.3', refName: 'v1.2.3' }, /Invalid Linux release tag/u],
  ['branch dispatch', { ref: 'refs/heads/main', refName: 'main' }, /pre-existing linux-v/u],
  ['version mismatch', { manifestVersion: '1.2.4' }, /does not match release tag/u],
  ['checkout drift', { headCommit: 'b'.repeat(40) }, /not tag-bound/u],
  ['unmerged commit', { reachableFromMain: false }, /not reachable from origin\/main/u]
]) {
  test(`fails closed for ${name}`, () => {
    assert.throws(() => resolveLinuxReleaseBinding({ ...valid, ...override }), message);
  });
}

for (const tag of ['linux-v01.2.3', 'linux-v1.2.3-01', 'linux-v1.2.3-alpha..1']) {
  test(`rejects invalid SemVer tag ${tag}`, () => {
    assert.throws(() => resolveLinuxReleaseBinding({
      ...valid,
      ref: `refs/tags/${tag}`,
      refName: tag,
      manifestVersion: tag.slice('linux-v'.length)
    }), /Invalid Linux release tag/u);
  });
}

test('workflow contract preserves one commit and includes source in provenance and publication', () => {
  const workflow = fs.readFileSync(path.join(root, '.github/workflows/linux-release.yml'), 'utf8');
  assert.match(workflow, /tags:\s*\n\s*- "linux-v\*"/u);
  assert.doesNotMatch(workflow, /\$\{\{ inputs\.version \}\}/u);
  assert.match(workflow, /fetch-depth: 0/u);
  assert.match(workflow, /OPENBURNBAR_RELEASE_COMMIT: \$\{\{ steps\.release-binding\.outputs\.commit \}\}/u);
  assert.match(workflow, /-name '\*-source-\*\.tar\.gz'/u);
  assert.match(workflow, /cosign verify-blob-attestation/u);
  assert.match(workflow, /--verify-tag/u);
  assert.match(workflow, /--target "\$RELEASE_COMMIT"/u);
  assert.match(workflow, /--latest=false/u);
});

test('allow-blocked never masks release verification failures', () => {
  const verifier = fs.readFileSync(path.join(root, 'scripts/linux-port/verify-linux-release.mjs'), 'utf8');
  assert.match(verifier, /passed:\s*failures\.length === 0,/u);
  assert.match(verifier, /process\.exit\(report\.passed \? 0 : 1\);/u);
  assert.doesNotMatch(verifier, /failures\.length === 0\s*\|\|\s*allowBlocked/u);
});

test('detached release signatures verify only for the pinned key and exact bytes', () => {
  const artifact = Buffer.from('openburnbar-linux-release-artifact', 'utf8');
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const { publicKey: wrongPublicKey } = crypto.generateKeyPairSync('ed25519');
  const signature = crypto.sign(null, artifact, privateKey);

  assert.equal(verifyEd25519Signature(artifact, signature, publicKey), true);
  assert.equal(verifyEd25519Signature(Buffer.from('tampered'), signature, publicKey), false);
  assert.equal(verifyEd25519Signature(artifact, signature, wrongPublicKey), false);
});
