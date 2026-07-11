import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const script = path.join(repoRoot, 'scripts/publish-linux-update-feed-r2.sh');
const etag = (value) => `"${value.toString(16).padStart(64, '0')}"`;
const ETAGS = {
  repository1: etag(101),
  repository3: etag(103),
  repositoryRaced: etag(199),
  feed1: etag(201),
  feed2: etag(202),
  feedRaced: etag(299)
};

test('feed publication and verification are explicit, pointer-bound phases with no direct R2 puts', () => {
  const value = fixture();
  try {
    const implicit = run(value, []);
    assert.notEqual(implicit.status, 0);
    assert.equal(fs.readFileSync(value.log, 'utf8'), '');

    const published = run(value, ['--publish-only']);
    assert.equal(published.status, 0, `${published.stdout}\n${published.stderr}`);
    const publication = JSON.parse(fs.readFileSync(path.join(value.releaseOut, 'repository-feed-publication.json'), 'utf8'));
    assert.equal(publication.requested.snapshotId, value.snapshotId);
    assert.equal(publication.requested.generation, 1);
    assert.equal(publication.requested.repositoryPointerEtag, ETAGS.repository1);
    assert.deepEqual(publication.requested.expectedCurrent, { generation: null, etag: null });
    assert.equal(publication.result.feed.repository.snapshotId, value.snapshotId);
    assert.equal(publication.result.pointerEtag, ETAGS.feed1);
    assert.equal(fs.existsSync(path.join(value.releaseOut, 'repository-feed-verification.json')), false);
    const publishLog = lines(value.log);
    assert.deepEqual(publishLog.map((row) => row.split(' ')[0]), ['GET', 'GET', 'POST', 'GET', 'GET']);
    assert.equal(publishLog.some((row) => row.includes('/latest-linux.json')), false,
      'first migration publication must not require a root feed route');

    fs.writeFileSync(value.log, '');
    const verified = run(value, ['--verify-only'], { FAKE_FEED_ROUTE_ENABLED: '1' });
    assert.equal(verified.status, 0, `${verified.stdout}\n${verified.stderr}`);
    const verification = JSON.parse(fs.readFileSync(path.join(value.releaseOut, 'repository-feed-verification.json'), 'utf8'));
    assert.equal(verification.snapshotId, value.snapshotId);
    assert.equal(verification.feedPointerEtag, ETAGS.feed1);
    assert.ok(Number.isFinite(Date.parse(verification.verifiedAt)));
    const verifyLog = lines(value.log);
    assert.equal(verifyLog.filter((row) => row.endsWith('/latest-linux.json')).length, 1);
    assert.equal(verifyLog.filter((row) => row.endsWith('/latest-linux.json.ed25519.sig')).length, 1);

    const source = fs.readFileSync(script, 'utf8');
    assert.doesNotMatch(source, /wrangler|r2 object put|CLOUDFLARE_API_TOKEN|OPENBURNBAR_R2_BUCKET/u);
  } finally {
    value.cleanup();
  }
});

test('repository activation race is rejected by Worker CAS without advancing the feed pointer', () => {
  const value = fixture();
  try {
    const result = run(value, ['--publish-only'], { FAKE_RACE_REPOSITORY_ON_POST: '1' });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /feed pointer publication failed: HTTP 409/u);
    assert.equal(fs.existsSync(value.feedState), false);
    assert.equal(fs.existsSync(path.join(value.releaseOut, 'repository-feed-publication.json')), false);
  } finally {
    value.cleanup();
  }
});

test('feed publication binds the live post-drill generation instead of the original activation receipt', () => {
  const value = fixture({ liveGeneration: 3, liveRepositoryEtag: ETAGS.repository3 });
  try {
    const result = run(value, ['--publish-only']);
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    const publication = JSON.parse(fs.readFileSync(
      path.join(value.releaseOut, 'repository-feed-publication.json'), 'utf8'
    ));
    assert.equal(publication.requested.generation, 3);
    assert.equal(publication.requested.repositoryPointerEtag, ETAGS.repository3);
  } finally {
    value.cleanup();
  }
});

