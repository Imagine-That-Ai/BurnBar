import assert from 'node:assert/strict';
import test from 'node:test';
import { rebindLinuxRepositoryFeed } from './rebind-linux-repository-feed.mjs';

const CHANNEL = 'stable';
const SNAPSHOT = 'a'.repeat(64);
const OLD_SNAPSHOT = 'b'.repeat(64);
const REPOSITORY_ETAG = `"${'c'.repeat(32)}"`;
const FEED_ETAG = `"${'d'.repeat(32)}"`;
const NEXT_FEED_ETAG = `"${'e'.repeat(32)}"`;

function service(options = {}) {
  const repository = {
    schemaVersion: 1,
    status: 'active',
    channel: CHANNEL,
    pointerEtag: REPOSITORY_ETAG,
    activation: {
      channel: CHANNEL,
      generation: 8,
      snapshotId: SNAPSHOT,
      version: '1.2.3',
      sourceCommit: 'f'.repeat(40)
    }
  };
  let feed = {
    schemaVersion: 1,
    status: 'published',
    channel: CHANNEL,
    pointerEtag: FEED_ETAG,
    feed: {
      schemaVersion: 1,
      generation: 5,
      channel: CHANNEL,
      repository: { generation: 7, snapshotId: OLD_SNAPSHOT, pointerEtag: `"${'9'.repeat(32)}"` },
      version: '1.2.3',
      sourceCommit: 'f'.repeat(40),
      feed: { key: 'linux/releases/linux-v1.2.3/latest-linux.json', sha256: '1'.repeat(64) },
      publishedAt: '2026-07-10T00:00:00.000Z',
      previousFeed: null
    }
  };
  let repositoryReads = 0;
  const requests = [];
  const fetchImpl = async (url, init = {}) => {
    const pathname = new URL(url).pathname;
    requests.push({ pathname, method: init.method ?? 'GET', body: init.body ? JSON.parse(init.body) : null });
    if (pathname.endsWith('/status')) {
      repositoryReads += 1;
      if (options.repositoryRace && repositoryReads === 2) {
        const racedEtag = `"${'7'.repeat(32)}"`;
        return new Response(JSON.stringify({
          ...repository,
          pointerEtag: racedEtag,
          activation: { ...repository.activation, generation: 9, snapshotId: '8'.repeat(64) }
        }), { status: 200, headers: { ETag: racedEtag } });
      }
      return new Response(JSON.stringify(repository), { status: 200, headers: { ETag: REPOSITORY_ETAG } });
    }
    if (pathname.endsWith('/feed-status')) {
      return new Response(JSON.stringify(feed), { status: 200, headers: { ETag: feed.pointerEtag } });
    }
    if (pathname.endsWith('/rebind-feed')) {
      feed = {
        ...feed,
        pointerEtag: NEXT_FEED_ETAG,
        feed: {
          ...feed.feed,
          generation: 6,
          repository: { generation: 8, snapshotId: SNAPSHOT, pointerEtag: REPOSITORY_ETAG }
        }
      };
      if (options.ambiguous) throw new Error('connection reset after request write');
      return new Response(JSON.stringify({ schemaVersion: 1, status: 'rebound' }), { status: 200 });
    }
    return new Response('not found', { status: 404 });
  };
  return { fetchImpl, requests, get feed() { return feed; } };
}

function options() {
  return {
    channel: CHANNEL,
    target: 'current',
    token: 'x'.repeat(32),
    baseUrl: 'http://localhost:8123',
    allowLocalTestOrigin: true,
    actor: 'release-bot',
    runUrl: null,
    reason: 'Rebind retained feed after repository metadata refresh'
  };
}

test('feed rebind uses exact repository/feed CAS and preserves the signed feed identity', async () => {
  const value = service();
  const result = await rebindLinuxRepositoryFeed(options(), value.fetchImpl);
  assert.equal(result.passed, true);
  assert.equal(result.mutationAttempted, true);
  assert.equal(result.reconciledAfterError, false);
  const request = value.requests.find((row) => row.pathname.endsWith('/rebind-feed')).body;
  assert.deepEqual(request.expectedCurrent, { generation: 5, etag: FEED_ETAG });
  assert.deepEqual(request.expectedRepository, {
    generation: 8,
    snapshotId: SNAPSHOT,
    pointerEtag: REPOSITORY_ETAG
  });
  assert.equal(result.before.feed.record.feed.sha256, result.after.feed.record.feed.sha256);
  assert.equal(result.after.feed.record.repository.snapshotId, SNAPSHOT);
});

test('feed rebind reconciles an ambiguous response only after exact authenticated status proof', async () => {
  const value = service({ ambiguous: true });
  const result = await rebindLinuxRepositoryFeed(options(), value.fetchImpl);
  assert.equal(result.passed, true);
  assert.equal(result.reconciledAfterError, true);
  assert.equal(result.after.feed.record.repository.pointerEtag, REPOSITORY_ETAG);
});

test('feed rebind is idempotent when the current descriptor already binds the active repository', async () => {
  const value = service();
  await rebindLinuxRepositoryFeed(options(), value.fetchImpl);
  const result = await rebindLinuxRepositoryFeed(options(), value.fetchImpl);
  assert.equal(result.alreadyBound, true);
  assert.equal(result.mutationAttempted, false);
  assert.equal(value.requests.filter((row) => row.pathname.endsWith('/rebind-feed')).length, 1);
});

test('feed rebind rejects a torn repository and feed status observation before mutation', async () => {
  const value = service({ repositoryRace: true });
  await assert.rejects(rebindLinuxRepositoryFeed(options(), value.fetchImpl), /changed during feed status/u);
  assert.equal(value.requests.some((row) => row.pathname.endsWith('/rebind-feed')), false);
});
