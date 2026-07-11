import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { drillLinuxRepositoryRollback } from './drill-linux-repository-rollback.mjs';

function fixture(withPrevious = true) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-rollback-drill-'));
  const closurePath = path.join(root, 'repository-closure.json');
  fs.writeFileSync(closurePath, `${JSON.stringify({ schemaVersion: 1, channel: 'stable', version: '2.0.0', gitCommit: 'b'.repeat(40) })}\n`);
  const snapshotId = crypto.createHash('sha256').update(fs.readFileSync(closurePath)).digest('hex');
  const candidate = { channel: 'stable', snapshotId, version: '2.0.0', sourceCommit: 'b'.repeat(40) };
  const previous = withPrevious
    ? { channel: 'stable', snapshotId: 'a'.repeat(64), version: '1.0.0', sourceCommit: 'a'.repeat(40) } : null;
  const activationReceiptPath = path.join(root, 'repository-activation.json');
  fs.writeFileSync(activationReceiptPath, `${JSON.stringify({ status: { active: previous }, result: { activation: candidate } })}\n`);
  return { root, closurePath, activationReceiptPath, snapshotId, candidate, previous };
}

function pointerEtag(generation) {
  return `"${generation.toString(16).padStart(32, '0')}"`;
}

function status(active, generation = 1) {
  const etag = pointerEtag(generation);
  return new Response(JSON.stringify({
    schemaVersion: 1,
    channel: 'stable',
    status: 'active',
    activation: {
      schemaVersion: 1,
      mode: 'promote',
      ...active,
      generation,
      closureSha256: active.snapshotId,
      activatedAt: '2026-07-11T02:00:00.000Z',
      previousSnapshotId: null,
      actor: 'release-engineer',
      runUrl: null,
      reason: 'Verified rollback drill fixture activation'
    },
    pointerEtag: etag
  }), { status: 200, headers: { ETag: etag } });
}

function mutationResponse(request, generation) {
  const etag = pointerEtag(generation);
  return new Response(JSON.stringify({
    schemaVersion: 1,
    status: 'activated',
    pointerEtag: etag,
    activation: {
      schemaVersion: 1,
      mode: request.mode,
      channel: request.channel,
      generation,
      snapshotId: request.targetSnapshotId,
      closureSha256: request.targetSnapshotId,
      version: request.version,
      sourceCommit: request.sourceCommit,
      activatedAt: '2026-07-11T03:00:00.000Z',
      previousSnapshotId: request.expectedCurrentSnapshotId,
      actor: request.actor,
      runUrl: request.runUrl,
      reason: request.reason
    }
  }), { status: 200, headers: { ETag: etag } });
}

const options = (value) => ({ ...value, baseUrl: 'http://127.0.0.1:9000', token: 'x'.repeat(32),
  actor: 'release-engineer', runUrl: null, allowLocalTestOrigin: true });

test('rollback drill selects the previous generation and restores the candidate', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let active = value.candidate;
  let generation = 4;
  const requests = [];
  const result = await drillLinuxRepositoryRollback(options(value), async (_url, request = {}) => {
    if (request.method === 'POST') {
      const body = JSON.parse(request.body);
      requests.push(body);
      assert.equal(body.expectedCurrentSnapshotId, active.snapshotId);
      assert.equal(body.expectedCurrentGeneration, generation);
      assert.equal(body.expectedCurrentPointerEtag, pointerEtag(generation));
      generation += 1;
      active = body.targetSnapshotId === value.snapshotId ? value.candidate : value.previous;
      return mutationResponse(body, generation);
    }
    if (request.method === 'HEAD') {
      return new Response(null, { status: 200, headers: { 'X-OpenBurnBar-Repository-Snapshot': active.snapshotId } });
    }
    return status(active, generation);
  });
  assert.equal(result.passed, true);
  assert.equal(result.candidateRestored, true);
  assert.deepEqual(requests.map((request) => request.targetSnapshotId), [value.previous.snapshotId, value.snapshotId]);
  assert.deepEqual(result.attempts.filter((attempt) => attempt.operation === 'status').map((attempt) => attempt.phase),
    ['initial', 'rollback-precondition', 'reactivate-precondition', 'final']);
});

