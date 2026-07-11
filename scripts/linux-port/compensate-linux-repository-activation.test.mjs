import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { compensateLinuxRepositoryActivation, writeAtomicJson } from './compensate-linux-repository-activation.mjs';

const ETAGS = {
  candidate: `"${'b'.repeat(64)}"`,
  prior: `"${'a'.repeat(64)}"`,
  raced: `"${'c'.repeat(64)}"`,
  inactive: `"${'d'.repeat(64)}"`,
  feed: `"${'e'.repeat(64)}"`,
  rebound: `"${'f'.repeat(64)}"`
};
const candidate = { channel: 'stable', snapshotId: 'b'.repeat(64), version: '2.0.0', sourceCommit: 'b'.repeat(40) };
const previous = { channel: 'stable', snapshotId: 'a'.repeat(64), version: '1.0.0', sourceCommit: 'a'.repeat(40) };

function fixture(receipt = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-compensation-v4-'));
  const activationReceiptPath = path.join(root, 'activation.json');
  fs.writeFileSync(activationReceiptPath, `${JSON.stringify(receipt)}\n`);
  return { root, activationReceiptPath };
}

function attemptedReceipt(withPrevious = true) {
  return {
    mutationAttempted: true,
    phase: 'attempted',
    candidate,
    request: {
      channel: candidate.channel,
      targetSnapshotId: candidate.snapshotId,
      version: candidate.version,
      sourceCommit: candidate.sourceCommit
    },
    status: { active: withPrevious ? previous : null }
  };
}

function options(value) {
  return {
    activationReceiptPath: value.activationReceiptPath,
    baseUrl: 'http://127.0.0.1:9000',
    allowLocalTestOrigin: true,
    token: 'x'.repeat(32),
    actor: 'release-engineer',
    runUrl: null
  };
}

function activeStatus(active, generation, etag, previousSnapshotId = null) {
  return new Response(JSON.stringify({
    schemaVersion: 1,
    status: 'active',
    channel: active.channel,
    activation: { ...active, generation, previousSnapshotId },
    pointerEtag: etag
  }), { status: 200, headers: { 'Content-Type': 'application/json', ETag: etag } });
}

function inactiveStatus(record = null, etag = null) {
  const body = { schemaVersion: 1, status: 'inactive', channel: 'stable' };
  if (record) {
    body.deactivation = record;
    body.pointerEtag = etag;
  }
  return new Response(JSON.stringify(body), {
    status: 404,
    headers: { 'Content-Type': 'application/json', ...(etag ? { ETag: etag } : {}) }
  });
}

function deactivation(fallbackMode, generation = 3) {
  return {
    schemaVersion: 1,
    status: 'inactive',
    channel: 'stable',
    generation,
    previousSnapshotId: candidate.snapshotId,
    previousVersion: candidate.version,
    previousSourceCommit: candidate.sourceCommit,
    fallbackMode,
    deactivatedAt: '2026-07-11T01:00:00.000Z',
    actor: 'release-engineer',
    runUrl: null,
    reason: 'Compensation deactivated candidate'
  };
}

function publicResponse(status, snapshotId = null, feedGeneration = '7') {
  return new Response(null, {
    status,
    headers: snapshotId ? {
      'X-OpenBurnBar-Repository-Snapshot': snapshotId,
      'X-OpenBurnBar-Feed-Generation': feedGeneration
    } : {}
  });
}

function descriptor(value) {
  return {
    channel: value.channel,
    version: value.version,
    sourceCommit: value.sourceCommit,
    feed: {
      key: `linux/releases/linux-v${value.version}/latest-linux-${value.channel}.json`,
      signatureKey: `linux/releases/linux-v${value.version}/latest-linux-${value.channel}.json.ed25519.sig`,
      sha256: '1'.repeat(64),
      size: 100,
      signatureSha256: '2'.repeat(64),
      signatureSize: 64
    },
    publishedAt: '2026-07-11T00:00:00.000Z'
  };
}

function feedRecord(value, repository, generation = 7, previousFeed = null) {
  return {
    schemaVersion: 1,
    generation,
    ...descriptor(value),
    repository,
    previousFeed
  };
}