test('prerelease publication uses an isolated feed pointer and public route', () => {
  const value = fixture({ channel: 'prerelease' });
  try {
    assert.equal(run(value, ['--publish-only']).status, 0);
    fs.writeFileSync(value.log, '');
    const result = run(value, ['--verify-only'], { FAKE_FEED_ROUTE_ENABLED: '1' });
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    const requests = lines(value.log);
    assert.ok(requests.some((row) => row.endsWith('/linux/update/prerelease/latest-linux.json')));
    assert.ok(requests.some((row) => row.endsWith('/linux/update/prerelease/latest-linux.json.ed25519.sig')));
    assert.equal(requests.some((row) => row === 'GET /latest-linux.json'), false);
  } finally {
    value.cleanup();
  }
});

test('feed compare-and-swap conflict fails without replacing the current pointer', () => {
  const value = fixture({ currentFeed: true });
  try {
    const before = fs.readFileSync(value.feedState);
    const result = run(value, ['--publish-only'], { FAKE_RACE_FEED_ON_POST: '1' });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /feed pointer publication failed: HTTP 409/u);
    const after = JSON.parse(fs.readFileSync(value.feedState, 'utf8'));
    const original = JSON.parse(before);
    assert.equal(after.feed.version, original.feed.version);
    assert.equal(after.pointerEtag, ETAGS.feedRaced);
    assert.equal(fs.existsSync(path.join(value.releaseOut, 'repository-feed-publication.json')), false);
  } finally {
    value.cleanup();
  }
});

test('feed publisher pins credentials to the exact production origin before any request', () => {
  const value = fixture();
  try {
    for (const origin of ['https://downloads.burnbar.ai.example', 'https://downloads.burnbar.ai/path', 'http://downloads.burnbar.ai']) {
      fs.writeFileSync(value.log, '');
      const result = run(value, ['--publish-only'], { OPENBURNBAR_R2_PUBLIC_BASE_URL: origin });
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /bare production origin/u);
      assert.equal(fs.readFileSync(value.log, 'utf8'), '');
    }
  } finally {
    value.cleanup();
  }
});

test('feed publisher does not expose the activation token to child processes', () => {
  const value = fixture();
  try {
    const result = run(value, ['--publish-only']);
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  } finally {
    value.cleanup();
  }
});

test('control-plane responses reject missing, malformed, duplicate, or body-mismatched HTTP ETags', () => {
  for (const environment of [
    { FAKE_OMIT_ETAG_PATH: '/linux/repository-admin/status' },
    { FAKE_MALFORMED_ETAG_PATH: '/linux/repository-admin/status' },
    { FAKE_DUPLICATE_ETAG_PATH: '/linux/repository-admin/status' },
    { FAKE_MISMATCH_ETAG_PATH: '/linux/repository-admin/status' }
  ]) {
    const value = fixture();
    try {
      const result = run(value, ['--publish-only'], environment);
      assert.notEqual(result.status, 0, JSON.stringify(environment));
      assert.match(result.stderr, /HTTP ETag|activation does not match/u);
      assert.equal(fs.existsSync(path.join(value.releaseOut, 'repository-feed-publication.json')), false);
    } finally {
      value.cleanup();
    }
  }
});

test('verify-only requires exact Worker snapshot and feed-generation response headers', () => {
  for (const environment of [
    { FAKE_OMIT_PUBLIC_ROUTING_HEADERS: '1' },
    { FAKE_DUPLICATE_PUBLIC_ROUTING_HEADERS: '1' },
    { FAKE_MISMATCH_PUBLIC_SNAPSHOT: '1' },
    { FAKE_MISMATCH_PUBLIC_FEED_GENERATION: '1' },
    { FAKE_MALFORMED_PUBLIC_FEED_GENERATION: '1' }
  ]) {
    const value = fixture();
    try {
      assert.equal(run(value, ['--publish-only']).status, 0);
      const result = run(value, ['--verify-only'], { FAKE_FEED_ROUTE_ENABLED: '1', ...environment });
      assert.notEqual(result.status, 0, JSON.stringify(environment));
      assert.match(result.stderr, /Worker snapshot and feed generation/u);
      assert.equal(fs.existsSync(path.join(value.releaseOut, 'repository-feed-verification.json')), false);
    } finally {
      value.cleanup();
    }
  }
});

