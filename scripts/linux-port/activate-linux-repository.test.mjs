import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { activateLinuxRepository } from './activate-linux-repository.mjs';

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-activation-test-'));
  const closurePath = path.join(root, 'repository-closure.json');
  fs.writeFileSync(closurePath, `${JSON.stringify({
    schemaVersion: 1,
    channel: 'stable',
    version: '1.2.3',
    gitCommit: 'a'.repeat(40)
  })}\n`);
  return {
    root,
    closurePath,
    snapshotId: crypto.createHash('sha256').update(fs.readFileSync(closurePath)).digest('hex')
  };
}

async function server(handler) {
  const instance = http.createServer(handler);
  await new Promise((resolve) => instance.listen(0, '127.0.0.1', resolve));
  return { instance, baseUrl: `http://127.0.0.1:${instance.address().port}` };
}

function activationResponseBody(request, pointerEtag, overrides = {}) {
  return {
    schemaVersion: 1,
    status: 'activated',
    pointerEtag,
    activation: {
      schemaVersion: 1,
      mode: request.mode,
      channel: request.channel,
      generation: (request.expectedCurrentGeneration ?? 0) + 1,
      snapshotId: request.targetSnapshotId,
      closureSha256: request.targetSnapshotId,
      version: request.version,
      sourceCommit: request.sourceCommit,
      activatedAt: '2026-07-11T03:00:00.000Z',
      previousSnapshotId: request.expectedCurrentSnapshotId,
      actor: request.actor,
      runUrl: request.runUrl,
      reason: request.reason,
      ...overrides
    }
  };
}

test('activation performs authenticated status read and exact-snapshot mutation', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const requests = [];
  const service = await server(async (request, response) => {
    requests.push({ method: request.method, url: request.url, authorization: request.headers.authorization,
      body: await new Promise((resolve) => { let body = ''; request.on('data', (chunk) => { body += chunk; }); request.on('end', () => resolve(body)); }) });
    response.setHeader('Content-Type', 'application/json');
    if (request.method === 'GET') { response.statusCode = 404; return response.end(JSON.stringify({ schemaVersion: 1, status: 'inactive', channel: 'stable' })); }
    const pointerEtag = `"${'d'.repeat(32)}"`;
    response.setHeader('ETag', pointerEtag);
    response.end(JSON.stringify(activationResponseBody(JSON.parse(requests.at(-1).body), pointerEtag)));
  });
  t.after(() => service.instance.close());
  const result = await activateLinuxRepository({
    closurePath: value.closurePath,
    baseUrl: service.baseUrl,
    actor: 'release-bot',
    reason: 'Promote verified candidate',
    runUrl: 'https://github.com/Imagine-That-Ai/BurnBar/actions/runs/1',
    confirm: true,
    token: 'x'.repeat(32),
    allowLocalTestOrigin: true
  });
  assert.equal(result.result.activation.snapshotId, value.snapshotId);
  assert.deepEqual(requests.map((item) => item.method), ['GET', 'POST']);
  assert.equal(requests[0].authorization, `Bearer ${'x'.repeat(32)}`);
  const request = JSON.parse(requests[1].body);
  assert.equal(request.expectedCurrentSnapshotId, null);
  assert.equal(request.expectedCurrentGeneration, null);
  assert.equal(request.expectedCurrentPointerEtag, null);
});

test('dry run reads state but never mutates', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let calls = 0;
  const service = await server((_request, response) => {
    calls += 1;
    response.setHeader('Content-Type', 'application/json');
    response.statusCode = 404;
    response.end(JSON.stringify({ schemaVersion: 1, status: 'inactive', channel: 'stable' }));
  });
  t.after(() => service.instance.close());
  const result = await activateLinuxRepository({ closurePath: value.closurePath, baseUrl: service.baseUrl,
    actor: 'operator', reason: 'Inspect candidate only', confirm: false, token: 'x'.repeat(32), allowLocalTestOrigin: true });
  assert.equal(result.dryRun, true);
  assert.equal(calls, 1);
});

test('metadata refresh keeps the exact active CAS identity and uses the explicit refresh mode', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const currentSnapshotId = 'b'.repeat(64);
  const statusEtag = `"${'c'.repeat(32)}"`;
  const result = await activateLinuxRepository({
    closurePath: value.closurePath,
    baseUrl: 'https://downloads.burnbar.ai',
    actor: 'release-bot',
    reason: 'Refresh signed apt expiry metadata',
    runUrl: null,
    mode: 'refresh',
    confirm: false,
    token: 'x'.repeat(32)
  }, async () => new Response(JSON.stringify({
    schemaVersion: 1,
    status: 'active',
    channel: 'stable',
    activation: {
      schemaVersion: 1,
      mode: 'promote',
      channel: 'stable',
      generation: 7,
      snapshotId: currentSnapshotId,
      closureSha256: currentSnapshotId,
      version: '1.2.3',
      sourceCommit: 'a'.repeat(40),
      activatedAt: '2026-07-11T03:00:00.000Z',
      previousSnapshotId: null,
      actor: 'release-bot',
      runUrl: null,
      reason: 'Initial verified promotion'
    },
    pointerEtag: statusEtag
  }), { status: 200, headers: { ETag: statusEtag, 'Content-Type': 'application/json' } }));
  assert.equal(result.request.mode, 'refresh');
  assert.equal(result.request.expectedCurrentSnapshotId, currentSnapshotId);
  assert.equal(result.request.expectedCurrentGeneration, 7);
  assert.equal(result.request.expectedCurrentPointerEtag, statusEtag);
});