function feedStatus(record, etag) {
  return new Response(JSON.stringify({
    schemaVersion: 1,
    status: 'published',
    feed: record,
    pointerEtag: etag
  }), { status: 200, headers: { 'Content-Type': 'application/json', ETag: etag } });
}

function noFeedStatus() {
  return new Response(JSON.stringify({ schemaVersion: 1, status: 'inactive' }), {
    status: 404,
    headers: { 'Content-Type': 'application/json' }
  });
}

async function runPrereleaseFirstCutover(t, feedHttpStatus) {
  const prereleaseCandidate = { ...candidate, channel: 'prerelease' };
  const value = fixture({
    mutationAttempted: true,
    phase: 'attempted',
    candidate: prereleaseCandidate,
    request: {
      channel: prereleaseCandidate.channel,
      targetSnapshotId: prereleaseCandidate.snapshotId,
      version: prereleaseCandidate.version,
      sourceCommit: prereleaseCandidate.sourceCommit
    },
    status: { active: null }
  });
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let inactive = false;
  const feedPaths = [];
  const record = { ...deactivation('legacy-direct-r2', 2), channel: 'prerelease' };
  const result = await compensateLinuxRepositoryActivation(options(value), async (url, request = {}) => {
    const pathname = new URL(url).pathname;
    if (pathname.endsWith('/status')) {
      if (!inactive) return activeStatus(prereleaseCandidate, 1, ETAGS.candidate);
      return new Response(JSON.stringify({
        schemaVersion: 1,
        status: 'inactive',
        channel: 'prerelease',
        deactivation: record,
        pointerEtag: ETAGS.inactive
      }), { status: 404, headers: { 'Content-Type': 'application/json', ETag: ETAGS.inactive } });
    }
    if (pathname.endsWith('/deactivate')) {
      inactive = true;
      return new Response('{}', { status: 200 });
    }
    if (request.method === 'HEAD') {
      if (pathname.startsWith('/linux/update/')) {
        feedPaths.push(pathname);
        return publicResponse(feedHttpStatus);
      }
      return publicResponse(404);
    }
    throw new Error(`unexpected request ${pathname}`);
  });
  return { result, feedPaths };
}

test('missing and explicitly not-attempted activation receipts pass without validation or network access', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-no-compensation-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const missing = path.join(root, 'missing.json');
  const planned = path.join(root, 'planned.json');
  fs.writeFileSync(planned, `${JSON.stringify({ phase: 'planned', mutationAttempted: false, candidate })}\n`);
  let calls = 0;
  for (const activationReceiptPath of [missing, planned]) {
    const result = await compensateLinuxRepositoryActivation({ activationReceiptPath }, async () => { calls += 1; });
    assert.equal(result.passed, true);
    assert.equal(result.contained, true);
    assert.equal(result.sourceMutationAttempted, false);
    assert.equal(result.mutationAttempted, false);
    assert.match(result.strategy, /missing-receipt|proven-not-attempted/u);
  }
  assert.equal(calls, 0);
});

test('contradictory planned receipt that claims a mutation is rejected without network access', async (t) => {
  const value = fixture({ phase: 'planned', mutationAttempted: true, candidate });
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let calls = 0;
  const result = await compensateLinuxRepositoryActivation(options(value), async () => { calls += 1; });
  assert.equal(result.passed, false);
  assert.equal(result.contained, false);
  assert.equal(calls, 0);
  assert.match(result.failures.join('\n'), /contradictory/u);
});

test('ambiguous receipt identity resolves result.activation before candidate and request, then proves no commit', async (t) => {
  const value = fixture({
    status: { active: null },
    result: { activation: candidate },
    candidate: { bad: true },
    request: { bad: true }
  });
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const result = await compensateLinuxRepositoryActivation(options(value), async (url, request = {}) => {
    const pathname = new URL(url).pathname;
    if (pathname.includes('repository-admin/status')) return inactiveStatus();
    if (request.method === 'HEAD' && pathname.startsWith('/latest-linux')) {
      return publicResponse(pathname.endsWith('.sig') ? 404 : 200);
    }
    throw new Error(`unexpected request ${pathname}`);
  });
  assert.equal(result.passed, true);
  assert.equal(result.strategy, 'activation-not-committed');
  assert.deepEqual(result.candidate, candidate);
  assert.equal(result.mutationAttempted, false);
  assert.equal(result.attempts.length, 1);
});