test('verify-only performs real Ed25519 verification and rejects corrupted signatures and wrong keys', () => {
  const corrupted = fixture();
  try {
    assert.equal(run(corrupted, ['--publish-only']).status, 0);
    fs.writeFileSync(path.join(corrupted.releaseOut, 'sidecars/latest-linux.json.ed25519.sig'), Buffer.alloc(64, 0x5a));
    const result = run(corrupted, ['--verify-only'], { FAKE_FEED_ROUTE_ENABLED: '1' });
    assert.notEqual(result.status, 0);
    assert.equal(fs.existsSync(path.join(corrupted.releaseOut, 'repository-feed-verification.json')), false);
  } finally {
    corrupted.cleanup();
  }

  const wrongKey = fixture();
  try {
    assert.equal(run(wrongKey, ['--publish-only']).status, 0);
    const result = run(wrongKey, ['--verify-only'], {
      FAKE_FEED_ROUTE_ENABLED: '1',
      FAKE_OPENSSL_PUBLIC_KEY: wrongKey.wrongPublicKey
    });
    assert.notEqual(result.status, 0);
    assert.equal(fs.existsSync(path.join(wrongKey.releaseOut, 'repository-feed-verification.json')), false);
  } finally {
    wrongKey.cleanup();
  }
});

test('verification receipt override is atomic and create-only', () => {
  const value = fixture();
  try {
    assert.equal(run(value, ['--publish-only']).status, 0);
    const override = path.join(value.root, 'runner-temp', 'post-github-feed-verification.json');
    const environment = {
      FAKE_FEED_ROUTE_ENABLED: '1',
      OPENBURNBAR_LINUX_REPOSITORY_FEED_VERIFICATION_RECEIPT: override
    };
    const verified = run(value, ['--verify-only'], environment);
    assert.equal(verified.status, 0, `${verified.stdout}\n${verified.stderr}`);
    assert.equal(fs.existsSync(override), true);
    assert.equal(fs.existsSync(path.join(value.releaseOut, 'repository-feed-verification.json')), false);
    const original = fs.readFileSync(override);
    const duplicate = run(value, ['--verify-only'], environment);
    assert.notEqual(duplicate.status, 0);
    assert.deepEqual(fs.readFileSync(override), original);
    assert.deepEqual(fs.readdirSync(path.dirname(override)), ['post-github-feed-verification.json']);
  } finally {
    value.cleanup();
  }
});

