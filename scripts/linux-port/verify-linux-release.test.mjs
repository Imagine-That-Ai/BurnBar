import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { verifyLinuxReleaseCandidate } from './lib/linux-release-verify.mjs';

const VERSION = '1.2.3';
const HEAD = '0123456789abcdef0123456789abcdef01234567';

function digest(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function fixture() {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-release-'));
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const publicKeyPem = publicKey.export({ type: 'spki', format: 'pem' });
  const fingerprint = digest(publicKey.export({ type: 'spki', format: 'der' }));
  const write = (rel, bytes) => {
    const full = path.join(repoRoot, rel);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, bytes);
    return { file: rel, sha256: digest(bytes), size: Buffer.byteLength(bytes) };
  };
  const artifactTypes = ['appimage', 'deb', 'rpm', 'daemon'];
  const architectures = ['aarch64', 'x86_64'];
  const extension = { appimage: 'AppImage', deb: 'deb', rpm: 'rpm', daemon: 'bin' };
  const artifacts = [];
  const signatures = [];
  for (const type of artifactTypes) {
    for (const architecture of architectures) {
      const artifactBytes = Buffer.from(`artifact:${type}:${architecture}`);
      const artifact = {
        type,
        architecture,
        ...write(`out/OpenBurnBar-${VERSION}-${architecture}.${extension[type]}`, artifactBytes)
      };
      const signatureFile = `${artifact.file}.ed25519.sig`;
      write(signatureFile, crypto.sign(null, artifactBytes, privateKey));
      artifacts.push(artifact);
      signatures.push({ artifact: artifact.file, signature: signatureFile, algorithm: 'Ed25519' });
    }
  }
  const checksums = write(
    'out/checksums.txt',
    Buffer.from(`${artifacts.map((artifact) => `${artifact.sha256}  ${artifact.file}`).join('\n')}\n`)
  );
  const sbom = write('out/sbom.json', Buffer.from('{"spdxVersion":"SPDX-2.3"}\n'));
  const vex = write('out/vex.json', Buffer.from('{"@context":"https://openvex.dev/ns/v0.2.0"}\n'));
  const sourceArchive = write('out/source.tar', Buffer.from('source'));
  const parityAttestation = write('out/parity.json', Buffer.from(`${JSON.stringify({ targetHead: HEAD, promotionPassed: true, productParityClaim: true })}\n`));
  const lifecycle = Object.fromEntries(
    ['guiLaunch', 'daemonLaunch', 'versionReadback', 'update', 'rollback', 'dataPreservation'].map((key) => [key, { status: 'passed' }])
  );
  const smokeSummary = { passed: true, failedCount: 0, lifecycle };
  const architectureSessions = write('out/architecture-sessions.json', Buffer.from('{"schemaVersion":1,"sessions":[]}\n'));
  const packageSmoke = write('out/package-smoke-summary.json', Buffer.from(`${JSON.stringify(smokeSummary)}\n`));
  const provenance = {
    version: VERSION,
    git: { commit: HEAD },
    expectedCosignIdentity: `https://github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-release.yml@refs/tags/linux-v${VERSION}`,
    expectedCosignIssuer: 'https://token.actions.githubusercontent.com',
    signatures,
    architectureSessions,
    packageSmoke
  };
  const provenancePredicate = write('out/provenance.json', Buffer.from(`${JSON.stringify(provenance)}\n`));
  const manifest = {
    requiredArtifacts: artifactTypes,
    supportedArchitectures: architectures,
    signing: {
      publicKeySpkiSha256: fingerprint,
      cosignIssuer: 'https://token.actions.githubusercontent.com',
      cosignIdentityTemplate: 'https://github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-release.yml@refs/tags/linux-v{version}'
    }
  };
  const closure = {
    schemaVersion: 3,
    tag: `linux-v${VERSION}`,
    version: VERSION,
    git: { commit: HEAD },
    artifacts,
    sidecars: {
      checksums,
      sbom,
      vex,
      provenancePredicate,
      sourceArchive,
      parityAttestation,
      architectureSessions,
      packageSmoke
    },
    blockers: []
  };
  const releaseBase = `https://github.com/Imagine-That-Ai/BurnBar/releases/download/linux-v${VERSION}`;
  const latest = {
    schemaVersion: 1,
    product: 'OpenBurnBar',
    platform: 'linux',
    version: VERSION,
    gitCommit: HEAD,
    publishedAt: '2026-07-09T00:00:00Z',
    channel: 'stable',
    artifacts: artifacts.map((artifact) => ({
      type: artifact.type,
      architecture: artifact.architecture,
      url: `${releaseBase}/${path.basename(artifact.file)}`,
      sha256: artifact.sha256,
      size: artifact.size,
      signatureUrl: `${releaseBase}/${path.basename(artifact.file)}.ed25519.sig`
    })),
    signature: {
      algorithm: 'Ed25519',
      publicKeySpkiSha256: fingerprint,
      url: `${releaseBase}/latest-linux.json.ed25519.sig`
    }
  };
  const updateFeedBytes = Buffer.from(`${JSON.stringify(latest, null, 2)}\n`);
  const updateFeed = write('out/latest-linux.draft.json', updateFeedBytes);
  const updateFeedSignature = write(
    'out/latest-linux.json.ed25519.sig',
    crypto.sign(null, updateFeedBytes, privateKey)
  );
  closure.sidecars.updateFeed = updateFeed;
  closure.sidecars.updateFeedSignature = updateFeedSignature;
  const input = { repoRoot, manifest, closure, provenance, latest, smokeSummary, publicKeyPem, expectedHead: HEAD, expectedVersion: VERSION };
  return {
    input,
    artifactPath: path.join(repoRoot, artifacts[0].file),
    signaturePath: path.join(repoRoot, signatures[0].signature)
  };
}