test('ambiguous attempted receipt derives candidate from request when no stronger identity exists', async (t) => {
  const value = fixture({ status: { active: null }, request: {
    channel: candidate.channel,
    targetSnapshotId: candidate.snapshotId,
    version: candidate.version,
    sourceCommit: candidate.sourceCommit
  } });
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const result = await compensateLinuxRepositoryActivation(options(value), async (url, request = {}) => {
    const pathname = new URL(url).pathname;
    if (pathname.includes('repository-admin/status')) return inactiveStatus();
    if (request.method === 'HEAD') return publicResponse(503);
    throw new Error(`unexpected request ${pathname}`);
  });
  assert.equal(result.passed, true);
  assert.deepEqual(result.candidate, candidate);
});

test('rollback uses fresh repository CAS and rebinds the retained previous feed with exact CAS', async (t) => {
  const value = fixture(attemptedReceipt());
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let repository = { active: candidate, generation: 2, etag: ETAGS.candidate };
  let feed = feedRecord(candidate, {
    generation: 2,
    snapshotId: candidate.snapshotId,
    pointerEtag: ETAGS.candidate
  }, 7, descriptor(previous));
  let feedEtag = ETAGS.feed;
  let rollbackRequest;
  let rebindRequest;
  const result = await compensateLinuxRepositoryActivation(options(value), async (url, request = {}) => {
    const pathname = new URL(url).pathname;
    if (pathname.endsWith('/status')) return activeStatus(repository.active, repository.generation, repository.etag);
    if (pathname.endsWith('/activate')) {
      rollbackRequest = JSON.parse(request.body);
      repository = { active: previous, generation: 3, etag: ETAGS.prior };
      return new Response(JSON.stringify({ schemaVersion: 1, status: 'activated' }), { status: 200 });
    }
    if (pathname.endsWith('/feed-status')) return feedStatus(feed, feedEtag);
    if (pathname.endsWith('/rebind-feed')) {
      rebindRequest = JSON.parse(request.body);
      feed = feedRecord(previous, {
        generation: 3,
        snapshotId: previous.snapshotId,
        pointerEtag: ETAGS.prior
      }, 8, descriptor(candidate));
      feedEtag = ETAGS.rebound;
      return new Response(JSON.stringify({ schemaVersion: 1, status: 'rebound' }), { status: 200 });
    }
    if (request.method === 'HEAD' && pathname.startsWith('/latest-linux')) {
      return publicResponse(200, previous.snapshotId, '8');
    }
    if (request.method === 'HEAD') return publicResponse(200, previous.snapshotId, '8');
    throw new Error(`unexpected request ${pathname}`);
  });
  assert.equal(result.passed, true);
  assert.equal(result.strategy, 'rollback');
  assert.equal(result.feedRestoration, 'previous');
  assert.equal(rollbackRequest.expectedCurrentGeneration, 2);
  assert.equal(rollbackRequest.expectedCurrentPointerEtag, ETAGS.candidate);
  assert.deepEqual(rebindRequest, {
    schemaVersion: 1,
    channel: 'stable',
    target: 'previous',
    expectedCurrent: { generation: 7, etag: ETAGS.feed },
    expectedRepository: { generation: 3, snapshotId: previous.snapshotId, pointerEtag: ETAGS.prior },
    actor: 'release-engineer',
    runUrl: null,
    reason: `Restore Linux update feed after repository compensation ${candidate.snapshotId}`
  });
});