function fixture(options = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-feed-publish-'));
  const releaseOut = path.join(root, 'release');
  const sidecars = path.join(releaseOut, 'sidecars');
  const repositories = path.join(releaseOut, 'repositories');
  const bin = path.join(root, 'bin');
  const state = path.join(root, 'state');
  const log = path.join(root, 'requests.log');
  for (const directory of [sidecars, repositories, bin, state]) fs.mkdirSync(directory, { recursive: true });
  fs.writeFileSync(log, '');
  const channel = options.channel ?? 'stable';
  const feed = Buffer.from(`${JSON.stringify({ version: '1.2.3', channel })}\n`);
  const signingKeys = crypto.generateKeyPairSync('ed25519');
  const wrongKeys = crypto.generateKeyPairSync('ed25519');
  const signature = crypto.sign(null, feed, signingKeys.privateKey);
  const testPublicKey = path.join(state, 'feed-public.pem');
  const wrongPublicKey = path.join(state, 'wrong-feed-public.pem');
  fs.writeFileSync(testPublicKey, signingKeys.publicKey.export({ type: 'spki', format: 'pem' }));
  fs.writeFileSync(wrongPublicKey, wrongKeys.publicKey.export({ type: 'spki', format: 'pem' }));
  fs.writeFileSync(path.join(releaseOut, 'latest-linux.draft.json'), feed);
  fs.writeFileSync(path.join(sidecars, 'latest-linux.json.ed25519.sig'), signature);
  const closurePath = path.join(repositories, 'repository-closure.json');
  fs.writeFileSync(closurePath, `${JSON.stringify({ version: '1.2.3', channel, gitCommit: 'a'.repeat(40) })}\n`);
  const snapshotId = crypto.createHash('sha256').update(fs.readFileSync(closurePath)).digest('hex');
  fs.writeFileSync(path.join(releaseOut, 'repository-activation.json'), `${JSON.stringify({ dryRun: false, result: {
    activation: { version: '1.2.3', channel, generation: 1, snapshotId, sourceCommit: 'a'.repeat(40) },
    pointerEtag: ETAGS.repository1
  } })}\n`);
  const repositoryState = path.join(state, 'repository.json');
  const feedState = path.join(state, 'feed.json');
  fs.writeFileSync(repositoryState, `${JSON.stringify({
    channel,
    generation: options.liveGeneration ?? 1,
    snapshotId,
    sourceCommit: 'a'.repeat(40),
    version: '1.2.3',
    pointerEtag: options.liveRepositoryEtag ?? ETAGS.repository1
  })}\n`);
  if (options.currentFeed) {
    fs.writeFileSync(feedState, `${JSON.stringify({
      pointerEtag: ETAGS.feed1,
      feed: feedRecord({ channel, generation: 1, snapshotId, repositoryEtag: ETAGS.repository1, version: '1.2.2' })
    })}\n`);
  }
  installFakes(bin);
  return {
    root, releaseOut, state, log, repositoryState, feedState, snapshotId, testPublicKey, wrongPublicKey,
    cleanup: () => fs.rmSync(root, { recursive: true, force: true })
  };
}

function feedRecord({ channel = 'stable', generation, snapshotId, repositoryEtag, version }) {
  return {
    schemaVersion: 1,
    generation,
    channel,
    repository: { generation: 1, snapshotId, pointerEtag: repositoryEtag },
    version,
    sourceCommit: 'a'.repeat(40),
    feed: {
      key: `linux/releases/linux-v${version}/latest-linux.json`,
      signatureKey: `linux/releases/linux-v${version}/latest-linux.json.ed25519.sig`,
      sha256: 'b'.repeat(64), size: 1, signatureSha256: 'c'.repeat(64), signatureSize: 1
    },
    publishedAt: '2026-07-11T00:00:00.000Z',
    previousFeed: null
  };
}

