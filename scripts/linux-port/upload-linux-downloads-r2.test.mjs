import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const uploadScript = path.join(repoRoot, 'scripts/upload-linux-downloads-r2.sh');
const version = '1.2.3';
const releasePrefix = `linux/releases/linux-v${version}`;
const publicBase = 'https://downloads.burnbar.ai';
const oldActivation = Buffer.from('old-prerelease-activation\n');

test('publisher uploads every immutable object through the authenticated Worker before metadata verification', () => {
  const value = fixture();
  try {
    const result = runPublisher(value);
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);

    const keys = readPutKeys(value.log);
    const snapshotPrefix = `linux/repository-snapshots/prerelease/${value.snapshotId}`;
    assert.equal(keys.length, new Set(keys).size, 'publisher must not overwrite an object within one transaction');
    for (const name of [
      'latest-linux-prerelease.json',
      ...value.artifactNames,
      ...value.artifactNames.map((artifact) => `${artifact}.ed25519.sig`),
      'latest-linux-prerelease.json.ed25519.sig'
    ]) {
      assert.ok(keys.includes(`${releasePrefix}/${name}`), name);
    }
    assert.ok(keys.indexOf(`${releasePrefix}/${value.artifactNames[0]}`)
      < keys.indexOf(`${snapshotPrefix}/apt/dists/prerelease/Release`));
    for (const relative of value.repositoryRelatives) {
      assert.ok(keys.includes(`${snapshotPrefix}/${relative}`), relative);
    }
    assert.ok(keys.includes('linux/apt/dists/prerelease/main/binary-amd64/by-hash/SHA256/abc'));
    assert.ok(keys.includes('linux/rpm/prerelease/x86_64/repodata/abc-primary.xml.gz'));
    assert.ok(!keys.includes('linux/apt/dists/prerelease/Release'));
    assert.ok(!keys.includes('linux/rpm/prerelease/x86_64/repodata/repomd.xml'));
    for (const bootstrap of [
      'apt/openburnbar-archive-keyring.gpg',
      'apt/openburnbar-prerelease.sources',
      'rpm/RPM-GPG-KEY-openburnbar',
      'rpm/openburnbar-prerelease.repo'
    ]) {
      assert.ok(keys.includes(`${snapshotPrefix}/${bootstrap}`));
      assert.ok(!keys.includes(`linux/${bootstrap}`));
    }
    assert.ok(!keys.some((key) => key.startsWith('linux/repository-activations/')));
    assert.ok(!keys.includes('latest-linux.json'));
    assertActivationNamespaceUnchanged(value);
    assert.doesNotMatch(fs.readFileSync(value.log, 'utf8'), new RegExp(value.uploadToken, 'u'));
    assert.equal(result.stdout.includes(value.uploadToken) || result.stderr.includes(value.uploadToken), false);

    const receipt = JSON.parse(fs.readFileSync(path.join(value.releaseOut, 'repository-upload.json'), 'utf8'));
    assert.equal(receipt.snapshotId, value.snapshotId);
    assert.equal(receipt.sourceCommit, 'a'.repeat(40));
    assert.equal(receipt.counts.release, 18);
    assert.equal(receipt.counts.snapshot, value.repositoryRelatives.length);
    assert.equal(receipt.counts.totalOperations, keys.length);
    const manifestPath = path.join(value.releaseOut, receipt.manifest.file);
    assert.equal(crypto.createHash('sha256').update(fs.readFileSync(manifestPath)).digest('hex'), receipt.manifest.sha256);
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    assert.equal(manifest.operations.length, keys.length);
    assert.ok(manifest.operations.every((operation) => operation.status === 'created'));
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('an identical retry is idempotent and preserves the old activation', () => {
  const value = fixture();
  try {
    const first = runPublisher(value);
    assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`);
    const firstKeys = readPutKeys(value.log);
    fs.rmSync(path.join(value.releaseOut, 'repository-upload.json'));
    fs.rmSync(path.join(value.releaseOut, 'repository-upload-manifest.json'));
    fs.writeFileSync(value.log, '');

    const retry = runPublisher(value);
    assert.equal(retry.status, 0, `${retry.stdout}\n${retry.stderr}`);
    assert.deepEqual(readPutKeys(value.log), firstKeys);
    const retryManifest = JSON.parse(fs.readFileSync(path.join(value.releaseOut, 'repository-upload-manifest.json'), 'utf8'));
    assert.ok(retryManifest.operations.every((operation) => operation.status === 'unchanged'));
    assertActivationNamespaceUnchanged(value);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('immutable key drift is rejected without changing activation or publishing the update feed', () => {
  const value = fixture();
  try {
    const first = runPublisher(value);
    assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`);
    fs.rmSync(path.join(value.releaseOut, 'repository-upload.json'));
    fs.rmSync(path.join(value.releaseOut, 'repository-upload-manifest.json'));
    fs.appendFileSync(path.join(value.releaseOut, 'artifacts', value.artifactNames[0]), 'drift\n');

    const drift = runPublisher(value);
    assert.notEqual(drift.status, 0, 'conflicting bytes at an immutable key must fail');
    assert.match(drift.stderr, /immutable object already exists with different bytes/u);
    assertActivationNamespaceUnchanged(value);
    assert.equal(fs.existsSync(path.join(value.objectRoot, 'latest-linux.json')), false);
    assert.equal(fs.existsSync(path.join(value.releaseOut, 'repository-upload.json')), false);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('every interrupted immutable Worker upload preserves the old activation and withholds the update feed', async () => {
  const discovery = fixture();
  let putCount;
  try {
    const result = runPublisher(discovery);
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    putCount = readPutKeys(discovery.log).length;
    assert.ok(putCount > 0);
  } finally {
    fs.rmSync(discovery.root, { recursive: true, force: true });
  }

  let nextFailure = 1;
  const workers = Array.from({ length: Math.min(6, putCount) }, async () => {
    while (nextFailure <= putCount) {
      const failAfterPut = nextFailure;
      nextFailure += 1;
      const value = fixture({ failAfterPut });
      try {
        const result = await runPublisherAsync(value);
        assert.notEqual(result.status, 0, `immutable upload ${failAfterPut}/${putCount} unexpectedly succeeded`);
        assert.equal(Number(fs.readFileSync(value.counter, 'utf8')), failAfterPut);
        assertActivationNamespaceUnchanged(value);
        assert.equal(
          fs.existsSync(path.join(value.objectRoot, 'latest-linux.json')),
          false,
          `latest-linux.json was published after failed put ${failAfterPut}/${putCount}`
        );
        assert.equal(
          fs.existsSync(path.join(value.releaseOut, 'repository-upload.json')),
          false,
          `upload receipt was written after failed put ${failAfterPut}/${putCount}`
        );
        assert.equal(fs.existsSync(path.join(value.releaseOut, 'repository-upload-manifest.json')), false);
      } finally {
        fs.rmSync(value.root, { recursive: true, force: true });
      }
    }
  });
  await Promise.all(workers);
});

test('publisher rejects a missing token or non-production origin before any upload', () => {
  for (const environment of [
    { OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN: '' },
    { OPENBURNBAR_R2_PUBLIC_BASE_URL: 'https://attacker.example' }
  ]) {
    const value = fixture();
    try {
      const result = runPublisher(value, environment);
      assert.notEqual(result.status, 0);
      assert.deepEqual(readPutKeys(value.log), []);
      assertActivationNamespaceUnchanged(value);
      assert.equal(result.stdout.includes(value.uploadToken), false);
      assert.equal(result.stderr.includes(value.uploadToken), false);
    } finally {
      fs.rmSync(value.root, { recursive: true, force: true });
    }
  }
});

function fixture({ failAfterPut = null } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-r2-publish-test-'));
  const releaseOut = path.join(root, 'release');
  const artifacts = path.join(releaseOut, 'artifacts');
  const sidecars = path.join(releaseOut, 'sidecars');
  const repositories = path.join(releaseOut, 'repositories');
  const bin = path.join(root, 'bin');
  const objectRoot = path.join(root, 'objects');
  const metadataRoot = path.join(root, 'metadata');
  const log = path.join(root, 'put.log');
  const counter = path.join(root, 'put-count');
  for (const directory of [artifacts, sidecars, repositories, bin, objectRoot, metadataRoot]) {
    fs.mkdirSync(directory, { recursive: true });
  }

  const artifactNames = [];
  for (const architecture of ['aarch64', 'x86_64']) {
    for (const extension of ['AppImage', 'deb', 'rpm']) {
      artifactNames.push(`OpenBurnBar-${version}-${architecture}.${extension}`);
    }
    artifactNames.push(`openburnbar-daemon-${version}-${architecture}`);
  }
  for (const name of artifactNames) {
    fs.writeFileSync(path.join(artifacts, name), `artifact:${name}\n`);
    fs.writeFileSync(path.join(sidecars, `${name}.ed25519.sig`), `signature:${name}\n`);
  }
  fs.writeFileSync(path.join(sidecars, 'latest-linux.json.ed25519.sig'), 'feed-signature\n');

  const feed = {
    version,
    signature: { url: `${publicBase}/${releasePrefix}/latest-linux-prerelease.json.ed25519.sig` },
    artifacts: artifactNames.map((name) => ({
      url: `${publicBase}/${releasePrefix}/${name}`,
      signatureUrl: `${publicBase}/${releasePrefix}/${name}.ed25519.sig`
    }))
  };
  fs.writeFileSync(path.join(releaseOut, 'latest-linux.draft.json'), `${JSON.stringify(feed)}\n`);
  fs.writeFileSync(path.join(releaseOut, 'release-verification.json'), `${JSON.stringify({
    phase: 'final', passed: true, failures: []
  })}\n`);

  const repositoryRelatives = [
    'apt/pool/main/o/openburnbar/OpenBurnBar_1.2.3_amd64.deb',
    'apt/pool/main/o/openburnbar/OpenBurnBar_1.2.3_arm64.deb',
    'rpm/prerelease/x86_64/OpenBurnBar-1.2.3-1.x86_64.rpm',
    'rpm/prerelease/aarch64/OpenBurnBar-1.2.3-1.aarch64.rpm',
    'apt/dists/prerelease/main/binary-amd64/by-hash/SHA256/abc',
    'apt/dists/prerelease/Release.gpg',
    'apt/dists/prerelease/Release',
    'apt/dists/prerelease/InRelease',
    'rpm/prerelease/x86_64/repodata/abc-primary.xml.gz',
    'rpm/prerelease/x86_64/repodata/repomd.xml.asc',
    'rpm/prerelease/x86_64/repodata/repomd.xml',
    'rpm/prerelease/aarch64/repodata/repomd.xml.asc',
    'rpm/prerelease/aarch64/repodata/repomd.xml',
    'apt/openburnbar-archive-keyring.gpg',
    'apt/openburnbar-prerelease.sources',
    'rpm/RPM-GPG-KEY-openburnbar',
    'rpm/openburnbar-prerelease.repo',
    'repository-lifecycle.json',
    'repository-closure.json.asc',
    'repository-closure.json'
  ];
  for (const relative of repositoryRelatives) {
    const file = path.join(repositories, relative);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, relative === 'repository-closure.json' ? `${JSON.stringify({
      schemaVersion: 1,
      channel: 'prerelease',
      version,
      gitCommit: 'a'.repeat(40)
    })}\n` : `${relative}\n`);
  }

  const activationRelative = 'linux/repository-activations/prerelease.json';
  const activationFile = path.join(objectRoot, activationRelative);
  fs.mkdirSync(path.dirname(activationFile), { recursive: true });
  fs.writeFileSync(activationFile, oldActivation);
  fs.writeFileSync(counter, '0\n');
  installFakeCommands({ bin });

  const uploadToken = 'test-immutable-upload-token-at-least-32-characters';

  return {
    root,
    releaseOut,
    objectRoot,
    metadataRoot,
    log,
    counter,
    uploadToken,
    failAfterPut,
    artifactNames,
    repositoryRelatives,
    activationRelative,
    activationFile,
    snapshotId: crypto.createHash('sha256')
      .update(fs.readFileSync(path.join(repositories, 'repository-closure.json')))
      .digest('hex')
  };
}

function runPublisher(value, environment = {}) {
  return spawnSync('bash', [uploadScript], publisherOptions(value, environment));
}

function runPublisherAsync(value, environment = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn('bash', [uploadScript], publisherOptions(value, environment));
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.once('error', reject);
    child.once('close', (status, signal) => resolve({ status, signal, stdout, stderr }));
  });
}

function publisherOptions(value, environment = {}) {
  return {
    cwd: repoRoot,
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${path.join(value.root, 'bin')}:${process.env.PATH}`,
      REAL_NODE: process.execPath,
      FAKE_R2_ROOT: value.objectRoot,
      FAKE_R2_METADATA_ROOT: value.metadataRoot,
      FAKE_R2_LOG: value.log,
      FAKE_R2_COUNTER: value.counter,
      FAKE_R2_FAIL_AFTER_PUT: value.failAfterPut == null ? '' : String(value.failAfterPut),
      OPENBURNBAR_LINUX_RELEASE_OUT: value.releaseOut,
      OPENBURNBAR_R2_PUBLIC_BASE_URL: publicBase,
      OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN: value.uploadToken,
      EXPECTED_UPLOAD_TOKEN: value.uploadToken,
      ...environment
    }
  };
}

function assertActivationNamespaceUnchanged(value) {
  const activationRoot = path.join(value.objectRoot, 'linux/repository-activations');
  assert.deepEqual(listRelativeFiles(activationRoot), ['prerelease.json']);
  assert.deepEqual(fs.readFileSync(value.activationFile), oldActivation);
}

function listRelativeFiles(root) {
  if (!fs.existsSync(root)) return [];
  const files = [];
  const walk = (directory) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true }).sort((left, right) => left.name.localeCompare(right.name))) {
      const full = path.join(directory, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile()) files.push(path.relative(root, full).split(path.sep).join('/'));
    }
  };
  walk(root);
  return files;
}

function readPutKeys(log) {
  return fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean) : [];
}

function installFakeCommands({ bin }) {
  const write = (name, source) => fs.writeFileSync(path.join(bin, name), `#!${process.execPath}\n${source}\n`, { mode: 0o755 });
  write('curl', `
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const url = new URL(args.find((value) => value.startsWith('https://')));
if (args.includes('--request')) {
  if (args[args.indexOf('--request') + 1] !== 'PUT' || url.origin !== 'https://downloads.burnbar.ai'
      || url.pathname !== '/linux/repository-upload/immutable') process.exit(90);
  const config = fs.readFileSync(args[args.indexOf('--config') + 1], 'utf8');
  if (config !== 'header = "Authorization: Bearer ' + process.env.EXPECTED_UPLOAD_TOKEN + '"\\n') process.exit(91);
  const headers = new Map();
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] !== '--header') continue;
    const header = args[index + 1];
    const separator = header.indexOf(':');
    headers.set(header.slice(0, separator).toLowerCase(), header.slice(separator + 1).trim());
  }
  const key = headers.get('x-openburnbar-object-key');
  const expectedDigest = headers.get('x-openburnbar-object-sha256');
  const sourceArgument = args[args.indexOf('--data-binary') + 1];
  const source = sourceArgument.slice(1);
  const bytes = fs.readFileSync(source);
  const actualDigest = crypto.createHash('sha256').update(bytes).digest('hex');
  if (!key || expectedDigest !== actualDigest || headers.get('content-length') !== String(bytes.length)) process.exit(92);

  const destination = path.join(process.env.FAKE_R2_ROOT, key);
  const metadataName = crypto.createHash('sha256').update(key).digest('hex') + '.json';
  const metadata = path.join(process.env.FAKE_R2_METADATA_ROOT, metadataName);
  const count = Number(fs.readFileSync(process.env.FAKE_R2_COUNTER, 'utf8')) + 1;
  fs.appendFileSync(process.env.FAKE_R2_LOG, key + '\\n');
  fs.writeFileSync(process.env.FAKE_R2_COUNTER, String(count) + '\\n');
  const existed = fs.existsSync(destination);
  if (existed) {
    const stored = JSON.parse(fs.readFileSync(metadata, 'utf8'));
    if (stored.sha256 !== expectedDigest || stored.size !== bytes.length) {
      process.stderr.write('{"error":"immutable object already exists with different bytes"}\\n');
      process.exit(22);
    }
  } else {
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(source, destination);
    fs.writeFileSync(metadata, JSON.stringify({ sha256: expectedDigest, size: bytes.length }));
  }
  if (process.env.FAKE_R2_FAIL_AFTER_PUT && count === Number(process.env.FAKE_R2_FAIL_AFTER_PUT)) process.exit(73);
  process.stdout.write(JSON.stringify({
    schemaVersion: 1,
    status: existed ? 'unchanged' : 'created',
    key,
    sha256: expectedDigest,
    size: bytes.length,
    etag: '"' + actualDigest.slice(0, 32) + '"'
  }));
  process.exit(0);
}
const destination = args[args.indexOf('-o') + 1];
fs.copyFileSync(path.join(process.env.FAKE_R2_ROOT, url.pathname.startsWith('/') ? url.pathname.slice(1) : url.pathname), destination);
`);
  write('openssl', 'process.exit(0);');
  fs.writeFileSync(path.join(bin, 'node'), `#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == *check-linux-update-feed.mjs ]]; then exit 0; fi
exec "$REAL_NODE" "$@"
`, { mode: 0o755 });
}
