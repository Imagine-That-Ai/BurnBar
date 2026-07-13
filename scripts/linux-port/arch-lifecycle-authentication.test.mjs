import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { authenticateArchLifecycleReport, requiredLifecycleSteps } from './lib/linux-package-session.mjs';

const version = '1.2.3';
const previousVersion = '1.2.2';
const architecture = 'aarch64';
const gitCommit = 'a'.repeat(40);

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function record(file, bytes) {
  return { file, sha256: sha256(bytes), size: bytes.length };
}

function signed(bytes, privateKey) {
  return crypto.sign(null, bytes, privateKey);
}

function lifecycleSteps(previous, candidate) {
  const steps = [
    { command: 'pacman -Syu --noconfirm --needed gtk3', exitCode: 0 },
    { command: 'pacman -T gtk3', exitCode: 0 }
  ];
  for (const packageRecord of [previous, candidate, previous, candidate]) {
    steps.push(
      { command: `pacman -U --noconfirm /workspace/${packageRecord.file}`, exitCode: 0 },
      { command: 'pacman -Qi openburnbar', exitCode: 0 },
      { command: '/usr/bin/openburnbar-linux-desktop --version', exitCode: 0 },
      { command: '/usr/libexec/openburnbar-daemon-launch --help', exitCode: 0 }
    );
  }
  return steps;
}

function transition(from, to) {
  return {
    status: 'passed', manager: 'pacman', packageName: 'openburnbar', architecture,
    fromVersion: from.version, toVersion: to.version,
    fromSha256: from.sha256, toSha256: to.sha256
  };
}

function makeFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-arch-auth-'));
  const outDir = path.join(root, '.linux-shard');
  const previousDir = path.join(outDir, 'previous', 'arch');
  const artifactsDir = path.join(outDir, 'artifacts');
  const manifestsDir = path.join(outDir, 'installed-manifests');
  fs.mkdirSync(previousDir, { recursive: true });
  fs.mkdirSync(artifactsDir, { recursive: true });
  fs.mkdirSync(manifestsDir, { recursive: true });
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const publicKeyFile = path.join(root, 'release.pub.pem');
  fs.writeFileSync(publicKeyFile, publicKey.export({ type: 'spki', format: 'pem' }));
  const candidateFile = path.join(artifactsDir, `openburnbar-${version}-1-${architecture}.pkg.tar.zst`);
  const previousFile = path.join(previousDir, `openburnbar-${previousVersion}-1-${architecture}.pkg.tar.zst`);
  const candidateBytes = Buffer.from('candidate-package');
  const previousBytes = Buffer.from('previous-package');
  fs.writeFileSync(candidateFile, candidateBytes);
  fs.writeFileSync(previousFile, previousBytes);
  const candidateRelative = path.relative(root, candidateFile).split(path.sep).join('/');
  const previousRelative = path.relative(root, previousFile).split(path.sep).join('/');
  const candidate = { ...record(candidateRelative, candidateBytes), version };
  const reportCandidate = { ...candidate };
  const candidateManifestBytes = Buffer.from(JSON.stringify({
    packageName: 'openburnbar', packageFormat: 'arch', packageArchitecture: architecture,
    packageVersion: version, gitCommit
  }));
  const candidateManifestFile = path.join(manifestsDir, `arch-${architecture}.installed-manifest.json`);
  const candidateManifestSignatureFile = `${candidateManifestFile}.sig`;
  fs.writeFileSync(candidateManifestFile, candidateManifestBytes);
  fs.writeFileSync(candidateManifestSignatureFile, signed(candidateManifestBytes, privateKey));
  candidate.installedManifest = record(
    path.relative(root, candidateManifestFile).split(path.sep).join('/'), candidateManifestBytes
  );
  candidate.installedManifestSignature = record(
    path.relative(root, candidateManifestSignatureFile).split(path.sep).join('/'),
    fs.readFileSync(candidateManifestSignatureFile)
  );
  const previous = { ...record(previousRelative, previousBytes), version: previousVersion };
  const manifestBytes = Buffer.from(JSON.stringify({
    packageName: 'openburnbar', packageFormat: 'arch', packageArchitecture: architecture,
    packageVersion: previousVersion, gitCommit
  }));
  const manifestFile = path.join(previousDir, `openburnbar-${previousVersion}-${architecture}.installed-manifest.json`);
  const manifestSignatureFile = path.join(previousDir, `openburnbar-${previousVersion}-${architecture}.installed-manifest.ed25519`);
  fs.writeFileSync(manifestFile, manifestBytes);
  fs.writeFileSync(manifestSignatureFile, signed(manifestBytes, privateKey));
  const closureBytes = Buffer.from(JSON.stringify({
    status: 'passed', stage: 'candidate', version: previousVersion,
    targetHead: gitCommit, sourceCommit: gitCommit,
    packages: [{
      format: 'arch', architecture,
      artifact: { sha256: previous.sha256, size: previous.size },
      installedManifest: record('unused', manifestBytes),
      installedManifestSignature: record('unused', fs.readFileSync(manifestSignatureFile))
    }]
  }));
  const closureFile = path.join(previousDir, 'product-proof-closure.json');
  const closureSignatureFile = path.join(previousDir, 'product-proof-closure.json.ed25519.sig');
  fs.writeFileSync(closureFile, closureBytes);
  fs.writeFileSync(closureSignatureFile, signed(closureBytes, privateKey));
  const packageSignatureFile = `${previousFile}.ed25519.sig`;
  fs.writeFileSync(packageSignatureFile, signed(previousBytes, privateKey));
  const provenance = {
    releaseTag: `linux-v${previousVersion}`,
    releaseCommit: gitCommit,
    packageSignature: record(path.relative(root, packageSignatureFile).split(path.sep).join('/'), fs.readFileSync(packageSignatureFile)),
    installedManifest: record(path.relative(root, manifestFile).split(path.sep).join('/'), manifestBytes),
    installedManifestSignature: record(path.relative(root, manifestSignatureFile).split(path.sep).join('/'), fs.readFileSync(manifestSignatureFile)),
    productProofClosure: record(path.relative(root, closureFile).split(path.sep).join('/'), closureBytes),
    productProofClosureSignature: record(path.relative(root, closureSignatureFile).split(path.sep).join('/'), fs.readFileSync(closureSignatureFile))
  };
  const sentinel = 'd'.repeat(64);
  const report = {
    schemaVersion: 1, manager: 'pacman', packageName: 'openburnbar', architecture, gitCommit,
    candidate: reportCandidate, previous, previousProvenance: provenance, steps: lifecycleSteps(previous, reportCandidate), passed: true,
    lifecycle: {
      update: transition(previous, reportCandidate), rollback: transition(reportCandidate, previous),
      dataPreservation: {
        status: 'passed', sentinelSha256: sentinel,
        afterPreviousSha256: sentinel, afterUpdateSha256: sentinel,
        afterRollbackSha256: sentinel, afterRestoreSha256: sentinel
      }
    }
  };
  return {
    root, outDir, report, artifact: candidate,
    publicKeyFile,
    privateKey, publicKey, closureFile, previousFile
  };
}