test('a later promotion accepts the exact active Worker status schema', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const currentSnapshotId = 'b'.repeat(64);
  let activationRequest;
  const result = await activateLinuxRepository({
    closurePath: value.closurePath,
    baseUrl: 'https://downloads.burnbar.ai',
    actor: 'release-bot',
    reason: 'Promote the next verified candidate',
    runUrl: null,
    confirm: true,
    token: 'x'.repeat(32)
  }, async (_url, options = {}) => {
    if (!options.method) {
      const statusEtag = `"${'c'.repeat(32)}"`;
      return new Response(JSON.stringify({
        schemaVersion: 1,
        status: 'active',
        channel: 'stable',
        activation: {
          schemaVersion: 1,
          mode: 'promote',
          channel: 'stable',
          generation: 7,
          snapshotId: currentSnapshotId,
          closureSha256: currentSnapshotId,
          version: '1.1.0',
          sourceCommit: 'b'.repeat(40),
          activatedAt: '2026-07-11T02:00:00.000Z',
          previousSnapshotId: null,
          actor: 'release-bot',
          runUrl: null,
          reason: 'Prior verified activation'
        },
        pointerEtag: statusEtag
      }), { status: 200, headers: { 'Content-Type': 'application/json', ETag: statusEtag } });
    }
    activationRequest = JSON.parse(options.body);
    const nextEtag = `"${'d'.repeat(32)}"`;
    return new Response(JSON.stringify(activationResponseBody(activationRequest, nextEtag)), {
      status: 200, headers: { 'Content-Type': 'application/json', ETag: nextEtag }
    });
  });
  assert.equal(activationRequest.expectedCurrentSnapshotId, currentSnapshotId);
  assert.equal(activationRequest.expectedCurrentGeneration, 7);
  assert.equal(activationRequest.expectedCurrentPointerEtag, `"${'c'.repeat(32)}"`);
  assert.equal(result.result.activation.snapshotId, value.snapshotId);
});

test('promotion after deactivation preserves the inactive tombstone CAS identity', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let activationRequest;
  const pointerEtag = `"${'d'.repeat(32)}"`;
  await activateLinuxRepository({
    closurePath: value.closurePath,
    baseUrl: 'https://downloads.burnbar.ai',
    actor: 'release-bot',
    reason: 'Promote after an intentional deactivation',
    runUrl: null,
    confirm: true,
    token: 'x'.repeat(32)
  }, async (_url, options = {}) => {
    if (!options.method) {
      return new Response(JSON.stringify({
        schemaVersion: 1,
        status: 'inactive',
        channel: 'stable',
        deactivation: {
          schemaVersion: 1,
          status: 'inactive',
          channel: 'stable',
          generation: 8,
          previousSnapshotId: 'b'.repeat(64),
          previousVersion: '1.1.0',
          previousSourceCommit: 'b'.repeat(40),
          fallbackMode: 'disabled',
          deactivatedAt: '2026-07-11T02:30:00.000Z',
          actor: 'release-bot',
          runUrl: null,
          reason: 'Prior intentional deactivation'
        },
        pointerEtag
      }), { status: 404, headers: { 'Content-Type': 'application/json', ETag: pointerEtag } });
    }
    activationRequest = JSON.parse(options.body);
    const nextEtag = `"${'e'.repeat(32)}"`;
    return new Response(JSON.stringify(activationResponseBody(activationRequest, nextEtag)), {
      status: 200, headers: { 'Content-Type': 'application/json', ETag: nextEtag }
    });
  });
  assert.equal(activationRequest.expectedCurrentSnapshotId, null);
  assert.equal(activationRequest.expectedCurrentGeneration, 8);
  assert.equal(activationRequest.expectedCurrentPointerEtag, pointerEtag);
});