test('rollback failure with candidate still active uses a fresh-CAS deactivation and proves disabled roots', async (t) => {
  const value = fixture(attemptedReceipt());
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let phase = 'candidate';
  let fallbackRequest;
  const result = await compensateLinuxRepositoryActivation(options(value), async (url, request = {}) => {
    const pathname = new URL(url).pathname;
    if (pathname.endsWith('/status')) {
      if (phase === 'inactive') return inactiveStatus(deactivation('disabled', 4), ETAGS.inactive);
      return activeStatus(candidate, phase === 'candidate' ? 2 : 3, phase === 'candidate' ? ETAGS.candidate : ETAGS.raced);
    }
    if (pathname.endsWith('/activate')) {
      phase = 'raced-candidate';
      return new Response('retained previous expired', { status: 409 });
    }
    if (pathname.endsWith('/deactivate')) {
      fallbackRequest = JSON.parse(request.body);
      phase = 'inactive';
      return new Response(JSON.stringify({ schemaVersion: 1, status: 'inactive' }), { status: 200 });
    }
    if (request.method === 'HEAD') return publicResponse(503);
    throw new Error(`unexpected request ${pathname}`);
  });
  assert.equal(result.passed, true);
  assert.equal(result.strategy, 'rollback-fallback-deactivate');
  assert.equal(fallbackRequest.expectedCurrentGeneration, 3);
  assert.equal(fallbackRequest.expectedCurrentPointerEtag, ETAGS.raced);
  assert.equal(result.attempts.filter((attempt) => attempt.operation === 'verify-public-root'
    && attempt.expectedState === 'disabled').length, 5);
});

test('first activation deactivation verifies legacy direct-R2 roots as 200 or 404 without snapshot headers', async (t) => {
  const value = fixture(attemptedReceipt(false));
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let inactive = false;
  let heads = 0;
  let deactivateRequest;
  const result = await compensateLinuxRepositoryActivation(options(value), async (url, request = {}) => {
    const pathname = new URL(url).pathname;
    if (pathname.endsWith('/status')) {
      return inactive
        ? inactiveStatus(deactivation('legacy-direct-r2', 2), ETAGS.inactive)
        : activeStatus(candidate, 1, ETAGS.candidate);
    }
    if (pathname.endsWith('/deactivate')) {
      deactivateRequest = JSON.parse(request.body);
      inactive = true;
      return new Response(JSON.stringify({ schemaVersion: 1, status: 'inactive' }), { status: 200 });
    }
    if (request.method === 'HEAD' && pathname.startsWith('/latest-linux')) {
      return publicResponse(pathname.endsWith('.sig') ? 404 : 200);
    }
    if (request.method === 'HEAD') return publicResponse((heads++ % 2) === 0 ? 200 : 404);
    throw new Error(`unexpected request ${pathname}`);
  });
  assert.equal(result.passed, true, result.failures.join('\n'));
  assert.equal(result.strategy, 'deactivate');
  assert.equal(deactivateRequest.expectedCurrentGeneration, 1);
  assert.equal(deactivateRequest.expectedCurrentPointerEtag, ETAGS.candidate);
  assert.equal(result.attempts.filter((attempt) => attempt.operation === 'verify-public-root'
    && attempt.expectedState === 'legacy-direct-r2').length, 5);
  assert.equal(result.attempts.filter((attempt) => attempt.operation === 'verify-public-feed'
    && attempt.expectedState === 'legacy-direct-r2').length, 2);
});

test('prerelease first-cutover compensation verifies only its channel-qualified feed roots', async (t) => {
  const { result, feedPaths } = await runPrereleaseFirstCutover(t, 404);
  assert.equal(result.passed, true, result.failures.join('\n'));
  assert.deepEqual(feedPaths, [
    '/linux/update/prerelease/latest-linux.json',
    '/linux/update/prerelease/latest-linux.json.ed25519.sig'
  ]);
});

test('prerelease first-cutover compensation rejects a stray headerless feed object', async (t) => {
  const { result } = await runPrereleaseFirstCutover(t, 200);
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /public Linux feed did not prove legacy-direct-r2 containment/u);
});

test('first activation deactivation CAS race is accepted only after legacy fallback reconciliation', async (t) => {
  const value = fixture(attemptedReceipt(false));
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let inactive = false;
  const result = await compensateLinuxRepositoryActivation(options(value), async (url, request = {}) => {
    const pathname = new URL(url).pathname;
    if (pathname.endsWith('/status')) return inactive
      ? inactiveStatus(deactivation('legacy-direct-r2', 2), ETAGS.inactive)
      : activeStatus(candidate, 1, ETAGS.candidate);
    if (pathname.endsWith('/deactivate')) {
      inactive = true;
      return new Response('concurrent deactivation won', { status: 409 });
    }
    if (request.method === 'HEAD' && pathname.startsWith('/latest-linux')) return publicResponse(404);
    if (request.method === 'HEAD') return publicResponse(404);
    throw new Error(`unexpected request ${pathname}`);
  });
  assert.equal(result.passed, true);
  assert.equal(result.attempts.find((attempt) => attempt.operation === 'deactivate').httpStatus, 409);
});