function run(value, args, environment = {}) {
  return spawnSync('bash', [script, ...args], {
    cwd: repoRoot,
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${path.join(value.root, 'bin')}:${process.env.PATH}`,
      REAL_NODE: process.execPath,
      OPENBURNBAR_LINUX_RELEASE_OUT: value.releaseOut,
      OPENBURNBAR_R2_PUBLIC_BASE_URL: 'https://downloads.burnbar.ai',
      OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN: 'activation-token-with-at-least-32-characters',
      EXPECTED_ACTIVATION_TOKEN: 'activation-token-with-at-least-32-characters',
      FAKE_REPOSITORY_STATE: value.repositoryState,
      FAKE_FEED_STATE: value.feedState,
      FAKE_REQUEST_LOG: value.log,
      FAKE_OPENSSL_PUBLIC_KEY: value.testPublicKey,
      FAKE_RACED_REPOSITORY_ETAG: ETAGS.repositoryRaced,
      FAKE_RACED_FEED_ETAG: ETAGS.feedRaced,
      ...environment
    }
  });
}

function lines(file) {
  return fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean);
}

function installFakes(bin) {
  const write = (name, source) => fs.writeFileSync(path.join(bin, name), `#!${process.execPath}\n${source}\n`, { mode: 0o755 });
  write('curl', String.raw`
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
if (process.env.OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN) process.exit(92);
const args = process.argv.slice(2);
const url = new URL(args.find((arg) => arg.startsWith('https://')));
const method = args.includes('--request') ? args[args.indexOf('--request') + 1] : 'GET';
fs.appendFileSync(process.env.FAKE_REQUEST_LOG, method + ' ' + url.pathname + url.search + '\n');
if (url.origin !== 'https://downloads.burnbar.ai') process.exit(90);
const configIndex = args.indexOf('--config');
if (url.pathname.startsWith('/linux/repository-admin/')) {
  const config = fs.readFileSync(args[configIndex + 1], 'utf8');
  if (config !== 'header = "Authorization: Bearer ' + process.env.EXPECTED_ACTIVATION_TOKEN + '"\n') process.exit(91);
}
const outputFlag = args.includes('--output') ? '--output' : '-o';
const output = args.includes(outputFlag) ? args[args.indexOf(outputFlag) + 1] : null;
const headers = args.includes('--dump-header') ? args[args.indexOf('--dump-header') + 1] : null;
const reply = (code, body, etag = null) => {
  if (output) fs.writeFileSync(output, JSON.stringify(body));
  if (headers) {
    let responseEtag = etag;
    if (process.env.FAKE_MALFORMED_ETAG_PATH === url.pathname) responseEtag = '"malformed"';
    if (process.env.FAKE_MISMATCH_ETAG_PATH === url.pathname) responseEtag = '"' + '9'.repeat(64) + '"';
    if (process.env.FAKE_OMIT_ETAG_PATH === url.pathname) responseEtag = null;
    const etagLines = responseEtag ? 'ETag: ' + responseEtag + '\r\n'
      + (process.env.FAKE_DUPLICATE_ETAG_PATH === url.pathname ? 'ETag: ' + responseEtag + '\r\n' : '') : '';
    fs.writeFileSync(headers, 'HTTP/1.1 ' + code + '\r\n' + etagLines + '\r\n');
  }
  if (args.includes('--write-out')) process.stdout.write(String(code));
  process.exit(0);
};
if (url.pathname === '/linux/repository-admin/status') {
  const state = JSON.parse(fs.readFileSync(process.env.FAKE_REPOSITORY_STATE, 'utf8'));
  reply(200, { schemaVersion: 1, status: 'active', channel: state.channel, activation: {
    channel: state.channel, generation: state.generation, snapshotId: state.snapshotId,
    sourceCommit: state.sourceCommit, version: state.version
  }, pointerEtag: state.pointerEtag }, state.pointerEtag);
}
if (url.pathname === '/linux/repository-admin/feed-status') {
  const repository = JSON.parse(fs.readFileSync(process.env.FAKE_REPOSITORY_STATE, 'utf8'));
  if (url.search !== '?channel=' + repository.channel) process.exit(93);
  if (!fs.existsSync(process.env.FAKE_FEED_STATE)) reply(404, { schemaVersion: 1, status: 'inactive' });
  const state = JSON.parse(fs.readFileSync(process.env.FAKE_FEED_STATE, 'utf8'));
  reply(200, { schemaVersion: 1, status: 'published', feed: state.feed, pointerEtag: state.pointerEtag }, state.pointerEtag);
}
if (url.pathname === '/linux/repository-admin/publish-feed') {
  const requestPath = args[args.indexOf('--data-binary') + 1].slice(1);
  const request = JSON.parse(fs.readFileSync(requestPath, 'utf8'));
  const repository = JSON.parse(fs.readFileSync(process.env.FAKE_REPOSITORY_STATE, 'utf8'));
  if (process.env.FAKE_RACE_REPOSITORY_ON_POST) repository.pointerEtag = process.env.FAKE_RACED_REPOSITORY_ETAG;
  let current = fs.existsSync(process.env.FAKE_FEED_STATE)
    ? JSON.parse(fs.readFileSync(process.env.FAKE_FEED_STATE, 'utf8')) : null;
  if (process.env.FAKE_RACE_FEED_ON_POST && current) {
    current.pointerEtag = process.env.FAKE_RACED_FEED_ETAG;
    fs.writeFileSync(process.env.FAKE_FEED_STATE, JSON.stringify(current));
  }
  if (request.repositoryPointerEtag !== repository.pointerEtag
      || request.generation !== repository.generation
      || request.snapshotId !== repository.snapshotId
      || request.expectedCurrent.generation !== (current?.feed.generation ?? null)
      || request.expectedCurrent.etag !== (current?.pointerEtag ?? null)) {
    reply(409, { error: 'compare-and-swap conflict' });
  }
  const generation = (current?.feed.generation ?? 0) + 1;
  const record = {
    schemaVersion: 1, generation, channel: request.channel,
    repository: { generation: request.generation, snapshotId: request.snapshotId, pointerEtag: request.repositoryPointerEtag },
    version: request.version, sourceCommit: request.sourceCommit, feed: request.feed,
    publishedAt: '2026-07-11T01:00:00.000Z',
    previousFeed: current ? {
      channel: current.feed.channel,
      version: current.feed.version,
      sourceCommit: current.feed.sourceCommit,
      feed: current.feed.feed,
      publishedAt: current.feed.publishedAt
    } : null
  };
  const pointerEtag = '"' + (200 + generation).toString(16).padStart(64, '0') + '"';
  fs.writeFileSync(process.env.FAKE_FEED_STATE, JSON.stringify({ pointerEtag, feed: record }));
  reply(200, { schemaVersion: 1, status: 'published', feed: record, pointerEtag }, pointerEtag);
}
if (/^(?:\/latest-linux\.json|\/linux\/update\/(?:stable|prerelease|nightly)\/latest-linux\.json)(?:\.ed25519\.sig)?$/.test(url.pathname)) {
  if (process.env.FAKE_FEED_ROUTE_ENABLED !== '1') process.exit(22);
  const release = process.env.OPENBURNBAR_LINUX_RELEASE_OUT;
  const source = url.pathname.endsWith('.sig')
    ? path.join(release, 'sidecars/latest-linux.json.ed25519.sig')
    : path.join(release, 'latest-linux.draft.json');
  fs.copyFileSync(source, output);
  if (headers) {
    const repository = JSON.parse(fs.readFileSync(process.env.FAKE_REPOSITORY_STATE, 'utf8'));
    const feed = JSON.parse(fs.readFileSync(process.env.FAKE_FEED_STATE, 'utf8'));
    const snapshot = process.env.FAKE_MISMATCH_PUBLIC_SNAPSHOT ? '9'.repeat(64) : repository.snapshotId;
    const generation = process.env.FAKE_MALFORMED_PUBLIC_FEED_GENERATION ? 'not-a-generation'
      : process.env.FAKE_MISMATCH_PUBLIC_FEED_GENERATION
        ? String(feed.feed.generation + 1) : String(feed.feed.generation);
    const routing = process.env.FAKE_OMIT_PUBLIC_ROUTING_HEADERS ? ''
      : 'X-OpenBurnBar-Repository-Snapshot: ' + snapshot + '\r\n'
        + 'X-OpenBurnBar-Feed-Generation: ' + generation + '\r\n'
        + (process.env.FAKE_DUPLICATE_PUBLIC_ROUTING_HEADERS
          ? 'X-OpenBurnBar-Feed-Generation: ' + generation + '\r\n' : '');
    fs.writeFileSync(headers, 'HTTP/1.1 200 OK\r\n' + routing + '\r\n');
  }
  process.exit(0);
}
process.exit(99);
`);
  write('openssl', String.raw`
const crypto = require('node:crypto');
const fs = require('node:fs');
if (process.env.OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN) process.exit(92);
const args = process.argv.slice(2);
if (args[0] !== 'pkeyutl' || !args.includes('-verify') || !args.includes('-pubin') || !args.includes('-rawin')) {
  process.exit(90);
}
const input = args[args.indexOf('-in') + 1];
const signature = args[args.indexOf('-sigfile') + 1];
if (!input || !signature || !process.env.FAKE_OPENSSL_PUBLIC_KEY) process.exit(91);
const valid = crypto.verify(null, fs.readFileSync(input), fs.readFileSync(process.env.FAKE_OPENSSL_PUBLIC_KEY),
  fs.readFileSync(signature));
process.exit(valid ? 0 : 1);
`);
  fs.writeFileSync(path.join(bin, 'node'), `#!/usr/bin/env bash
set -euo pipefail
if [[ -n "\${OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN:-}" ]]; then exit 92; fi
if [[ "\${1:-}" == *check-linux-update-feed.mjs ]]; then exit 0; fi
exec "$REAL_NODE" "$@"
`, { mode: 0o755 });
}