test('Arch finalizer re-authenticates exact package, manifest, closure, and signatures', (t) => {
  const fixture = makeFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  const context = {
    report: fixture.report,
    architecture,
    version,
    gitCommit,
    artifact: fixture.artifact,
    releaseRoot: fixture.root,
    publicKeyFile: fixture.publicKeyFile,
  };
  assert.equal(authenticateArchLifecycleReport(context), true);

  fs.appendFileSync(fixture.closureFile, 'forged closure\n');
  assert.throws(() => authenticateArchLifecycleReport(context), /sealed provenance|signature/u);
  fs.writeFileSync(fixture.closureFile, JSON.stringify({ status: 'passed' }));
  assert.throws(() => authenticateArchLifecycleReport(context), /sealed provenance|signature/u);

  const fresh = makeFixture();
  t.after(() => fs.rmSync(fresh.root, { recursive: true, force: true }));
  const freshContext = {
    ...context,
    report: fresh.report,
    artifact: fresh.artifact,
    releaseRoot: fresh.root,
    publicKeyFile: fresh.publicKeyFile,
  };
  fs.appendFileSync(fresh.previousFile, 'post-verification mutation');
  assert.throws(() => authenticateArchLifecycleReport(freshContext), /sealed provenance/u);
});

test('authentication report schema remains exact and lifecycle steps stay complete', () => {
  const fixture = makeFixture();
  try {
    assert.equal(fixture.report.steps.length, 18);
    assert.deepEqual(Object.keys(fixture.report.lifecycle).sort(), ['dataPreservation', 'rollback', 'update']);
    assert.equal(requiredLifecycleSteps.length, 6);
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  }
});