test('stale expected-current and malformed status fail before mutation', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const service = await server((_request, response) => {
    response.setHeader('Content-Type', 'application/json');
    response.setHeader('ETag', `"${'a'.repeat(32)}"`);
    response.end(JSON.stringify({ schemaVersion: 1, channel: 'stable', status: 'active', activation: {
      snapshotId: 'b'.repeat(64), version: '1.1.0', generation: 3
    }, pointerEtag: `"${'a'.repeat(32)}"` }));
  });
  t.after(() => service.instance.close());
  await assert.rejects(() => activateLinuxRepository({ closurePath: value.closurePath, baseUrl: service.baseUrl,
    expectedCurrent: 'none', actor: 'operator', reason: 'Attempt stale activation', confirm: true, token: 'x'.repeat(32),
    allowLocalTestOrigin: true }),
  /does not match --expected-current/u);
});

test('status body pointer identity must match the exact HTTP ETag', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const options = {
    closurePath: value.closurePath,
    baseUrl: 'https://downloads.burnbar.ai',
    actor: 'operator',
    reason: 'Inspect exact pointer binding',
    confirm: false,
    token: 'x'.repeat(32)
  };
  const bodyEtag = `"${'a'.repeat(32)}"`;
  const headerEtag = `"${'b'.repeat(32)}"`;
  await assert.rejects(() => activateLinuxRepository(options, async () => new Response(JSON.stringify({
    schemaVersion: 1,
    status: 'active',
    channel: 'stable',
    activation: { snapshotId: 'b'.repeat(64), version: '1.1.0', generation: 3 },
    pointerEtag: bodyEtag
  }), { status: 200, headers: { ETag: headerEtag } })), /invalid active pointer/u);
  await assert.rejects(() => activateLinuxRepository(options, async () => new Response(JSON.stringify({
    schemaVersion: 1,
    status: 'inactive',
    channel: 'stable'
  }), { status: 404, headers: { ETag: headerEtag } })), /unexpectedly has an HTTP ETag/u);
  await assert.rejects(() => activateLinuxRepository(options, async () => new Response(JSON.stringify({
    schemaVersion: 1,
    status: 'inactive',
    channel: 'stable',
    deactivation: { generation: 4 },
    pointerEtag: bodyEtag
  }), { status: 404, headers: { ETag: headerEtag } })), /invalid inactive pointer/u);
});

test('activation mutation response requires an exact body and HTTP ETag binding', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const bodyEtag = `"${'d'.repeat(32)}"`;
  const headerEtag = `"${'e'.repeat(32)}"`;
  await assert.rejects(() => activateLinuxRepository({
    closurePath: value.closurePath,
    baseUrl: 'https://downloads.burnbar.ai',
    actor: 'operator',
    reason: 'Promote exact response binding',
    confirm: true,
    token: 'x'.repeat(32)
  }, async (_url, request = {}) => {
    if (!request.method) {
      return new Response(JSON.stringify({ schemaVersion: 1, status: 'inactive', channel: 'stable' }), { status: 404 });
    }
    const activationRequest = JSON.parse(request.body);
    return new Response(JSON.stringify(activationResponseBody(activationRequest, bodyEtag)), {
      status: 200,
      headers: { ETag: headerEtag }
    });
  }), /does not confirm/u);
});

test('server conflict and mismatched response fail closed', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let conflict = true;
  const service = await server((_request, response) => {
    response.setHeader('Content-Type', 'application/json');
    if (_request.method === 'GET') {
      return response.end(JSON.stringify({ schemaVersion: 1, status: 'inactive', channel: 'stable' }));
    }
    if (conflict) { response.statusCode = 409; return response.end('{"error":"activation_conflict"}'); }
    const pointerEtag = `"${'d'.repeat(32)}"`;
    response.setHeader('ETag', pointerEtag);
    response.end(JSON.stringify(activationResponseBody({
      schemaVersion: 1,
      mode: 'promote',
      channel: 'stable',
      targetSnapshotId: value.snapshotId,
      expectedCurrentSnapshotId: null,
      expectedCurrentGeneration: null,
      version: '1.2.3',
      sourceCommit: 'a'.repeat(40),
      actor: 'operator',
      runUrl: null,
      reason: 'Promote verified candidate'
    }, pointerEtag, { snapshotId: 'c'.repeat(64), closureSha256: 'c'.repeat(64) })));
  });
  t.after(() => service.instance.close());
  const options = { closurePath: value.closurePath, baseUrl: service.baseUrl, actor: 'operator',
    reason: 'Promote verified candidate', confirm: true, token: 'x'.repeat(32), allowLocalTestOrigin: true };
  await assert.rejects(() => activateLinuxRepository(options), /HTTP 409/u);
  conflict = false;
  await assert.rejects(() => activateLinuxRepository(options), /does not confirm/u);
});