test('valid Ed25519 release closure passes pre-attestation verification', () => {
  assert.deepEqual(verifyLinuxReleaseCandidate(fixture().input), { passed: true, failures: [] });
});

test('artifact mutation fails checksum and signature verification', () => {
  const value = fixture();
  fs.appendFileSync(value.artifactPath, 'x');
  const result = verifyLinuxReleaseCandidate(value.input);
  assert.equal(result.passed, false);
  assert.ok(result.failures.some((failure) => /checksum drifted/.test(failure.message)));
  assert.ok(result.failures.some((failure) => /signature verification failed/.test(failure.message)));
});

test('signature mutation fails Ed25519 verification', () => {
  const value = fixture();
  const bytes = fs.readFileSync(value.signaturePath);
  bytes[0] ^= 1;
  fs.writeFileSync(value.signaturePath, bytes);
  const result = verifyLinuxReleaseCandidate(value.input);
  assert.ok(result.failures.some((failure) => /signature verification failed/.test(failure.message)));
});

test('wrong public key and fingerprint fail closed', () => {
  const value = fixture();
  const other = crypto.generateKeyPairSync('ed25519').publicKey.export({ type: 'spki', format: 'pem' });
  value.input.publicKeyPem = other;
  const result = verifyLinuxReleaseCandidate(value.input);
  assert.ok(result.failures.some((failure) => /fingerprint/.test(failure.message)));
  assert.ok(result.failures.some((failure) => /signature verification failed/.test(failure.message)));
});

test('missing and duplicate signatures fail exact coverage', () => {
  const value = fixture();
  value.input.provenance.signatures.push({ ...value.input.provenance.signatures[0] });
  const duplicate = verifyLinuxReleaseCandidate(value.input);
  assert.ok(duplicate.failures.some((failure) => /duplicate signature/.test(failure.message)));
  value.input.provenance.signatures = [];
  const missing = verifyLinuxReleaseCandidate(value.input);
  assert.ok(missing.failures.some((failure) => /no detached Ed25519 signature/.test(failure.message)));
});

test('missing architecture and duplicate type/architecture fail closure coverage', () => {
  const missing = fixture();
  missing.input.closure.artifacts = missing.input.closure.artifacts.filter(
    (artifact) => !(artifact.type === 'rpm' && artifact.architecture === 'x86_64')
  );
  const missingResult = verifyLinuxReleaseCandidate(missing.input);
  assert.ok(missingResult.failures.some((failure) => /required rpm:x86_64/.test(failure.message)));

  const duplicate = fixture();
  duplicate.input.closure.artifacts.push({ ...duplicate.input.closure.artifacts[0] });
  const duplicateResult = verifyLinuxReleaseCandidate(duplicate.input);
  assert.ok(duplicateResult.failures.some((failure) => /duplicate artifact type\/architecture/.test(failure.message)));
});