test('candidate authenticated as first generation rejects disabled fallback after deactivation', async (t) => {
  const value = fixture(attemptedReceipt(false));
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let inactive = false;
  const result = await compensateLinuxRepositoryActivation(options(value), async (url, request = {}) => {
    const pathname = new URL(url).pathname;
    if (pathname.endsWith('/status')) return inactive
      ? inactiveStatus(deactivation('disabled', 2), ETAGS.inactive)
      : activeStatus(candidate, 1, ETAGS.candidate, null);
    if (pathname.endsWith('/deactivate')) {
      inactive = true;
      return new Response('{}', { status: 200 });
    }
    if (request.method === 'HEAD') return publicResponse(503);
    throw new Error(`unexpected request ${pathname}`);
  });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /expected legacy-direct-r2/u);
});

test('ambiguous replacement activation derives disabled fallback from authenticated previousSnapshotId', async (t) => {
  const value = fixture({ mutationAttempted: true, candidate, status: { active: null } });
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const retainedUnknown = '8'.repeat(64);
  let inactive = false;
  const result = await compensateLinuxRepositoryActivation(options(value), async (url, request = {}) => {
    const pathname = new URL(url).pathname;
    if (pathname.endsWith('/status')) return inactive
      ? inactiveStatus(deactivation('disabled', 5), ETAGS.inactive)
      : activeStatus(candidate, 4, ETAGS.candidate, retainedUnknown);
    if (pathname.endsWith('/deactivate')) {
      const body = JSON.parse(request.body);
      assert.equal(body.expectedCurrentGeneration, 4);
      assert.equal(body.expectedCurrentPointerEtag, ETAGS.candidate);
      inactive = true;
      return new Response('{}', { status: 200 });
    }
    if (request.method === 'HEAD') return publicResponse(503);
    throw new Error(`unexpected request ${pathname}`);
  });
  assert.equal(result.passed, true);
  assert.equal(result.expectedFallbackMode, 'disabled');
  assert.equal(result.attempts.filter((attempt) => attempt.operation === 'verify-public-root'
    && attempt.expectedState === 'disabled').length, 5);
});

test('an already-restored repository rebinds a matching current feed descriptor with exact CAS', async (t) => {
  const value = fixture(attemptedReceipt());
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let feed = feedRecord(previous, {
    generation: 2,
    snapshotId: candidate.snapshotId,
    pointerEtag: ETAGS.candidate
  }, 7, null);
  let feedEtag = ETAGS.feed;
  let requestBody;
  const result = await compensateLinuxRepositoryActivation(options(value), async (url, request = {}) => {
    const pathname = new URL(url).pathname;
    if (pathname.endsWith('/status')) return activeStatus(previous, 3, ETAGS.prior);
    if (pathname.endsWith('/feed-status')) return feedStatus(feed, feedEtag);
    if (pathname.endsWith('/rebind-feed')) {
      requestBody = JSON.parse(request.body);
      feed = feedRecord(previous, {
        generation: 3,
        snapshotId: previous.snapshotId,
        pointerEtag: ETAGS.prior
      }, 8, null);
      feedEtag = ETAGS.rebound;
      return new Response('{}', { status: 200 });
    }
    if (request.method === 'HEAD') return publicResponse(200, previous.snapshotId, '8');
    throw new Error(`unexpected request ${pathname}`);
  });
  assert.equal(result.passed, true);
  assert.equal(result.strategy, 'already-rolled-back');
  assert.equal(result.feedRestoration, 'current');
  assert.equal(requestBody.target, 'current');
  assert.deepEqual(requestBody.expectedCurrent, { generation: 7, etag: ETAGS.feed });
});