test('first activation records a verified skipped drill without mutation', async (t) => {
  const value = fixture(false);
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let posts = 0;
  const result = await drillLinuxRepositoryRollback(options(value), async (_url, request = {}) => {
    if (request.method === 'POST') posts += 1;
    return status(value.candidate);
  });
  assert.equal(result.skipped, true);
  assert.equal(result.passed, true);
  assert.equal(result.candidateRestored, true);
  assert.equal(posts, 0);
});

test('rollback verification failure is recorded after the candidate is restored', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let active = value.candidate;
  let generation = 2;
  let rollbackHeads = 0;
  const result = await drillLinuxRepositoryRollback(options(value), async (_url, request = {}) => {
    if (request.method === 'POST') {
      const body = JSON.parse(request.body);
      generation += 1;
      active = body.targetSnapshotId === value.snapshotId ? value.candidate : value.previous;
      return mutationResponse(body, generation);
    }
    if (request.method === 'HEAD') {
      if (active.snapshotId === value.previous.snapshotId) rollbackHeads += 1;
      return new Response(null, { status: 200, headers: {
        'X-OpenBurnBar-Repository-Snapshot': rollbackHeads === 1 ? 'f'.repeat(64) : active.snapshotId
      } });
    }
    return status(active, generation);
  });
  assert.equal(result.passed, false);
  assert.equal(result.candidateRestored, true);
  assert.equal(result.finalObservedStatus.active.snapshotId, value.snapshotId);
  assert.match(result.failures.join('\n'), /did not resolve/u);
});

test('failed candidate restoration records final live status and remains non-passing', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let active = value.candidate;
  let generation = 2;
  let posts = 0;
  const result = await drillLinuxRepositoryRollback(options(value), async (_url, request = {}) => {
    if (request.method === 'POST') {
      posts += 1;
      if (posts === 1) {
        const body = JSON.parse(request.body);
        generation += 1;
        active = value.previous;
        return mutationResponse(body, generation);
      }
      return new Response('activation unavailable', { status: 503 });
    }
    if (request.method === 'HEAD') {
      return new Response(null, { status: 200, headers: { 'X-OpenBurnBar-Repository-Snapshot': active.snapshotId } });
    }
    return status(active, generation);
  });
  assert.equal(result.passed, false);
  assert.equal(result.candidateRestored, false);
  assert.equal(result.finalObservedStatus.active.snapshotId, value.previous.snapshotId);
  assert.ok(posts >= 2);
  assert.match(result.failures.join('\n'), /HTTP 503/u);
});

test('lost rollback response is detected from live status and the candidate is restored', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let active = value.candidate;
  let generation = 2;
  let posts = 0;
  const result = await drillLinuxRepositoryRollback(options(value), async (_url, request = {}) => {
    if (request.method === 'POST') {
      posts += 1;
      const target = JSON.parse(request.body).targetSnapshotId;
      generation += 1;
      active = target === value.snapshotId ? value.candidate : value.previous;
      if (posts === 1) return new Response('gateway lost the response', { status: 502 });
      return mutationResponse(JSON.parse(request.body), generation);
    }
    if (request.method === 'HEAD') {
      return new Response(null, { status: 200, headers: { 'X-OpenBurnBar-Repository-Snapshot': active.snapshotId } });
    }
    return status(active, generation);
  });
  assert.equal(result.passed, false);
  assert.equal(result.candidateRestored, true);
  assert.equal(active.snapshotId, value.snapshotId);
  assert.equal(posts, 2);
  assert.match(result.failures.join('\n'), /HTTP 502/u);
});