test('feed artifact checksum and exact architecture coverage are closure-bound', () => {
  const mismatch = fixture();
  mismatch.input.latest.artifacts[0].sha256 = 'f'.repeat(64);
  assert.ok(verifyLinuxReleaseCandidate(mismatch.input).failures.some(
    (failure) => /update feed artifact does not match package closure/.test(failure.message)
  ));

  const missing = fixture();
  missing.input.latest.artifacts.pop();
  assert.ok(verifyLinuxReleaseCandidate(missing.input).failures.some(
    (failure) => /update feed does not exactly cover/.test(failure.message)
  ));
});

test('commit and version disagreements fail', () => {
  const value = fixture();
  value.input.latest.gitCommit = 'wrong';
  value.input.provenance.version = '9.9.9';
  const result = verifyLinuxReleaseCandidate(value.input);
  assert.ok(result.failures.some((failure) => /update feed commit/.test(failure.message)));
  assert.ok(result.failures.some((failure) => /provenance version/.test(failure.message)));
});

test('sidecar mutation fails closure binding', () => {
  for (const kind of [
    'checksums',
    'sbom',
    'vex',
    'provenancePredicate',
    'sourceArchive',
    'parityAttestation',
    'updateFeed',
    'updateFeedSignature'
  ]) {
    const value = fixture();
    fs.appendFileSync(path.join(value.input.repoRoot, value.input.closure.sidecars[kind].file), 'x');
    const result = verifyLinuxReleaseCandidate(value.input);
    assert.ok(result.failures.some((failure) => failure.message === `${kind} sidecar checksum drifted.`), kind);
  }
});

test('missing or extra checksum targets fail', () => {
  const missing = fixture();
  fs.writeFileSync(path.join(missing.input.repoRoot, missing.input.closure.sidecars.checksums.file), '');
  missing.input.closure.sidecars.checksums.sha256 = digest(Buffer.from(''));
  missing.input.closure.sidecars.checksums.size = 0;
  assert.ok(verifyLinuxReleaseCandidate(missing.input).failures.some((failure) => /does not match artifact/.test(failure.message)));

  const extra = fixture();
  const checksumPath = path.join(extra.input.repoRoot, extra.input.closure.sidecars.checksums.file);
  fs.appendFileSync(checksumPath, `${'0'.repeat(64)}  out/extra\n`);
  const bytes = fs.readFileSync(checksumPath);
  extra.input.closure.sidecars.checksums.sha256 = digest(bytes);
  extra.input.closure.sidecars.checksums.size = bytes.length;
  assert.ok(verifyLinuxReleaseCandidate(extra.input).failures.some((failure) => /extra target/.test(failure.message)));
});

test('blocked update or rollback proof fails even when package assertions pass', () => {
  const value = fixture();
  value.input.smokeSummary.lifecycle.update.status = 'blocked';
  value.input.smokeSummary.lifecycle.rollback.status = 'blocked';
  const result = verifyLinuxReleaseCandidate(value.input);
  assert.ok(result.failures.some((failure) => /update/.test(failure.message)));
  assert.ok(result.failures.some((failure) => /rollback/.test(failure.message)));
});

test('final verification requires Sigstore bundles but pre-attestation does not', () => {
  const value = fixture();
  assert.equal(verifyLinuxReleaseCandidate(value.input).passed, true);
  value.input.phase = 'final';
  const result = verifyLinuxReleaseCandidate(value.input);
  assert.ok(result.failures.some((failure) => /Sigstore bundle is missing/.test(failure.message)));
});

test('wrong cosign identity and issuer fail', () => {
  const value = fixture();
  value.input.provenance.expectedCosignIdentity = 'wrong';
  value.input.provenance.expectedCosignIssuer = 'wrong';
  const result = verifyLinuxReleaseCandidate(value.input);
  assert.ok(result.failures.some((failure) => /wrong expected cosign identity/.test(failure.message)));
  assert.ok(result.failures.some((failure) => /wrong expected cosign issuer/.test(failure.message)));
});

test('path traversal fails closed', () => {
  const value = fixture();
  value.input.closure.artifacts[0].file = '../outside';
  const result = verifyLinuxReleaseCandidate(value.input);
  assert.ok(result.failures.some((failure) => /outside the repository/.test(failure.message)));
});