test('feed rebind CAS race passes only when authenticated reconciliation proves the restored binding', async (t) => {
  const value = fixture(attemptedReceipt());
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let repository = candidate;
  let feed = feedRecord(candidate, { generation: 2, snapshotId: candidate.snapshotId, pointerEtag: ETAGS.candidate },
    7, descriptor(previous));
  let feedEtag = ETAGS.feed;
  const result = await compensateLinuxRepositoryActivation(options(value), async (url, request = {}) => {
    const pathname = new URL(url).pathname;
    if (pathname.endsWith('/status')) return activeStatus(repository, repository === candidate ? 2 : 3,
      repository === candidate ? ETAGS.candidate : ETAGS.prior);
    if (pathname.endsWith('/activate')) {
      repository = previous;
      return new Response('{}', { status: 200 });
    }
    if (pathname.endsWith('/feed-status')) return feedStatus(feed, feedEtag);
    if (pathname.endsWith('/rebind-feed')) {
      feed = feedRecord(previous, { generation: 3, snapshotId: previous.snapshotId, pointerEtag: ETAGS.prior }, 8,
        descriptor(candidate));
      feedEtag = ETAGS.rebound;
      return new Response('concurrent winner', { status: 409 });
    }
    if (request.method === 'HEAD') return publicResponse(200, previous.snapshotId, '8');
    throw new Error(`unexpected request ${pathname}`);
  });
  assert.equal(result.passed, true);
  assert.equal(result.feedRestoration, 'previous');
  assert.equal(result.attempts.find((attempt) => attempt.operation === 'rebind-feed').httpStatus, 409);
});

test('rollback with no retained feed pointer treats it as nothing to restore without probing public feed roots', async (t) => {
  const value = fixture(attemptedReceipt());
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let repository = candidate;
  let feedHeadCalls = 0;
  const result = await compensateLinuxRepositoryActivation(options(value), async (url, request = {}) => {
    const pathname = new URL(url).pathname;
    if (pathname.endsWith('/status')) return activeStatus(repository, repository === candidate ? 2 : 3,
      repository === candidate ? ETAGS.candidate : ETAGS.prior);
    if (pathname.endsWith('/activate')) {
      repository = previous;
      return new Response('{}', { status: 200 });
    }
    if (pathname.endsWith('/feed-status')) return noFeedStatus();
    if (request.method === 'HEAD' && pathname.startsWith('/latest-linux')) {
      feedHeadCalls += 1;
      return publicResponse(503);
    }
    if (request.method === 'HEAD') return publicResponse(200, previous.snapshotId);
    throw new Error(`unexpected request ${pathname}`);
  });
  assert.equal(result.passed, true);
  assert.equal(result.feedRestoration, 'no-feed-pointer');
  assert.equal(result.attempts.some((attempt) => attempt.operation === 'rebind-feed'), false);
  assert.equal(feedHeadCalls, 0);
});

test('active containment fails when the repository pointer changes during the status-feed-public-status sandwich', async (t) => {
  const value = fixture(attemptedReceipt());
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let repository = candidate;
  let restoredStatusCalls = 0;
  const result = await compensateLinuxRepositoryActivation(options(value), async (url, request = {}) => {
    const pathname = new URL(url).pathname;
    if (pathname.endsWith('/status')) {
      if (repository === candidate) return activeStatus(candidate, 2, ETAGS.candidate, previous.snapshotId);
      restoredStatusCalls += 1;
      return restoredStatusCalls < 3
        ? activeStatus(previous, 3, ETAGS.prior, candidate.snapshotId)
        : activeStatus(previous, 4, ETAGS.raced, candidate.snapshotId);
    }
    if (pathname.endsWith('/activate')) {
      repository = previous;
      return new Response('{}', { status: 200 });
    }
    if (pathname.endsWith('/feed-status')) return noFeedStatus();
    if (request.method === 'HEAD') return publicResponse(200, previous.snapshotId);
    throw new Error(`unexpected request ${pathname}`);
  });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /changed during public compensation verification/u);
});