test('candidate mismatch is a structured failure with no mutation', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let posts = 0;
  const result = await drillLinuxRepositoryRollback(options(value), async (_url, request = {}) => {
    if (request.method === 'POST') posts += 1;
    return status(value.previous);
  });
  assert.equal(result.passed, false);
  assert.equal(result.candidateRestored, false);
  assert.equal(posts, 0);
  assert.match(result.failures.join('\n'), /not active/u);
});

test('rollback drill rejects a status body and HTTP ETag mismatch before mutation', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let posts = 0;
  const result = await drillLinuxRepositoryRollback(options(value), async (_url, request = {}) => {
    if (request.method === 'POST') posts += 1;
    const response = status(value.candidate, 2);
    return new Response(await response.text(), {
      status: 200,
      headers: { ETag: pointerEtag(3) }
    });
  });
  assert.equal(result.passed, false);
  assert.equal(posts, 0);
  assert.match(result.failures.join('\n'), /invalid active pointer/u);
});

test('malformed successful rollback response is reconciled but never recorded as a passing drill', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let active = value.candidate;
  let generation = 2;
  let posts = 0;
  const result = await drillLinuxRepositoryRollback(options(value), async (_url, request = {}) => {
    if (request.method === 'POST') {
      posts += 1;
      const body = JSON.parse(request.body);
      generation += 1;
      active = body.targetSnapshotId === value.snapshotId ? value.candidate : value.previous;
      if (posts === 1) return new Response(JSON.stringify({ activation: active }), { status: 200 });
      return mutationResponse(body, generation);
    }
    if (request.method === 'HEAD') {
      return new Response(null, { status: 200, headers: { 'X-OpenBurnBar-Repository-Snapshot': active.snapshotId } });
    }
    return status(active, generation);
  });
  assert.equal(result.passed, false);
  assert.equal(result.candidateRestored, true);
  assert.equal(posts, 2);
  assert.match(result.failures.join('\n'), /does not confirm/u);
});

test('credential-bearing rollback requests are pinned to the production origin', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let calls = 0;
  const result = await drillLinuxRepositoryRollback({ ...options(value), allowLocalTestOrigin: false,
    baseUrl: 'https://downloads.burnbar.ai/linux' }, async () => { calls += 1; });
  assert.equal(result.passed, false);
  assert.equal(calls, 0);
  assert.match(result.failures.join('\n'), /bare origin/u);
});

test('rollback CLI atomically emits failure and final-restoration fields on setup failure', (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const releaseOut = path.join(value.root, 'release');
  fs.mkdirSync(path.join(releaseOut, 'repositories'), { recursive: true });
  fs.copyFileSync(value.closurePath, path.join(releaseOut, 'repositories/repository-closure.json'));
  fs.copyFileSync(value.activationReceiptPath, path.join(releaseOut, 'repository-activation.json'));
  const output = path.join(value.root, 'rollback-result.json');
  const result = spawnSync(process.execPath, [path.resolve('scripts/linux-port/drill-linux-repository-rollback.mjs')], {
    cwd: path.resolve('.'),
    encoding: 'utf8',
    env: {
      ...process.env,
      OPENBURNBAR_LINUX_RELEASE_OUT: releaseOut,
      OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN: 'x'.repeat(32),
      OPENBURNBAR_R2_PUBLIC_BASE_URL: 'https://downloads.burnbar.ai.invalid',
      OPENBURNBAR_LINUX_REPOSITORY_ROLLBACK_RECEIPT: output
    }
  });
  assert.notEqual(result.status, 0);
  const receipt = JSON.parse(fs.readFileSync(output, 'utf8'));
  assert.equal(receipt.passed, false);
  assert.equal(receipt.candidateRestored, false);
  assert.equal(receipt.finalObservedStatus, null);
  assert.match(receipt.failures.join('\n'), /must use https:\/\/downloads\.burnbar\.ai/u);
});
