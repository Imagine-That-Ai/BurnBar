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

test('candidate and promotion workflows preserve one commit and separate provenance from publication', () => {
  const workflow = fs.readFileSync(path.join(root, '.github/workflows/linux-release.yml'), 'utf8');
  const promotion = fs.readFileSync(path.join(root, '.github/workflows/linux-release-promote.yml'), 'utf8');
  const postResolverWorkflow = workflow.slice(workflow.indexOf('build-architecture:'));
  assert.match(workflow, /tags:\s*\n\s*- "linux-v\*"/u);
  assert.match(workflow, /INPUT_VERSION:\s*\$\{\{ inputs\.version \}\}/u);
  assert.equal((workflow.match(/\$\{\{ inputs\.version \}\}/gu) ?? []).length, 1);
  assert.doesNotMatch(postResolverWorkflow, /\$\{\{ inputs\.version \}\}/u);
  assert.match(workflow, /resolve-linux-release-version\.mjs --github-output/u);
  assert.match(workflow, /--version '\$\{\{ needs\.resolve-release\.outputs\.version \}\}'/u);
  assert.match(workflow, /OPENBURNBAR_LINUX_RELEASE_BASE_URL: https:\/\/github\.com\/Imagine-That-Ai\/BurnBar\/releases\/download\/\$\{\{ needs\.resolve-release\.outputs\.tag \}\}/u);
  assert.match(workflow, /list-linux-release-attestation-subjects\.mjs/u);
  assert.match(workflow, /cosign attest-blob/u);
  assert.match(workflow, /node scripts\/linux-port\/verify-linux-release\.mjs\s+--candidate\s+--phase final\s+--version '\$\{\{ needs\.resolve-release\.outputs\.version \}\}'/u);
  assert.doesNotMatch(workflow, /gh release create/u);
  assert.match(promotion, /tag="linux-v\$\{version\}"/u);
  assert.match(promotion, /release_commit="\$\(git rev-parse HEAD\)"/u);
  assert.match(promotion, /git fetch --force origin "\+refs\/tags\/\$\{tag\}:refs\/tags\/\$\{tag\}"/u);
  assert.match(promotion, /tag_commit="\$\(git rev-list -n 1 "refs\/tags\/\$\{tag\}\^\{commit\}"\)"/u);
  assert.match(promotion, /if \[\[ "\$tag_commit" != "\$release_commit" \]\]; then/u);
  assert.match(promotion, /--draft/u);
  assert.match(promotion, /--verify-tag/u);
  assert.match(promotion, /--target "\$release_commit"/u);
  assert.match(promotion, /--latest=false/u);
  assert.match(promotion, /gh release edit "linux-v\$\{version\}" --draft=false/u);
});

test('allow-blocked never masks release verification failures', () => {
  const verifier = fs.readFileSync(path.join(root, 'scripts/linux-port/verify-linux-release.mjs'), 'utf8');
  const pureVerifier = fs.readFileSync(path.join(root, 'scripts/linux-port/lib/linux-release-verify.mjs'), 'utf8');
  const workflowWiring = fs.readFileSync(path.join(root, 'scripts/linux-port/verify-linux-workflow-wiring.mjs'), 'utf8');
  assert.match(verifier, /passed:\s*failures\.length === 0,/u);
  assert.match(verifier, /process\.exit\(report\.passed \? 0 : 1\);/u);
  assert.doesNotMatch(verifier, /failures\.length === 0\s*\|\|\s*allowBlocked/u);
  assert.doesNotMatch(verifier, /report\.passed\s*\|\|\s*diagnostic/u);
  assert.match(verifier, /const diagnostic = argv\.includes\('--diagnostic'\) \|\| argv\.includes\('--allow-blocked'\);/u);
  assert.match(verifier, /--allow-blocked is deprecated; diagnostic output never downgrades release failures\./u);
  assert.match(verifier, /import \{ verifyLinuxReleaseCandidate \} from '\.\/lib\/linux-release-verify\.mjs';/u);
  assert.match(verifier, /const pure = verifyLinuxReleaseCandidate\(/u);
  assert.match(verifier, /failures\.push\(\.\.\.pure\.failures\);/u);
  assert.match(verifier, /runStep\('node', \['scripts\/linux-port\/validate-parity-ledger\.mjs'\]/u);
  assert.doesNotMatch(verifier, /validate-parity-ledger\.mjs'[\s\S]{0,120}--allow-blocked/u);
  assert.match(verifier, /fail\('parity ledger is not green for release promotion\.'/u);
  assert.match(verifier, /fail\('source archive does not equal a fresh git archive of the release commit\.'/u);
  assert.match(verifier, /verify-blob-attestation/u);
  assert.match(verifier, /fail\('Sigstore bundle verification failed\.'/u);
  assert.match(verifier, /release checkout has unexpected dirty files outside generated release output/u);
  assert.match(pureVerifier, /return \{ passed: failures\.length === 0, failures \};/u);
  assert.match(pureVerifier, /package closure schemaVersion must be 3\./u);
  assert.match(pureVerifier, /package closure tag does not match linux release version\./u);
  assert.match(pureVerifier, /release public-key fingerprint does not match the pinned manifest value\./u);
  assert.match(pureVerifier, /required \$\{key\} artifact is absent from package closure\./u);
  assert.match(pureVerifier, /update feed signing fingerprint does not match the pinned manifest value\./u);
  assert.match(pureVerifier, /Ed25519 signature verification failed/u);
  assert.match(pureVerifier, /\$\{kind\} sidecar is absent from package closure\./u);
  assert.match(pureVerifier, /parity attestation is not green for the release commit\./u);
  assert.match(workflowWiring, /release verification may not use --allow-blocked\./u);
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