test('inactive containment fails when a concurrent tombstone swaps fallback mode during public verification', async (t) => {
  const value = fixture(attemptedReceipt(false));
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let inactive = false;
  let inactiveStatusCalls = 0;
  const result = await compensateLinuxRepositoryActivation(options(value), async (url, request = {}) => {
    const pathname = new URL(url).pathname;
    if (pathname.endsWith('/status')) {
      if (!inactive) return activeStatus(candidate, 1, ETAGS.candidate, null);
      inactiveStatusCalls += 1;
      return inactiveStatusCalls < 3
        ? inactiveStatus(deactivation('legacy-direct-r2', 2), ETAGS.inactive)
        : inactiveStatus(deactivation('disabled', 3), ETAGS.raced);
    }
    if (pathname.endsWith('/deactivate')) {
      inactive = true;
      return new Response('{}', { status: 200 });
    }
    if (request.method === 'HEAD' && pathname.startsWith('/latest-linux')) return publicResponse(404);
    if (request.method === 'HEAD') return publicResponse(404);
    throw new Error(`unexpected request ${pathname}`);
  });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /deactivation changed during public compensation verification/u);
});

test('unrelated live activation is never mutated', async (t) => {
  const value = fixture(attemptedReceipt());
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const unrelated = { ...candidate, snapshotId: '9'.repeat(64), version: '3.0.0' };
  let posts = 0;
  const result = await compensateLinuxRepositoryActivation(options(value), async (_url, request = {}) => {
    if (request.method === 'POST') posts += 1;
    return activeStatus(unrelated, 4, ETAGS.raced);
  });
  assert.equal(result.passed, false);
  assert.equal(result.strategy, 'unrelated-current');
  assert.equal(posts, 0);
});

test('atomic receipt writer replaces a destination without leaving staging files', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-compensation-receipt-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const output = path.join(root, 'nested', 'result.json');
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, '{}\n');
  writeAtomicJson(output, { passed: false, contained: false });
  assert.deepEqual(JSON.parse(fs.readFileSync(output, 'utf8')), { passed: false, contained: false });
  assert.deepEqual(fs.readdirSync(path.dirname(output)), ['result.json']);
});

test('compensation CLI atomically emits a passing receipt when activation was proven not attempted', (t) => {
  const value = fixture({ phase: 'planned', mutationAttempted: false, candidate });
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const output = path.join(value.root, 'compensation-result.json');
  const result = spawnSync(process.execPath, [path.resolve('scripts/linux-port/compensate-linux-repository-activation.mjs')], {
    cwd: path.resolve('.'),
    encoding: 'utf8',
    env: {
      ...process.env,
      OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_RECEIPT: value.activationReceiptPath,
      OPENBURNBAR_LINUX_REPOSITORY_COMPENSATION_RECEIPT: output
    }
  });
  assert.equal(result.status, 0, result.stderr);
  const receipt = JSON.parse(fs.readFileSync(output, 'utf8'));
  assert.equal(receipt.passed, true);
  assert.equal(receipt.mutationAttempted, false);
  assert.deepEqual(fs.readdirSync(value.root).sort(), ['activation.json', 'compensation-result.json']);
});

test('compensation CLI atomically emits a non-passing receipt on attempted-recovery setup failure', (t) => {
  const value = fixture(attemptedReceipt());
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const output = path.join(value.root, 'compensation-result.json');
  const result = spawnSync(process.execPath, [path.resolve('scripts/linux-port/compensate-linux-repository-activation.mjs')], {
    cwd: path.resolve('.'),
    encoding: 'utf8',
    env: {
      ...process.env,
      OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_RECEIPT: value.activationReceiptPath,
      OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN: 'x'.repeat(32),
      OPENBURNBAR_R2_PUBLIC_BASE_URL: 'https://downloads.burnbar.ai.invalid',
      OPENBURNBAR_LINUX_REPOSITORY_COMPENSATION_RECEIPT: output
    }
  });
  assert.notEqual(result.status, 0);
  const receipt = JSON.parse(fs.readFileSync(output, 'utf8'));
  assert.equal(receipt.passed, false);
  assert.equal(receipt.contained, false);
  assert.match(receipt.failures.join('\n'), /must use https:\/\/downloads\.burnbar\.ai/u);
  assert.deepEqual(fs.readdirSync(value.root).sort(), ['activation.json', 'compensation-result.json']);
});
