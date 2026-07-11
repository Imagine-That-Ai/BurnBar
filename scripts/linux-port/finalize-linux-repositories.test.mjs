import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const script = path.join(repoRoot, 'scripts/linux-port/finalize-linux-repositories.mjs');
const version = '1.2.3';
const channel = 'prerelease';
const commit = '0123456789abcdef0123456789abcdef01234567';

test('finalizer binds repository closure, signature, and lifecycle into provenance and package closure', () => {
  const value = fixture();
  try {
    const result = run(value.releaseOut);
    assert.equal(result.status, 0, result.stderr);
    const closure = JSON.parse(fs.readFileSync(value.packageClosurePath, 'utf8'));
    const provenance = JSON.parse(fs.readFileSync(value.provenancePath, 'utf8'));
    for (const key of ['repositoryClosure', 'repositoryClosureSignature', 'repositoryLifecycle']) {
      assert.deepEqual(closure.sidecars[key], provenance.repositories[key]);
      assert.match(closure.sidecars[key].sha256, /^[a-f0-9]{64}$/u);
    }
    assert.equal(closure.repositoryPackageSetRootSha256, value.packageSetRootSha256);
    assert.equal(provenance.repositories.signingFingerprint, 'A'.repeat(40));
    assert.equal(provenance.repositories.signingSubkeyFingerprint, 'B'.repeat(40));
    assert.equal(closure.sidecars.provenancePredicate.sha256, digest(fs.readFileSync(value.provenancePath)));
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('finalizer rejects stale or failed lifecycle evidence without mutating release closure', () => {
  for (const mutation of [
    (lifecycle) => { lifecycle.repositoryClosureSha256 = '0'.repeat(64); },
    (lifecycle) => { lifecycle.passed = false; },
    (lifecycle) => { lifecycle.apt.pop(); }
  ]) {
    const value = fixture();
    try {
      const before = fs.readFileSync(value.packageClosurePath);
      const lifecycle = JSON.parse(fs.readFileSync(value.lifecyclePath, 'utf8'));
      mutation(lifecycle);
      fs.writeFileSync(value.lifecyclePath, `${JSON.stringify(lifecycle)}\n`);
      const result = run(value.releaseOut);
      assert.notEqual(result.status, 0);
      assert.deepEqual(fs.readFileSync(value.packageClosurePath), before);
    } finally {
      fs.rmSync(value.root, { recursive: true, force: true });
    }
  }
});

test('finalizer rejects a repository channel that disagrees with the signed update feed', () => {
  const value = fixture();
  try {
    const feed = JSON.parse(fs.readFileSync(value.updateFeedPath, 'utf8'));
    feed.channel = 'stable';
    fs.writeFileSync(value.updateFeedPath, `${JSON.stringify(feed)}\n`);
    const result = run(value.releaseOut);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /signed update feed identity/u);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

function fixture() {
  const root = fs.mkdtempSync(path.join(repoRoot, '.linux-repository-finalize-test-'));
  const releaseOut = path.join(root, 'release');
  const sidecars = path.join(releaseOut, 'sidecars');
  const repositories = path.join(releaseOut, 'repositories');
  fs.mkdirSync(sidecars, { recursive: true });
  fs.mkdirSync(repositories, { recursive: true });
  const provenancePath = path.join(sidecars, 'provenance.json');
  fs.writeFileSync(provenancePath, `${JSON.stringify({ version, git: { commit } })}\n`);
  const updateFeedPath = path.join(sidecars, 'latest-linux.draft.json');
  fs.writeFileSync(updateFeedPath, `${JSON.stringify({ version, channel, gitCommit: commit })}\n`);
  const packageClosurePath = path.join(releaseOut, 'package-closure.json');
  fs.writeFileSync(packageClosurePath, `${JSON.stringify({
    schemaVersion: 3,
    version,
    git: { commit },
    sidecars: {
      provenancePredicate: {
        file: path.relative(repoRoot, provenancePath),
        sha256: digest(fs.readFileSync(provenancePath)),
        size: fs.statSync(provenancePath).size
      },
      updateFeed: {
        file: path.relative(repoRoot, updateFeedPath),
        sha256: digest(fs.readFileSync(updateFeedPath)),
        size: fs.statSync(updateFeedPath).size
      }
    }
  })}\n`);
  const packageSetRootSha256 = digest(Buffer.from('package-set'));
  const repositoryClosurePath = path.join(repositories, 'repository-closure.json');
  fs.writeFileSync(repositoryClosurePath, `${JSON.stringify({
    schemaVersion: 1,
    version,
    channel,
    gitCommit: commit,
    packageSetRootSha256,
    signing: { fingerprint: 'A'.repeat(40), signingFingerprint: 'B'.repeat(40) },
    lifecycleRequired: {
      architectures: ['aarch64', 'x86_64'],
      operations: ['install', 'remove'],
      packageManagers: ['apt', 'dnf']
    }
  })}\n`);
  fs.writeFileSync(`${repositoryClosurePath}.asc`, 'signature\n');
  const lifecyclePath = path.join(repositories, 'repository-lifecycle.json');
  fs.writeFileSync(lifecyclePath, `${JSON.stringify({
    schemaVersion: 1,
    version,
    channel,
    repositoryClosureSha256: digest(fs.readFileSync(repositoryClosurePath)),
    architectures: ['aarch64', 'x86_64'],
    operations: ['install', 'remove'],
    apt: [
      { passed: true, architecture: 'amd64', platform: 'linux/amd64' },
      { passed: true, architecture: 'arm64', platform: 'linux/arm64' }
    ],
    rpm: [
      { passed: true, architecture: 'x86_64', platform: 'linux/amd64' },
      { passed: true, architecture: 'aarch64', platform: 'linux/arm64' }
    ],
    passed: true
  })}\n`);
  return {
    root,
    releaseOut,
    packageClosurePath,
    provenancePath,
    updateFeedPath,
    lifecyclePath,
    packageSetRootSha256
  };
}

function run(releaseOut) {
  return spawnSync(process.execPath, [script, '--version', version, '--channel', channel], {
    cwd: repoRoot,
    env: { ...process.env, OPENBURNBAR_LINUX_RELEASE_OUT: releaseOut },
    encoding: 'utf8'
  });
}

function digest(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}