test('activation exposes durable intent before an ambiguous response failure', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let attempted;
  let calls = 0;
  await assert.rejects(() => activateLinuxRepository({
    closurePath: value.closurePath,
    baseUrl: 'https://downloads.burnbar.ai',
    actor: 'release-bot',
    reason: 'Exercise ambiguous activation response',
    runUrl: null,
    confirm: true,
    token: 'x'.repeat(32),
    onAttempt: (intent) => { attempted = structuredClone(intent); }
  }, async (_url, options = {}) => {
    calls += 1;
    if (!options.method) {
      return new Response(JSON.stringify({ schemaVersion: 1, status: 'inactive', channel: 'stable' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' }
      });
    }
    assert.ok(attempted, 'onAttempt must complete before the activation POST begins');
    throw new Error('response lost after remote commit');
  }), /response lost/u);
  assert.equal(calls, 2);
  assert.equal(attempted.request.targetSnapshotId, value.snapshotId);
  assert.equal(attempted.request.expectedCurrentSnapshotId, null);
  assert.equal(attempted.request.expectedCurrentGeneration, null);
  assert.equal(attempted.request.expectedCurrentPointerEtag, null);
  assert.equal(attempted.status.active, null);
});

test('activation CLI leaves a planned, not-attempted receipt when setup fails before status I/O', (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const outputPath = path.join(value.root, 'activation-receipt.json');
  const result = spawnSync(process.execPath, [
    path.resolve('scripts/linux-port/activate-linux-repository.mjs'),
    '--closure', value.closurePath,
    '--base-url', 'https://downloads.burnbar.ai.invalid',
    '--actor', 'release-bot',
    '--reason', 'Verify durable intent before any remote mutation',
    '--output', outputPath,
    '--yes'
  ], {
    cwd: path.resolve('.'),
    encoding: 'utf8',
    env: {
      ...process.env,
      OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN: 'x'.repeat(32)
    }
  });
  assert.notEqual(result.status, 0);
  const receipt = JSON.parse(fs.readFileSync(outputPath, 'utf8'));
  assert.equal(receipt.phase, 'planned');
  assert.equal(receipt.mutationAttempted, false);
  assert.equal(receipt.candidate.snapshotId, value.snapshotId);
  assert.equal(Object.hasOwn(receipt, 'request'), false);
  assert.match(result.stderr, /must use https:\/\/downloads\.burnbar\.ai/u);
});

test('credential-bearing activation requests are pinned to the production origin', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let calls = 0;
  const options = { closurePath: value.closurePath, actor: 'operator', reason: 'Origin validation',
    confirm: true, token: 'x'.repeat(32) };
  const fetchImpl = async () => { calls += 1; throw new Error('unexpected request'); };
  for (const baseUrl of [
    'http://downloads.burnbar.ai',
    'https://user@downloads.burnbar.ai',
    'https://downloads.burnbar.ai/linux',
    'https://downloads.burnbar.ai/.',
    'https://downloads.burnbar.ai:443',
    'https://downloads.burnbar.ai?redirect=https://example.com',
    'https://downloads.burnbar.ai.example'
  ]) {
    await assert.rejects(() => activateLinuxRepository({ ...options, baseUrl }, fetchImpl), /repository router URL/u);
  }
  await assert.rejects(() => activateLinuxRepository({ ...options, baseUrl: 'http://127.0.0.1:9000' }, fetchImpl),
    /must use https:\/\/downloads\.burnbar\.ai/u);
  assert.equal(calls, 0);
});

test('activation rejects actors, reasons, and run URLs outside the Worker grammar before mutation', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  for (const override of [
    { actor: 'release engineer' },
    { reason: ' leading reason' },
    { runUrl: 'https://github.com/example/repo/actions/runs/1' }
  ]) {
    let calls = 0;
    await assert.rejects(() => activateLinuxRepository({
      closurePath: value.closurePath,
      baseUrl: 'https://downloads.burnbar.ai',
      actor: 'release-bot',
      reason: 'Promote verified candidate',
      runUrl: null,
      confirm: true,
      token: 'x'.repeat(32),
      ...override
    }, async () => {
      calls += 1;
      return new Response(JSON.stringify({ schemaVersion: 1, status: 'inactive', channel: 'stable' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' }
      });
    }), /actor|reason|run URL/u);
    assert.equal(calls, 1);
  }
});

test('exact production origin remains valid without a test override', async (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let requestedUrl;
  const result = await activateLinuxRepository({ closurePath: value.closurePath,
    baseUrl: 'https://downloads.burnbar.ai/', actor: 'operator', reason: 'Validate production origin',
    confirm: false, token: 'x'.repeat(32) }, async (url) => {
    requestedUrl = url;
    return new Response(JSON.stringify({ schemaVersion: 1, status: 'inactive', channel: 'stable' }), {
      status: 404, headers: { 'Content-Type': 'application/json' }
    });
  });
  assert.equal(result.dryRun, true);
  assert.equal(requestedUrl.origin, 'https://downloads.burnbar.ai');
  assert.equal(requestedUrl.pathname, '/linux/repository-admin/status');
});
