import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import test from 'node:test';

import { handleRequest } from '../src/index.mjs';

const TOKEN = 'repository-activation-test-token-0000000000000001';
const UPLOAD_TOKEN = 'repository-upload-test-token-00000000000000000002';
const COMMIT = 'a'.repeat(40);
const RUN_URL = 'https://github.com/Imagine-That-Ai/BurnBar/actions/runs/12345/attempts/2';
const ORIGIN = 'https://downloads.burnbar.ai';
const TEST_FEED_KEYS = await crypto.webcrypto.subtle.generateKey('Ed25519', true, ['sign', 'verify']);
const TEST_FEED_SPKI = new Uint8Array(await crypto.webcrypto.subtle.exportKey('spki', TEST_FEED_KEYS.publicKey));
const TEST_FEED_FINGERPRINT = crypto.createHash('sha256').update(TEST_FEED_SPKI).digest('hex');

test('authenticated initial activation publishes one CAS pointer and status returns it', async () => {
  const bucket = new FakeR2();
  const snapshot = await seedSnapshot(bucket, { channel: 'stable', version: '1.2.3' });
  const activation = await activate(bucket, activationBody(snapshot));
  assert.equal(activation.status, 200);
  const body = await activation.json();
  assert.equal(body.status, 'activated');
  assert.equal(body.activation.snapshotId, snapshot.id);
  assert.equal(body.activation.generation, 1);
  assert.equal(body.activation.previousSnapshotId, null);
  assert.match(body.pointerEtag, /^"[a-f0-9]{64}"$/u);
  assert.deepEqual([...bucket.keys()].filter((key) => key.includes('repository-activations/')), [
    'linux/repository-activations/stable.json'
  ]);

  const status = await request(bucket, '/linux/repository-admin/status?channel=stable', {
    headers: authHeaders()
  });
  assert.equal(status.status, 200);
  const statusBody = await status.json();
  assert.equal(statusBody.channel, 'stable');
  assert.equal(statusBody.activation.snapshotId, snapshot.id);
  assert.equal(status.headers.get('etag'), body.pointerEtag);
  assert.equal(status.headers.get('cache-control'), 'no-store');
});

test('first activation deactivation restores exact legacy direct-R2 repository and root-feed routes', async () => {
  const bucket = new FakeR2();
  bucket.seed('linux/apt/dists/stable/InRelease', 'legacy apt root');
  bucket.seed('linux/rpm/stable/x86_64/repodata/repomd.xml', 'legacy rpm root');
  bucket.seed('linux/apt/openburnbar-archive-keyring.gpg', 'legacy keyring');
  bucket.seed('latest-linux.json', '{"version":"0.9.0"}\n');
  const snapshot = await seedSnapshot(bucket, { channel: 'stable', version: '1.2.3' });
  const activated = await (await activate(bucket, activationBody(snapshot))).json();
  const publication = await seedFeedBundle(bucket, snapshot, activated.pointerEtag);
  assert.equal((await publishFeed(bucket, publication)).status, 200);

  const response = await deactivate(bucket, deactivationBody(snapshot));
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.deepEqual(Object.keys(body).sort(), [
    'channel', 'fallbackMode', 'generation', 'pointerEtag', 'previousSnapshotId', 'schemaVersion', 'status'
  ]);
  assert.equal(body.status, 'inactive');
  assert.equal(body.channel, 'stable');
  assert.equal(body.previousSnapshotId, snapshot.id);
  assert.equal(body.generation, 2);
  assert.equal(body.fallbackMode, 'legacy-direct-r2');
  assert.equal(response.headers.get('etag'), body.pointerEtag);

  const pointerKey = 'linux/repository-activations/stable.json';
  assert.equal([...bucket.keys()].filter((key) => key === pointerKey).length, 1);
  const tombstone = JSON.parse(await bucket.text(pointerKey));
  assert.deepEqual(Object.keys(tombstone).sort(), [
    'actor', 'channel', 'deactivatedAt', 'fallbackMode', 'generation', 'previousSnapshotId',
    'previousSourceCommit', 'previousVersion', 'reason', 'runUrl', 'schemaVersion', 'status'
  ]);
  assert.equal(tombstone.status, 'inactive');
  assert.equal(tombstone.previousSnapshotId, snapshot.id);
  assert.equal(tombstone.previousVersion, snapshot.version);
  assert.equal(tombstone.previousSourceCommit, snapshot.commit);
  assert.equal(tombstone.fallbackMode, 'legacy-direct-r2');

  const status = await request(bucket, '/linux/repository-admin/status?channel=stable', { headers: authHeaders() });
  assert.equal(status.status, 404);
  const statusBody = await status.json();
  assert.equal(statusBody.status, 'inactive');
  assert.deepEqual(statusBody.deactivation, tombstone);
  assert.equal(statusBody.pointerEtag, body.pointerEtag);
  assert.equal(status.headers.get('etag'), body.pointerEtag);

  for (const [path, expected] of [
    ['/linux/apt/dists/stable/InRelease', 'legacy apt root'],
    ['/linux/rpm/stable/x86_64/repodata/repomd.xml', 'legacy rpm root'],
    ['/linux/apt/openburnbar-archive-keyring.gpg', 'legacy keyring']
  ]) {
    const publicResponse = await request(bucket, path);
    assert.equal(publicResponse.status, 200, path);
    assert.equal(await publicResponse.text(), expected, path);
    assert.equal(publicResponse.headers.get('x-openburnbar-repository-snapshot'), null, path);
  }
  assert.equal((await request(bucket, '/linux/apt/dists/stable/Release')).status, 404);
  const legacyFeed = await request(bucket, '/latest-linux.json');
  assert.equal(legacyFeed.status, 200);
  assert.equal((await legacyFeed.json()).version, '0.9.0');
  assert.equal(legacyFeed.headers.get('x-openburnbar-repository-snapshot'), null);
  assert.equal(legacyFeed.headers.get('x-openburnbar-feed-generation'), null);
  assert.equal((await request(bucket, '/latest-linux.json', { method: 'HEAD' })).status, 200);
  assert.equal((await request(bucket, '/latest-linux.json.ed25519.sig')).status, 404);
  const stableChannelFeed = await request(bucket, '/linux/update/stable/latest-linux.json');
  assert.equal(stableChannelFeed.status, 200);
  assert.equal((await stableChannelFeed.json()).version, '0.9.0');
  assert.equal(stableChannelFeed.headers.get('x-openburnbar-repository-snapshot'), null);
  assert.equal((await request(bucket, '/linux/update/stable/latest-linux.json.ed25519.sig')).status, 404);
  assert.equal((await publishFeed(bucket, publication)).status, 409);
  assert.equal((await deactivate(bucket, deactivationBody(snapshot))).status, 409);
});

test('malformed inactive pointers are not treated as safely inactive state', async () => {
  const bucket = new FakeR2();
  const snapshot = await seedSnapshot(bucket, { channel: 'stable', version: '1.2.3' });
  await activate(bucket, activationBody(snapshot));
  await deactivate(bucket, deactivationBody(snapshot));
  const pointerKey = 'linux/repository-activations/stable.json';
  const tombstone = JSON.parse(await bucket.text(pointerKey));
  bucket.seed(pointerKey, `${JSON.stringify({ ...tombstone, unexpected: true })}\n`);

  assert.equal((await request(bucket, '/linux/repository-admin/status?channel=stable', {
    headers: authHeaders()
  })).status, 503);
  assert.equal((await request(bucket, '/linux/apt/dists/stable/InRelease')).status, 503);
  assert.equal((await activate(bucket, activationBody(snapshot))).status, 503);
  assert.equal((await deactivate(bucket, deactivationBody(snapshot))).status, 503);
});

test('deactivation after a replacement activation disables legacy fallback', async () => {
  const bucket = new FakeR2();
  bucket.seed('linux/apt/dists/stable/InRelease', 'legacy bytes must not reappear');
  bucket.seed('latest-linux.json', '{"version":"0.9.0"}\n');
  const first = await seedSnapshot(bucket, { channel: 'stable', version: '1.2.3' });
  await activate(bucket, activationBody(first));
  const second = await seedSnapshot(bucket, { channel: 'stable', version: '1.3.0', commit: 'b'.repeat(40) });
  await activate(bucket, { ...activationBody(second), expectedCurrentSnapshotId: first.id });

  const response = await deactivate(bucket, deactivationBody(second));
  assert.equal(response.status, 200);
  assert.equal((await response.json()).fallbackMode, 'disabled');
  const tombstone = JSON.parse(await bucket.text('linux/repository-activations/stable.json'));
  assert.equal(tombstone.fallbackMode, 'disabled');
  const publicResponse = await request(bucket, '/linux/apt/dists/stable/InRelease');
  assert.equal(publicResponse.status, 503);
  assert.equal(publicResponse.headers.get('cache-control'), 'no-store');
  assert.equal((await request(bucket, '/latest-linux.json')).status, 503);
});

test('first-cutover deactivation handles legacy feed fallback explicitly for every channel', async () => {
  for (const channel of ['stable', 'prerelease', 'nightly']) {
    for (const withFeedPointer of [false, true]) {
      const label = `${channel} withFeedPointer=${withFeedPointer}`;
      const bucket = new FakeR2();
      bucket.seed('latest-linux.json', '{"version":"0.9.0"}\n');
      bucket.seed('latest-linux.json.ed25519.sig', 'legacy signature');
      const snapshot = await seedSnapshot(bucket, { channel, version: '1.2.3' });
      const activation = await (await activate(bucket, activationBody(snapshot))).json();
      if (withFeedPointer) {
        const publication = await seedFeedBundle(bucket, snapshot, activation.pointerEtag);
        assert.equal((await publishFeed(bucket, publication)).status, 200, label);
      }
      const deactivated = await deactivate(bucket, deactivationBody(snapshot));
      assert.equal(deactivated.status, 200, label);
      assert.equal((await deactivated.json()).fallbackMode, 'legacy-direct-r2', label);

      const path = `/linux/update/${channel}/latest-linux.json`;
      const signaturePath = `${path}.ed25519.sig`;
      const feed = await request(bucket, path);
      assert.equal(feed.status, channel === 'stable' ? 200 : 404, label);
      if (channel === 'stable') {
        assert.equal(await feed.text(), '{"version":"0.9.0"}\n');
        assert.equal(await (await request(bucket, signaturePath)).text(), 'legacy signature');
        assert.equal((await request(bucket, '/latest-linux.json')).status, 200);
      } else {
        assert.equal((await request(bucket, signaturePath)).status, 404, label);
      }
      assert.equal(feed.headers.get('x-openburnbar-repository-snapshot'), null, label);
      assert.equal(feed.headers.get('x-openburnbar-feed-generation'), null, label);
    }
  }
});

test('stable legacy feed fallback fails closed when the tombstone changes during object read', async () => {
  const bucket = new FakeR2();
  bucket.seed('latest-linux.json', '{"version":"0.9.0"}\n');
  const snapshot = await seedSnapshot(bucket, { channel: 'stable', version: '1.2.3' });
  await activate(bucket, activationBody(snapshot));
  const activeRecord = bucket.textSync('linux/repository-activations/stable.json');
  await deactivate(bucket, deactivationBody(snapshot));
  bucket.beforeHead = (key) => {
    if (key !== 'latest-linux.json') return;
    bucket.beforeHead = null;
    bucket.seed('linux/repository-activations/stable.json', activeRecord);
  };

  const response = await request(bucket, '/latest-linux.json');
  assert.equal(response.status, 503);
  assert.match((await response.json()).error, /fallback changed during request/u);
});

test('deactivation enforces bearer auth, method, query, content type, and exact request grammar', async () => {
  const bucket = new FakeR2();
  const snapshot = await seedSnapshot(bucket, { channel: 'stable', version: '1.2.3' });
  await activate(bucket, activationBody(snapshot));
  const body = deactivationBody(snapshot);
  assert.equal((await request(bucket, '/linux/repository-admin/deactivate', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body)
  })).status, 401);
  assert.equal((await request(bucket, '/linux/repository-admin/deactivate', {
    method: 'GET', headers: authHeaders()
  })).status, 405);
  assert.equal((await request(bucket, '/linux/repository-admin/deactivate?channel=stable', {
    method: 'POST', headers: authHeaders({ 'Content-Type': 'application/json' }), body: JSON.stringify(body)
  })).status, 400);
  assert.equal((await request(bucket, '/linux/repository-admin/deactivate', {
    method: 'POST', headers: authHeaders(), body: JSON.stringify(body)
  })).status, 415);
  for (const invalid of [
    { ...body, extra: true },
    { ...body, schemaVersion: 2 },
    { ...body, channel: 'unknown' },
    { ...body, expectedCurrentSnapshotId: null },
    { ...body, expectedCurrentGeneration: -1 },
    { ...body, expectedCurrentPointerEtag: '"bad"' },
    { ...body, actor: '' },
    { ...body, runUrl: 'https://attacker.example/run/1' },
    { ...body, reason: 'short' }
  ]) {
    assert.equal((await deactivate(bucket, invalid)).status, 400, JSON.stringify(invalid));
  }
});

test('deactivation rejects stale logical state and a concurrent pointer winner', async () => {
  const bucket = new FakeR2();
  const snapshot = await seedSnapshot(bucket, { channel: 'stable', version: '1.2.3' });
  await activate(bucket, activationBody(snapshot));
  const stale = await deactivate(bucket, {
    ...deactivationBody(snapshot), expectedCurrentSnapshotId: 'f'.repeat(64)
  });
  assert.equal(stale.status, 409);
  assert.equal((await stale.json()).currentSnapshotId, snapshot.id);

  const identity = await currentPointerIdentity(bucket, 'stable');
  const staleGeneration = await deactivate(bucket, {
    ...deactivationBody(snapshot),
    expectedCurrentGeneration: identity.generation + 1,
    expectedCurrentPointerEtag: identity.etag
  });
  assert.equal(staleGeneration.status, 409);
  assert.equal((await staleGeneration.json()).currentGeneration, identity.generation);
  const staleEtag = await deactivate(bucket, {
    ...deactivationBody(snapshot),
    expectedCurrentGeneration: identity.generation,
    expectedCurrentPointerEtag: `"${'f'.repeat(64)}"`
  });
  assert.equal(staleEtag.status, 409);
  assert.equal((await staleEtag.json()).currentPointerEtag, identity.etag);

  const pointerKey = 'linux/repository-activations/stable.json';
  const before = JSON.parse(await bucket.text(pointerKey));
  bucket.beforeConditionalPut = (key) => {
    if (key !== pointerKey) return;
    bucket.beforeConditionalPut = null;
    bucket.seed(key, `${JSON.stringify({ ...before, generation: 2, reason: 'competing control write won' })}\n`);
  };
  const raced = await deactivate(bucket, deactivationBody(snapshot));
  assert.equal(raced.status, 409);
  assert.match((await raced.json()).error, /concurrent/u);
  assert.equal(JSON.parse(await bucket.text(pointerKey)).reason, 'competing control write won');
});

test('activation after a tombstone uses its ETag and generation and permits only exact retry or a newer version', async () => {
  const bucket = new FakeR2();
  const first = await seedSnapshot(bucket, { channel: 'stable', version: '1.2.3' });
  await activate(bucket, activationBody(first));
  await deactivate(bucket, deactivationBody(first));

  const driftedIdentity = await seedSnapshot(bucket, {
    channel: 'stable', version: '1.2.3', commit: 'b'.repeat(40)
  });
  const drifted = await activate(bucket, activationBody(driftedIdentity));
  assert.equal(drifted.status, 409);
  assert.match((await drifted.json()).error, /exact prior snapshot or use a strictly newer version/u);

  const retry = await activate(bucket, activationBody(first));
  assert.equal(retry.status, 200);
  const retryBody = await retry.json();
  assert.equal(retryBody.activation.generation, 3);
  assert.equal(retryBody.activation.snapshotId, first.id);
  assert.equal(retryBody.activation.previousSnapshotId, null);
  assert.equal((await request(bucket, '/linux/apt/dists/stable/InRelease')).status, 200);

  await deactivate(bucket, deactivationBody(first));
  const newer = await seedSnapshot(bucket, { channel: 'stable', version: '1.3.0', commit: 'c'.repeat(40) });
  const promoted = await activate(bucket, activationBody(newer));
  assert.equal(promoted.status, 200);
  assert.equal((await promoted.json()).activation.generation, 5);
});

test('reactivation loses safely when the inactive pointer changes before its conditional write', async () => {
  const bucket = new FakeR2();
  const snapshot = await seedSnapshot(bucket, { channel: 'stable', version: '1.2.3' });
  await activate(bucket, activationBody(snapshot));
  await deactivate(bucket, deactivationBody(snapshot));
  const pointerKey = 'linux/repository-activations/stable.json';
  const tombstone = JSON.parse(await bucket.text(pointerKey));
  bucket.beforeConditionalPut = (key) => {
    if (key !== pointerKey) return;
    bucket.beforeConditionalPut = null;
    bucket.seed(key, `${JSON.stringify({
      ...tombstone,
      generation: tombstone.generation + 1,
      reason: 'competing deactivation control write won'
    })}\n`);
  };

  const raced = await activate(bucket, activationBody(snapshot));
  assert.equal(raced.status, 409);
  assert.match((await raced.json()).error, /concurrent/u);
  const winner = JSON.parse(await bucket.text(pointerKey));
  assert.equal(winner.status, 'inactive');
  assert.equal(winner.reason, 'competing deactivation control write won');
});

test('admin routes enforce bearer authentication, exact methods, and exact status query', async () => {
  const bucket = new FakeR2();
  for (const headers of [{}, { Authorization: 'Bearer wrong-token-that-is-long-enough-000000' }]) {
    const response = await request(bucket, '/linux/repository-admin/status?channel=stable', { headers });
    assert.equal(response.status, 401);
    assert.equal(response.headers.get('www-authenticate'), 'Bearer');
  }
  assert.equal((await request(bucket, '/linux/repository-admin/status?channel=stable&extra=1', {
    headers: authHeaders()
  })).status, 400);
  assert.equal((await request(bucket, '/linux/repository-admin/status?channel=unknown', {
    headers: authHeaders()
  })).status, 400);
  assert.equal((await request(bucket, '/linux/repository-admin/status?channel=stable', {
    method: 'POST', headers: authHeaders()
  })).status, 405);
  assert.equal((await request(bucket, '/linux/repository-admin/unknown', {
    headers: authHeaders()
  })).status, 404);
  assert.equal((await request(bucket, '/linux/repository-admin/feed-status')).status, 401);
  assert.equal((await request(bucket, '/linux/repository-admin/feed-status', {
    headers: authHeaders()
  })).status, 400);
  const inactiveFeedStatus = await request(bucket, '/linux/repository-admin/feed-status?channel=stable', {
    headers: authHeaders()
  });
  assert.equal(inactiveFeedStatus.status, 404);
  assert.deepEqual(await inactiveFeedStatus.json(), { schemaVersion: 1, status: 'inactive', channel: 'stable' });
  assert.equal((await request(bucket, '/linux/repository-admin/feed-status?channel=stable&extra=1', {
    headers: authHeaders()
  })).status, 400);
  assert.equal((await request(bucket, '/linux/repository-admin/feed-status?channel=unknown', {
    headers: authHeaders()
  })).status, 400);
  assert.equal((await request(bucket, '/linux/repository-admin/publish-feed', {
    headers: authHeaders()
  })).status, 405);
  assert.equal((await request(bucket, '/linux/repository-admin/rebind-feed', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}'
  })).status, 401);
  assert.equal((await request(bucket, '/linux/repository-admin/rebind-feed?retry=1', {
    method: 'POST', headers: authHeaders({ 'Content-Type': 'application/json' }), body: '{}'
  })).status, 400);
});

test('bearer credentials reject whitespace, controls, quotes, and backslashes outside the shared alphabet', async () => {
  const bucket = new FakeR2();
  for (const value of [
    `Bearer ${'a'.repeat(32)} space`,
    `Bearer ${'a'.repeat(32)}\t`,
    `Bearer ${'a'.repeat(32)}"`,
    `Bearer ${'a'.repeat(32)}\\`,
    `Bearer ${'a'.repeat(32)}\u0001`
  ]) {
    const response = await requestAsRoleWithRawAuthorization(bucket, value);
    assert.equal(response.status, 401, JSON.stringify(value));
  }
});

test('immutable upload is create-only, idempotent for identical bytes, and rejects drift', async () => {
  const bucket = new FakeR2();
  const key = 'linux/releases/linux-v1.2.3/OpenBurnBar-1.2.3-x86_64.AppImage';
  const bytes = 'immutable release bytes';
  const sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  const put = (body, digest = sha256) => request(bucket, '/linux/repository-upload/immutable', {
    method: 'PUT',
    headers: uploadAuthHeaders({
      'Content-Type': 'application/octet-stream',
      'Content-Length': String(Buffer.byteLength(body)),
      'X-OpenBurnBar-Object-Key': key,
      'X-OpenBurnBar-Object-Sha256': digest
    }),
    body
  });
  assert.equal((await put(bytes)).status, 201);
  assert.equal((await put(bytes)).status, 200);
  const altered = 'immutable release bytez';
  assert.equal(Buffer.byteLength(altered), Buffer.byteLength(bytes));
  assert.equal((await put(altered, crypto.createHash('sha256').update(altered).digest('hex'))).status, 409);
  assert.equal(await bucket.text(key), bytes);
  assert.equal((await request(bucket, '/linux/repository-upload/immutable', {
    method: 'PUT', headers: uploadAuthHeaders({ 'Content-Length': '1', 'X-OpenBurnBar-Object-Key': 'latest-linux.json',
      'X-OpenBurnBar-Object-Sha256': 'a'.repeat(64) }), body: 'x'
  })).status, 400);
  assert.equal((await request(bucket, '/linux/repository-admin/immutable', {
    method: 'PUT', headers: authHeaders(), body: 'x'
  })).status, 404);
});

test('immutable upload verifies small legacy bytes without mutation and rejects unknown large or drifted objects', async () => {
  const bucket = new FakeR2();
  const key = 'linux/releases/linux-v1.2.3/legacy.bin';
  const bytes = 'legacy exact bytes';
  const sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  bucket.seed(key, bytes);
  const upload = (uploadKey, body, digest, size = Buffer.byteLength(body)) => request(bucket,
    '/linux/repository-upload/immutable', {
      method: 'PUT',
      headers: uploadAuthHeaders({
        'Content-Type': 'application/octet-stream',
        'Content-Length': String(size),
        'X-OpenBurnBar-Object-Key': uploadKey,
        'X-OpenBurnBar-Object-Sha256': digest
      }),
      body
    });
  const adopted = await upload(key, bytes, sha256);
  assert.equal(adopted.status, 200);
  assert.equal((await adopted.json()).status, 'verified-legacy');
  assert.deepEqual((await bucket.head(key)).customMetadata, {});
  assert.equal((await upload(key, 'legacy drift bytez', crypto.createHash('sha256').update('legacy drift bytez').digest('hex'))).status, 409);

  const largeKey = 'linux/releases/linux-v1.2.3/large.bin';
  bucket.seedSized(largeKey, 8 * 1024 * 1024 + 1);
  assert.equal((await upload(largeKey, 'x', crypto.createHash('sha256').update('x').digest('hex'), 8 * 1024 * 1024 + 1)).status, 409);
  assert.equal((await request(bucket, '/linux/repository-upload/immutable', {
    method: 'PUT', headers: authHeaders()
  })).status, 401);
});

test('worker roles isolate upload, control, serving, preview, and feed surfaces', async () => {
  const bucket = new FakeR2();
  const cases = [
    ['serving', '/linux/repository-admin/status?channel=stable'],
    ['serving', '/linux/repository-upload/immutable'],
    ['control', '/linux/apt/dists/stable/InRelease'],
    ['control', '/latest-linux.json'],
    ['control', '/linux/update/stable/latest-linux.json'],
    ['serving', '/linux/update/stable/latest-linux.json'],
    ['upload', '/linux/update/stable/latest-linux.json'],
    ['upload', '/linux/repository-admin/status?channel=stable'],
    ['feed', '/linux/apt/dists/stable/InRelease']
  ];
  for (const [role, path] of cases) {
    assert.equal((await requestAsRole(bucket, role, path, { headers: authHeaders() })).status, 404, `${role} ${path}`);
  }
  assert.equal((await requestAsRole(bucket, 'invalid', '/linux/apt/dists/stable/InRelease')).status, 500);
});

test('snapshot preview supports first cutover without a pointer and rejects unsafe or cross-channel paths', async () => {
  const bucket = new FakeR2();
  const snapshot = await seedSnapshot(bucket, { channel: 'stable', version: '1.2.3' });
  const base = `/linux/repository-preview/stable/${snapshot.id}`;
  const preview = await request(bucket, `${base}/apt/dists/stable/InRelease`);
  assert.equal(preview.status, 200);
  assert.equal(await preview.text(), 'snapshot:apt/dists/stable/InRelease\n');
  assert.equal(preview.headers.get('cache-control'), 'public, max-age=31536000, immutable');
  assert.equal(preview.headers.get('x-openburnbar-repository-snapshot'), snapshot.id);
  assert.equal((await request(bucket, `${base}/apt/dists/nightly/InRelease`)).status, 404);
  assert.equal((await request(bucket, `${base}/apt/openburnbar-nightly.sources`)).status, 404);
  assert.equal((await request(bucket, `${base}/../apt/dists/stable/InRelease`)).status, 404);
  assert.equal((await request(bucket, `${base}/apt/%2e%2e/secret`)).status, 404);
  assert.equal((await request(bucket, `${base}/repository-closure.json`)).status, 404);
});

test('activation validates exact input, content type, closure identity, hash, and signature', async () => {
  const bucket = new FakeR2();
  const snapshot = await seedSnapshot(bucket, { channel: 'stable', version: '1.2.3' });
  const valid = activationBody(snapshot);
  assert.equal((await activate(bucket, { ...valid, extra: true })).status, 400);
  for (const invalid of [
    { ...valid, expectedCurrentGeneration: 1, expectedCurrentPointerEtag: null },
    { ...valid, expectedCurrentGeneration: null, expectedCurrentPointerEtag: `"${'a'.repeat(64)}"` },
    { ...valid, expectedCurrentSnapshotId: 'a'.repeat(64) }
  ]) {
    assert.equal((await activate(bucket, invalid)).status, 400, JSON.stringify(invalid));
  }
  assert.equal((await request(bucket, '/linux/repository-admin/activate', {
    method: 'POST', headers: authHeaders(), body: JSON.stringify(valid)
  })).status, 415);

  const wrongIdentity = await seedSnapshot(bucket, { channel: 'prerelease', version: '2.0.0' });
  assert.equal((await activate(bucket, {
    ...activationBody(wrongIdentity), version: '2.0.1'
  })).status, 409);

  const missingSignature = await seedSnapshot(bucket, { channel: 'nightly', version: '3.0.0', signature: false });
  assert.equal((await activate(bucket, activationBody(missingSignature))).status, 409);

  const incomplete = await seedSnapshot(bucket, { channel: 'stable', version: '4.0.0', commit: 'c'.repeat(40) });
  bucket.delete(`linux/repository-snapshots/stable/${incomplete.id}/apt/dists/stable/Release.gpg`);
  assert.equal((await activate(bucket, activationBody(incomplete))).status, 409);

  const corrupted = await seedSnapshot(bucket, { channel: 'stable', version: '4.1.0', commit: 'e'.repeat(40) });
  const corruptKey = `linux/repository-snapshots/stable/${corrupted.id}/apt/dists/stable/Release.gpg`;
  const originalSize = (await bucket.head(corruptKey)).size;
  bucket.seed(corruptKey, 'x'.repeat(originalSize));
  const corruptResponse = await activate(bucket, activationBody(corrupted));
  assert.equal(corruptResponse.status, 409);
  assert.match((await corruptResponse.json()).error, /hash does not match/u);

  const expiring = await seedSnapshot(bucket, { channel: 'stable', version: '5.0.0', commit: 'd'.repeat(40),
    validUntil: '2026-07-10T18:00:00.000Z' });
  const expiringResponse = await activate(bucket, activationBody(expiring));
  assert.equal(expiringResponse.status, 409);
  assert.match((await expiringResponse.json()).error, /less than 24 hours/u);

  const wrongHash = `${snapshot.id.slice(0, -1)}${snapshot.id.endsWith('0') ? '1' : '0'}`;
  bucket.copy(snapshot.closureKey, `linux/repository-snapshots/stable/${wrongHash}/repository-closure.json`);
  bucket.seed(`linux/repository-snapshots/stable/${wrongHash}/repository-closure.json.asc`, 'signature');
  assert.equal((await activate(bucket, { ...valid, targetSnapshotId: wrongHash })).status, 409);
});

test('activation requires closure-matching SHA-256 metadata for every object larger than 8 MiB', async () => {
  const acceptedBucket = new FakeR2();
  const accepted = await seedSnapshot(acceptedBucket, {
    channel: 'stable', version: '6.0.0', largeObjectMetadata: 'matching'
  });
  assert.equal((await activate(acceptedBucket, activationBody(accepted))).status, 200);

  for (const mode of ['missing', 'drifted']) {
    const bucket = new FakeR2();
    const snapshot = await seedSnapshot(bucket, {
      channel: 'stable', version: mode === 'missing' ? '6.0.1' : '6.0.2',
      commit: mode === 'missing' ? 'b'.repeat(40) : 'c'.repeat(40),
      largeObjectMetadata: mode
    });
    const response = await activate(bucket, activationBody(snapshot));
    assert.equal(response.status, 409, mode);
    assert.match((await response.json()).error, /large-object integrity metadata/u, mode);
  }
});

test('logical and storage-level compare-and-swap reject stale or concurrent activations', async () => {
  const bucket = new FakeR2();
  const first = await seedSnapshot(bucket, { channel: 'stable', version: '1.0.0' });
  const second = await seedSnapshot(bucket, { channel: 'stable', version: '1.1.0', commit: 'b'.repeat(40) });
  assert.equal((await activate(bucket, activationBody(first))).status, 200);
  assert.equal((await activate(bucket, activationBody(second))).status, 409);

  const identity = await currentPointerIdentity(bucket, 'stable');
  const staleGeneration = await activate(bucket, {
    ...activationBody(second),
    expectedCurrentSnapshotId: first.id,
    expectedCurrentGeneration: identity.generation + 1,
    expectedCurrentPointerEtag: identity.etag
  });
  assert.equal(staleGeneration.status, 409);
  assert.equal((await staleGeneration.json()).currentGeneration, identity.generation);
  const staleEtag = await activate(bucket, {
    ...activationBody(second),
    expectedCurrentSnapshotId: first.id,
    expectedCurrentGeneration: identity.generation,
    expectedCurrentPointerEtag: `"${'f'.repeat(64)}"`
  });
  assert.equal(staleEtag.status, 409);
  assert.equal((await staleEtag.json()).currentPointerEtag, identity.etag);

  const before = JSON.parse(await bucket.text('linux/repository-activations/stable.json'));
  bucket.beforeConditionalPut = (key) => {
    if (key !== 'linux/repository-activations/stable.json') return;
    bucket.beforeConditionalPut = null;
    const competing = { ...before, generation: before.generation + 1, reason: 'competing activation won' };
    bucket.seed(key, `${JSON.stringify(competing)}\n`);
  };
  const raced = await activate(bucket, {
    ...activationBody(second), expectedCurrentSnapshotId: first.id
  });
  assert.equal(raced.status, 409);
  assert.match((await raced.json()).error, /concurrent/u);
  assert.equal(JSON.parse(await bucket.text('linux/repository-activations/stable.json')).reason, 'competing activation won');
});

test('successful forward activation and rollback advance generation and preserve the prior snapshot', async () => {
  const bucket = new FakeR2();
  const first = await seedSnapshot(bucket, { channel: 'stable', version: '1.0.0' });
  const second = await seedSnapshot(bucket, { channel: 'stable', version: '1.1.0', commit: 'b'.repeat(40) });
  assert.equal((await activate(bucket, activationBody(first))).status, 200);

  const forward = await activate(bucket, {
    ...activationBody(second), expectedCurrentSnapshotId: first.id
  });
  assert.equal(forward.status, 200);
  const forwardRecord = (await forward.json()).activation;
  assert.equal(forwardRecord.generation, 2);
  assert.equal(forwardRecord.snapshotId, second.id);
  assert.equal(forwardRecord.previousSnapshotId, first.id);

  const replay = await activate(bucket, {
    ...activationBody(first), expectedCurrentSnapshotId: second.id
  });
  assert.equal(replay.status, 409);
  assert.match((await replay.json()).error, /strictly newer/u);

  const rollback = await activate(bucket, {
    ...activationBody(first),
    mode: 'rollback',
    expectedCurrentSnapshotId: second.id,
    reason: 'Rollback OpenBurnBar after verified release regression'
  });
  assert.equal(rollback.status, 200);
  const rollbackRecord = (await rollback.json()).activation;
  assert.equal(rollbackRecord.generation, 3);
  assert.equal(rollbackRecord.snapshotId, first.id);
  assert.equal(rollbackRecord.previousSnapshotId, second.id);
});

test('feed publication validates immutable identity, uses CAS, and serves only while repository binding is exact', async () => {
  const bucket = new FakeR2();
  const snapshot = await seedSnapshot(bucket, { channel: 'stable', version: '1.2.3' });
  const activated = await activate(bucket, activationBody(snapshot));
  const activation = await activated.json();
  const publication = await seedFeedBundle(bucket, snapshot, activation.pointerEtag, {
    notes: 'Security and reliability fixes.'
  });

  const published = await publishFeed(bucket, publication);
  assert.equal(published.status, 200);
  const publishedBody = await published.json();
  assert.equal(publishedBody.feed.generation, 1);
  assert.equal(publishedBody.feed.repository.snapshotId, snapshot.id);
  assert.equal(publishedBody.feed.previousFeed, null);
  assert.equal(published.headers.get('etag'), publishedBody.pointerEtag);

  const status = await request(bucket, '/linux/repository-admin/feed-status?channel=stable', { headers: authHeaders() });
  assert.equal(status.status, 200);
  assert.equal((await status.json()).feed.feed.key, publication.feed.key);
  const publicFeed = await request(bucket, '/latest-linux.json');
  assert.equal(publicFeed.status, 200);
  assert.equal((await publicFeed.json()).version, '1.2.3');
  assert.equal((await (await request(bucket, '/latest-linux.json')).json()).notes,
    'Security and reliability fixes.');
  assert.equal(publicFeed.headers.get('x-openburnbar-repository-snapshot'), snapshot.id);
  assert.equal(publicFeed.headers.get('x-openburnbar-feed-generation'), '1');
  assert.equal((await request(bucket, '/latest-linux.json.ed25519.sig')).status, 200);
  assert.equal((await (await request(bucket, '/linux/update/stable/latest-linux.json')).json()).version, '1.2.3');
  assert.equal((await request(bucket, '/linux/update/stable/latest-linux.json.ed25519.sig')).status, 200);
  assert.equal((await request(bucket, '/latest-linux.json', { method: 'HEAD' })).status, 200);
  assert.equal((await request(bucket, '/latest-linux.json?cache=1')).status, 404);
  assert.equal((await request(bucket, '/latest-linux.json/extra')).status, 404);
  assert.equal((await request(bucket, '/linux/update/unknown/latest-linux.json')).status, 404);
  assert.equal((await request(bucket, '/linux/update/stable/latest-linux.json/extra')).status, 404);
  assert.equal((await request(bucket, '/linux/update/stable/latest-linux.json?cache=1')).status, 404);

  assert.equal((await publishFeed(bucket, publication)).status, 409);
  const second = await seedSnapshot(bucket, { channel: 'stable', version: '1.3.0', commit: 'b'.repeat(40) });
  const secondActivation = await activate(bucket, { ...activationBody(second), expectedCurrentSnapshotId: snapshot.id });
  assert.equal(secondActivation.status, 200);
  const secondActivationBody = await secondActivation.json();
  const stale = await request(bucket, '/latest-linux.json');
  assert.equal(stale.status, 503);
  assert.match((await stale.json()).error, /does not match/u);

  const replacement = await seedFeedBundle(bucket, second, secondActivationBody.pointerEtag, {
    repositoryGeneration: 2,
    expectedCurrent: { generation: 1, etag: publishedBody.pointerEtag }
  });
  const republished = await publishFeed(bucket, replacement);
  assert.equal(republished.status, 200);
  const replacementBody = await republished.json();
  assert.equal(replacementBody.feed.generation, 2);
  assert.equal(replacementBody.feed.previousFeed.version, snapshot.version);
  assert.equal(replacementBody.feed.previousFeed.feed.sha256, publication.feed.sha256);
  assert.equal((await (await request(bucket, '/latest-linux.json')).json()).version, '1.3.0');
});

test('feed rebind swaps the retained feed across repository rollback and forward recovery', async () => {
  const bucket = new FakeR2();
  const first = await seedSnapshot(bucket, { channel: 'stable', version: '1.0.0' });
  const firstActivation = await (await activate(bucket, activationBody(first))).json();
  const firstPublication = await seedFeedBundle(bucket, first, firstActivation.pointerEtag);
  const firstFeed = await (await publishFeed(bucket, firstPublication)).json();

  const second = await seedSnapshot(bucket, { channel: 'stable', version: '1.1.0', commit: 'b'.repeat(40) });
  const secondActivation = await (await activate(bucket, {
    ...activationBody(second), expectedCurrentSnapshotId: first.id
  })).json();
  const secondPublication = await seedFeedBundle(bucket, second, secondActivation.pointerEtag, {
    repositoryGeneration: 2,
    expectedCurrent: { generation: 1, etag: firstFeed.pointerEtag }
  });
  const secondFeed = await (await publishFeed(bucket, secondPublication)).json();

  const rollback = await (await activate(bucket, {
    ...activationBody(first),
    mode: 'rollback',
    expectedCurrentSnapshotId: second.id,
    reason: 'Rollback repository and restore its retained signed feed'
  })).json();
  assert.equal((await request(bucket, '/latest-linux.json')).status, 503);
  const reboundFirst = await rebindFeed(bucket, {
    schemaVersion: 1,
    channel: 'stable',
    target: 'previous',
    expectedCurrent: { generation: 2, etag: secondFeed.pointerEtag },
    expectedRepository: {
      generation: rollback.activation.generation,
      snapshotId: rollback.activation.snapshotId,
      pointerEtag: rollback.pointerEtag
    },
    actor: 'release-engineer',
    runUrl: RUN_URL,
    reason: 'Rebind retained feed after repository rollback verification'
  });
  assert.equal(reboundFirst.status, 200);
  const reboundFirstBody = await reboundFirst.json();
  assert.equal(reboundFirstBody.status, 'rebound');
  assert.equal(reboundFirstBody.feed.version, first.version);
  assert.equal(reboundFirstBody.feed.previousFeed.version, second.version);
  assert.equal((await (await request(bucket, '/latest-linux.json')).json()).version, first.version);

  const forward = await (await activate(bucket, {
    ...activationBody(second), expectedCurrentSnapshotId: first.id
  })).json();
  const reboundSecond = await rebindFeed(bucket, {
    schemaVersion: 1,
    channel: 'stable',
    target: 'previous',
    expectedCurrent: { generation: 3, etag: reboundFirstBody.pointerEtag },
    expectedRepository: {
      generation: forward.activation.generation,
      snapshotId: forward.activation.snapshotId,
      pointerEtag: forward.pointerEtag
    },
    actor: 'release-engineer',
    runUrl: RUN_URL,
    reason: 'Rebind retained candidate feed after forward recovery verification'
  });
  assert.equal(reboundSecond.status, 200);
  assert.equal((await (await request(bucket, '/latest-linux.json')).json()).version, second.version);
});

test('interleaved channel publications and rollback keep CAS generations, history, and public routes isolated', async () => {
  const bucket = new FakeR2();
  const definitions = [
    ['prerelease', '2.0.0', 'b'],
    ['stable', '1.0.0', 'a'],
    ['nightly', '3.0.0', 'c']
  ];
  const state = new Map();

  for (const [channel, version, commitCharacter] of definitions) {
    const snapshot = await seedSnapshot(bucket, {
      channel,
      version,
      commit: commitCharacter.repeat(40)
    });
    const activation = await (await activate(bucket, activationBody(snapshot))).json();
    const publication = await seedFeedBundle(bucket, snapshot, activation.pointerEtag);
    const response = await publishFeed(bucket, publication);
    assert.equal(response.status, 200, channel);
    const published = await response.json();
    assert.equal(published.feed.generation, 1, channel);
    assert.equal(published.feed.previousFeed, null, channel);
    state.set(channel, { snapshot, activation, publication, published });
  }

  assert.deepEqual(
    [...bucket.keys()].filter((key) => key.startsWith('linux/update-feed-activations/')).sort(),
    [
      'linux/update-feed-activations/nightly.json',
      'linux/update-feed-activations/prerelease.json',
      'linux/update-feed-activations/stable.json'
    ]
  );
  for (const [channel, version] of definitions) {
    const status = await request(bucket, `/linux/repository-admin/feed-status?channel=${channel}`, {
      headers: authHeaders()
    });
    assert.equal(status.status, 200, channel);
    const statusBody = await status.json();
    assert.equal(statusBody.feed.channel, channel);
    assert.equal(statusBody.feed.version, version);
    assert.equal(statusBody.feed.generation, 1);
    const publicFeed = await request(bucket, `/linux/update/${channel}/latest-linux.json`);
    assert.equal(publicFeed.status, 200, channel);
    assert.equal((await publicFeed.json()).version, version, channel);
    assert.equal(publicFeed.headers.get('x-openburnbar-feed-generation'), '1');
  }
  assert.equal((await (await request(bucket, '/latest-linux.json')).json()).version, '1.0.0');

  const firstPrerelease = state.get('prerelease');
  const nextPrerelease = await seedSnapshot(bucket, {
    channel: 'prerelease',
    version: '2.1.0',
    commit: 'd'.repeat(40)
  });
  const nextActivation = await (await activate(bucket, {
    ...activationBody(nextPrerelease),
    expectedCurrentSnapshotId: firstPrerelease.snapshot.id
  })).json();
  const nextPublication = await seedFeedBundle(bucket, nextPrerelease, nextActivation.pointerEtag, {
    repositoryGeneration: 2,
    expectedCurrent: {
      generation: firstPrerelease.published.feed.generation,
      etag: firstPrerelease.published.pointerEtag
    }
  });
  const nextFeed = await (await publishFeed(bucket, nextPublication)).json();
  assert.equal(nextFeed.feed.generation, 2);
  assert.equal(nextFeed.feed.previousFeed.channel, 'prerelease');
  assert.equal(nextFeed.feed.previousFeed.version, '2.0.0');
  assert.equal((await (await request(bucket, '/linux/update/prerelease/latest-linux.json')).json()).version, '2.1.0');
  assert.equal((await (await request(bucket, '/linux/update/stable/latest-linux.json')).json()).version, '1.0.0');
  assert.equal((await (await request(bucket, '/linux/update/nightly/latest-linux.json')).json()).version, '3.0.0');

  const repositoryRollback = await (await activate(bucket, {
    ...activationBody(firstPrerelease.snapshot),
    mode: 'rollback',
    expectedCurrentSnapshotId: nextPrerelease.id,
    reason: 'Rollback prerelease without mutating stable or nightly feed state'
  })).json();
  const rebound = await rebindFeed(bucket, {
    schemaVersion: 1,
    channel: 'prerelease',
    target: 'previous',
    expectedCurrent: { generation: 2, etag: nextFeed.pointerEtag },
    expectedRepository: {
      generation: repositoryRollback.activation.generation,
      snapshotId: repositoryRollback.activation.snapshotId,
      pointerEtag: repositoryRollback.pointerEtag
    },
    actor: 'release-engineer',
    runUrl: RUN_URL,
    reason: 'Rebind only prerelease retained feed after verified rollback'
  });
  assert.equal(rebound.status, 200);
  const reboundBody = await rebound.json();
  assert.equal(reboundBody.feed.generation, 3);
  assert.equal(reboundBody.feed.channel, 'prerelease');
  assert.equal(reboundBody.feed.version, '2.0.0');
  assert.equal(reboundBody.feed.previousFeed.channel, 'prerelease');
  assert.equal(reboundBody.feed.previousFeed.version, '2.1.0');

  for (const [channel, generation, version] of [
    ['stable', 1, '1.0.0'],
    ['prerelease', 3, '2.0.0'],
    ['nightly', 1, '3.0.0']
  ]) {
    const pointer = JSON.parse(await bucket.text(`linux/update-feed-activations/${channel}.json`));
    assert.equal(pointer.channel, channel);
    assert.equal(pointer.generation, generation);
    assert.equal(pointer.version, version);
    assert.equal((await (await request(bucket, `/linux/update/${channel}/latest-linux.json`)).json()).version, version);
  }
  assert.equal((await (await request(bucket, '/latest-linux.json')).json()).version, '1.0.0');
});

test('a valid feed record stored under another channel key fails closed without affecting its owner', async () => {
  const bucket = new FakeR2();
  const stable = await seedSnapshot(bucket, { channel: 'stable', version: '1.0.0' });
  await activate(bucket, activationBody(stable));
  const prerelease = await seedSnapshot(bucket, {
    channel: 'prerelease',
    version: '2.0.0',
    commit: 'b'.repeat(40)
  });
  const prereleaseActivation = await (await activate(bucket, activationBody(prerelease))).json();
  const prereleasePublication = await seedFeedBundle(bucket, prerelease, prereleaseActivation.pointerEtag);
  assert.equal((await publishFeed(bucket, prereleasePublication)).status, 200);
  bucket.copy(
    'linux/update-feed-activations/prerelease.json',
    'linux/update-feed-activations/stable.json'
  );

  const stableStatus = await request(bucket, '/linux/repository-admin/feed-status?channel=stable', {
    headers: authHeaders()
  });
  assert.equal(stableStatus.status, 503);
  assert.equal((await request(bucket, '/latest-linux.json')).status, 503);
  assert.equal((await request(bucket, '/linux/update/stable/latest-linux.json')).status, 503);
  const prereleaseFeed = await request(bucket, '/linux/update/prerelease/latest-linux.json');
  assert.equal(prereleaseFeed.status, 200);
  assert.equal((await prereleaseFeed.json()).version, '2.0.0');
});

test('feed rebind rejects stale CAS identities, invalid selection, and a repository race', async () => {
  const bucket = new FakeR2();
  const snapshot = await seedSnapshot(bucket, { channel: 'stable', version: '4.0.0' });
  const activation = await (await activate(bucket, activationBody(snapshot))).json();
  const publication = await seedFeedBundle(bucket, snapshot, activation.pointerEtag);
  const feed = await (await publishFeed(bucket, publication)).json();
  const body = {
    schemaVersion: 1,
    channel: 'stable',
    target: 'current',
    expectedCurrent: { generation: 1, etag: feed.pointerEtag },
    expectedRepository: { generation: 1, snapshotId: snapshot.id, pointerEtag: activation.pointerEtag },
    actor: 'release-engineer',
    runUrl: RUN_URL,
    reason: 'Rebind current feed after equivalent repository pointer refresh'
  };
  assert.equal((await rebindFeed(bucket, { ...body, extra: true })).status, 400);
  assert.equal((await rebindFeed(bucket, {
    ...body, expectedCurrent: { generation: 2, etag: feed.pointerEtag }
  })).status, 409);
  assert.equal((await rebindFeed(bucket, {
    ...body, expectedRepository: { ...body.expectedRepository, generation: 2 }
  })).status, 409);
  assert.equal((await rebindFeed(bucket, { ...body, target: 'previous' })).status, 409);

  const reboundCurrent = await rebindFeed(bucket, body);
  assert.equal(reboundCurrent.status, 200);
  const reboundCurrentBody = await reboundCurrent.json();
  assert.equal(reboundCurrentBody.feed.version, snapshot.version);
  assert.equal(reboundCurrentBody.feed.previousFeed, null);
  const raceBody = {
    ...body,
    expectedCurrent: { generation: 2, etag: reboundCurrentBody.pointerEtag }
  };

  bucket.beforeConditionalPut = (key) => {
    if (key !== 'linux/update-feed-activations/stable.json') return;
    bucket.beforeConditionalPut = null;
    const repositoryKey = 'linux/repository-activations/stable.json';
    const record = JSON.parse(bucket.textSync(repositoryKey));
    bucket.seed(repositoryKey, `${JSON.stringify({ ...record, generation: 2 })}\n`);
  };
  const raced = await rebindFeed(bucket, raceBody);
  assert.equal(raced.status, 409);
  assert.match((await raced.json()).error, /changed during/u);
  assert.equal((await request(bucket, '/latest-linux.json')).status, 503);
});

test('feed publication verifies pinned identity, Ed25519 bytes, and artifact R2 metadata', async () => {
  async function fixture(version) {
    const bucket = new FakeR2();
    const snapshot = await seedSnapshot(bucket, { channel: 'stable', version });
    const activation = await (await activate(bucket, activationBody(snapshot))).json();
    return { bucket, publication: await seedFeedBundle(bucket, snapshot, activation.pointerEtag) };
  }

  {
    const { bucket, publication } = await fixture('5.0.0');
    const document = JSON.parse(await bucket.text(publication.feed.key));
    document.signature.publicKeySpkiSha256 = 'f'.repeat(64);
    await replaceSignedFeed(bucket, publication, document);
    const response = await publishFeed(bucket, publication);
    assert.equal(response.status, 409);
    assert.match((await response.json()).error, /signature identity/u);
  }
  {
    const { bucket, publication } = await fixture('5.0.1');
    const bogus = crypto.randomBytes(64);
    bucket.seed(publication.feed.signatureKey, bogus);
    publication.feed.signatureSha256 = crypto.createHash('sha256').update(bogus).digest('hex');
    const response = await publishFeed(bucket, publication);
    assert.equal(response.status, 409);
    assert.match((await response.json()).error, /signature verification failed/u);
  }
  for (const [mode, version] of [['missing', '5.0.2'], ['metadata', '5.0.3'], ['size', '5.0.4']]) {
    const { bucket, publication } = await fixture(version);
    const document = JSON.parse(await bucket.text(publication.feed.key));
    const artifact = document.artifacts[0];
    const key = new URL(artifact.url).pathname.slice(1);
    if (mode === 'missing') bucket.delete(key);
    else if (mode === 'metadata') bucket.seed(key, Buffer.alloc(artifact.size), {}, { sha256: '0'.repeat(64) });
    else bucket.seed(key, Buffer.alloc(artifact.size + 1), {}, { sha256: artifact.sha256 });
    const response = await publishFeed(bucket, publication);
    assert.equal(response.status, 409, mode);
    assert.match((await response.json()).error, /artifact is missing or integrity metadata drifted/u, mode);
  }
});

test('feed publication rejects malformed bundles and fails closed when repository changes during pointer CAS', async () => {
  const bucket = new FakeR2();
  const snapshot = await seedSnapshot(bucket, { channel: 'stable', version: '2.0.0' });
  const activation = await (await activate(bucket, activationBody(snapshot))).json();
  const publication = await seedFeedBundle(bucket, snapshot, activation.pointerEtag);

  const feedDocument = JSON.parse(await bucket.text(publication.feed.key));
  feedDocument.artifacts[0].url = 'https://attacker.example/OpenBurnBar.AppImage';
  const drift = `${JSON.stringify(feedDocument)}\n`;
  bucket.seed(publication.feed.key, drift, { contentType: 'application/json; charset=utf-8' });
  publication.feed.sha256 = crypto.createHash('sha256').update(drift).digest('hex');
  publication.feed.size = Buffer.byteLength(drift);
  const invalid = await publishFeed(bucket, publication);
  assert.equal(invalid.status, 409);
  assert.match((await invalid.json()).error, /invalid artifact/u);

  const valid = await seedFeedBundle(bucket, snapshot, activation.pointerEtag);
  bucket.beforeConditionalPut = (key) => {
    if (key !== 'linux/update-feed-activations/stable.json') return;
    bucket.beforeConditionalPut = null;
    const repositoryKey = 'linux/repository-activations/stable.json';
    const record = JSON.parse(bucket.textSync(repositoryKey));
    bucket.seed(repositoryKey, `${JSON.stringify({ ...record, generation: record.generation + 1 })}\n`);
  };
  const raced = await publishFeed(bucket, valid);
  assert.equal(raced.status, 409);
  assert.match((await raced.json()).error, /changed during/u);
  assert.equal((await request(bucket, '/latest-linux.json')).status, 503);
});

test('feed pointer storage CAS rejects a concurrent winner after validation', async () => {
  const bucket = new FakeR2();
  const snapshot = await seedSnapshot(bucket, { channel: 'stable', version: '3.0.0' });
  const activation = await (await activate(bucket, activationBody(snapshot))).json();
  const first = await seedFeedBundle(bucket, snapshot, activation.pointerEtag);
  const firstResponse = await publishFeed(bucket, first);
  const firstState = await firstResponse.json();
  const retry = {
    ...first,
    expectedCurrent: { generation: 1, etag: firstState.pointerEtag }
  };
  bucket.beforeConditionalPut = (key) => {
    if (key !== 'linux/update-feed-activations/stable.json') return;
    bucket.beforeConditionalPut = null;
    const current = JSON.parse(bucket.textSync(key));
    bucket.seed(key, `${JSON.stringify({ ...current, generation: 2, publishedAt: '2026-07-10T11:30:00.000Z' })}\n`);
  };
  const response = await publishFeed(bucket, retry);
  assert.equal(response.status, 409);
  assert.match((await response.json()).error, /concurrent/u);
  assert.equal(JSON.parse(await bucket.text('linux/update-feed-activations/stable.json')).generation, 2);
});

test('apt mutable roots and bootstrap route through the pointer while by-hash and pool stay shared', async () => {
  const bucket = new FakeR2();
  const snapshot = await seedSnapshot(bucket, { channel: 'stable', version: '1.2.3' });
  const prefix = `linux/repository-snapshots/stable/${snapshot.id}`;
  bucket.seed(`${prefix}/apt/dists/stable/main/binary-amd64/Packages.gz`, 'snapshot-packages');
  const digest = 'c'.repeat(64);
  bucket.seed(`linux/apt/dists/stable/main/binary-amd64/by-hash/SHA256/${digest}`, 'old-index');
  bucket.seed('linux/apt/pool/main/o/openburnbar/OpenBurnBar_1.2.3_amd64.deb', 'deb-bytes');
  await activate(bucket, activationBody(snapshot));

  const root = await request(bucket, '/linux/apt/dists/stable/InRelease');
  assert.equal(root.status, 200);
  assert.equal(await root.text(), 'snapshot:apt/dists/stable/InRelease\n');
  assert.equal(root.headers.get('cache-control'), 'no-cache, must-revalidate');
  assert.equal(root.headers.get('x-openburnbar-repository-snapshot'), snapshot.id);
  assert.equal(await (await request(bucket, '/linux/apt/dists/stable/main/binary-amd64/Packages.gz')).text(), 'snapshot-packages');

  const byHash = await request(bucket, `/linux/apt/dists/stable/main/binary-amd64/by-hash/SHA256/${digest}`);
  assert.equal(await byHash.text(), 'old-index');
  assert.equal(byHash.headers.get('cache-control'), 'public, max-age=31536000, immutable');
  assert.equal(await (await request(bucket, '/linux/apt/pool/main/o/openburnbar/OpenBurnBar_1.2.3_amd64.deb')).text(), 'deb-bytes');
  const sources = await request(bucket, '/linux/apt/openburnbar-stable.sources');
  assert.equal(await sources.text(), 'snapshot:apt/openburnbar-stable.sources\n');
  assert.equal(sources.headers.get('cache-control'), 'public, max-age=300, must-revalidate');
  assert.equal(sources.headers.get('x-openburnbar-repository-snapshot'), snapshot.id);
  assert.equal(await (await request(bucket, '/linux/apt/openburnbar-archive-keyring.gpg')).text(),
    'snapshot:apt/openburnbar-archive-keyring.gpg\n');
  assert.equal(await (await request(bucket, '/linux/apt/openburnbar-stable-archive-keyring.gpg')).text(),
    'snapshot:apt/openburnbar-archive-keyring.gpg\n');
});

test('rpm repomd routes through the pointer while checksum metadata and packages stay shared', async () => {
  const bucket = new FakeR2();
  const snapshot = await seedSnapshot(bucket, { channel: 'prerelease', version: '2.0.0' });
  const prefix = `linux/repository-snapshots/prerelease/${snapshot.id}`;
  const primary = `${'d'.repeat(64)}-primary.xml.gz`;
  bucket.seed(`linux/rpm/prerelease/x86_64/repodata/${primary}`, 'primary');
  bucket.seed('linux/rpm/prerelease/x86_64/OpenBurnBar-2.0.0-1.x86_64.rpm', 'rpm');
  await activate(bucket, activationBody(snapshot));

  const repomd = await request(bucket, '/linux/rpm/prerelease/x86_64/repodata/repomd.xml');
  assert.equal(await repomd.text(), 'snapshot:rpm/prerelease/x86_64/repodata/repomd.xml\n');
  assert.equal(repomd.headers.get('x-openburnbar-repository-snapshot'), snapshot.id);
  assert.equal(await (await request(bucket, `/linux/rpm/prerelease/x86_64/repodata/${primary}`)).text(), 'primary');
  assert.equal(await (await request(bucket, '/linux/rpm/prerelease/x86_64/OpenBurnBar-2.0.0-1.x86_64.rpm')).text(), 'rpm');
  assert.equal(await (await request(bucket, '/linux/rpm/openburnbar-prerelease.repo')).text(),
    'snapshot:rpm/openburnbar-prerelease.repo\n');
  const key = await request(bucket, '/linux/rpm/RPM-GPG-KEY-openburnbar-prerelease');
  assert.equal(await key.text(), 'snapshot:rpm/RPM-GPG-KEY-openburnbar\n');
  assert.equal(key.headers.get('x-openburnbar-repository-snapshot'), snapshot.id);
});

test('public object responses support HEAD, strong ETag conditions, and single byte ranges', async () => {
  const bucket = new FakeR2();
  const key = 'linux/apt/pool/main/o/openburnbar/OpenBurnBar_1.0.0_amd64.deb';
  bucket.seed(key, '0123456789', { contentType: 'application/vnd.debian.binary-package' });
  const path = `/${key}`;
  const full = await request(bucket, path);
  assert.equal(full.status, 200);
  assert.equal(full.headers.get('content-length'), '10');
  const etag = full.headers.get('etag');

  const head = await request(bucket, path, { method: 'HEAD' });
  assert.equal(head.status, 200);
  assert.equal(head.headers.get('content-length'), '10');
  assert.equal(await head.text(), '');
  assert.equal((await request(bucket, path, { headers: { 'If-None-Match': etag } })).status, 304);
  assert.equal((await request(bucket, path, { headers: { 'If-None-Match': `W/${etag}` } })).status, 304);
  assert.equal((await request(bucket, path, { headers: { 'If-Match': '"wrong"' } })).status, 412);
  assert.equal((await request(bucket, path, { headers: { 'If-Match': `W/${etag}` } })).status, 412);

  const range = await request(bucket, path, { headers: { Range: 'bytes=2-5' } });
  assert.equal(range.status, 206);
  assert.equal(await range.text(), '2345');
  assert.equal(range.headers.get('content-range'), 'bytes 2-5/10');
  const suffix = await request(bucket, path, { headers: { Range: 'bytes=-3' } });
  assert.equal(await suffix.text(), '789');
  const staleIfRange = await request(bucket, path, { headers: { Range: 'bytes=2-5', 'If-Range': '"stale"' } });
  assert.equal(staleIfRange.status, 200);
  assert.equal(await staleIfRange.text(), '0123456789');
  assert.equal((await request(bucket, path, { headers: { Range: 'bytes=10-11' } })).status, 416);
  assert.equal((await request(bucket, path, { headers: { Range: 'bytes=0-1,4-5' } })).status, 416);
});

test('strict public path grammar and fail-closed active snapshots reject unsafe or incomplete requests', async () => {
  const bucket = new FakeR2();
  assert.equal((await request(bucket, '/linux/apt/dists/stable/InRelease')).status, 503);
  assert.equal((await request(bucket, '/linux/apt/dists/stable/InRelease?cache=1')).status, 404);
  assert.equal((await request(bucket, '/linux/apt/%2e%2e/secret')).status, 404);
  assert.equal((await request(bucket, '/linux/rpm/stable/x86_64/repodata/not-checksummed.xml.gz')).status, 404);
  assert.equal((await request(bucket, '/linux/rpm/stable/i686/repodata/repomd.xml')).status, 404);
  assert.equal((await request(bucket, '/linux/apt/dists/stable/InRelease', { method: 'POST' })).status, 405);

  const snapshot = await seedSnapshot(bucket, { channel: 'stable', version: '1.0.0' });
  await activate(bucket, activationBody(snapshot));
  bucket.delete(`linux/repository-snapshots/stable/${snapshot.id}/apt/dists/stable/InRelease`);
  const incomplete = await request(bucket, '/linux/apt/dists/stable/InRelease');
  assert.equal(incomplete.status, 503);
  assert.equal(incomplete.headers.get('cache-control'), 'no-store');

  bucket.seed('linux/repository-activations/prerelease.json', '{bad json');
  assert.equal((await request(bucket, '/linux/rpm/prerelease/x86_64/repodata/repomd.xml')).status, 503);
});

async function seedSnapshot(bucket, { channel, version, commit = COMMIT, signature = true,
  validUntil = '2026-07-20T12:00:00.000Z', largeObjectMetadata = null }) {
  const criticalFiles = [
    'apt/openburnbar-archive-keyring.gpg',
    `apt/openburnbar-${channel}.sources`,
    `apt/dists/${channel}/InRelease`,
    `apt/dists/${channel}/Release`,
    `apt/dists/${channel}/Release.gpg`,
    'rpm/RPM-GPG-KEY-openburnbar',
    `rpm/openburnbar-${channel}.repo`,
    `rpm/${channel}/aarch64/repodata/repomd.xml`,
    `rpm/${channel}/aarch64/repodata/repomd.xml.asc`,
    `rpm/${channel}/x86_64/repodata/repomd.xml`,
    `rpm/${channel}/x86_64/repodata/repomd.xml.asc`
  ];
  const files = criticalFiles.map((file) => {
    const bytes = Buffer.from(`snapshot:${file}\n`);
    return { file, sha256: crypto.createHash('sha256').update(bytes).digest('hex'), size: bytes.length, bytes };
  });
  const largeFile = `apt/dists/${channel}/main/binary-amd64/Packages.gz`;
  if (largeObjectMetadata) {
    files.push({
      file: largeFile,
      sha256: 'd'.repeat(64),
      size: 8 * 1024 * 1024 + 1,
      bytes: null
    });
  }
  const closureBytes = Buffer.from(`${JSON.stringify({
    schemaVersion: 1,
    product: 'OpenBurnBar',
    version,
    channel,
    gitCommit: commit,
    repositories: { apt: { validUntil } },
    files: files.map(({ file, sha256, size }) => ({ file, sha256, size }))
  }, null, 2)}\n`);
  const id = crypto.createHash('sha256').update(closureBytes).digest('hex');
  const closureKey = `linux/repository-snapshots/${channel}/${id}/repository-closure.json`;
  bucket.seed(closureKey, closureBytes, { contentType: 'application/json; charset=utf-8' });
  for (const file of files) {
    const key = `linux/repository-snapshots/${channel}/${id}/${file.file}`;
    if (file.file === largeFile && largeObjectMetadata) {
      const sha256 = largeObjectMetadata === 'matching' ? file.sha256
        : largeObjectMetadata === 'drifted' ? 'e'.repeat(64) : undefined;
      bucket.seedSized(key, file.size, sha256 ? { sha256 } : {});
    } else bucket.seed(key, file.bytes);
  }
  if (signature) bucket.seed(`${closureKey}.asc`, 'repository closure signature');
  return { id, channel, version, commit, closureKey };
}

function activationBody(snapshot) {
  return {
    schemaVersion: 1,
    mode: 'promote',
    channel: snapshot.channel,
    targetSnapshotId: snapshot.id,
    expectedCurrentSnapshotId: null,
    expectedCurrentGeneration: null,
    expectedCurrentPointerEtag: null,
    version: snapshot.version,
    sourceCommit: snapshot.commit,
    actor: 'release-engineer',
    runUrl: RUN_URL,
    reason: `Promote OpenBurnBar ${snapshot.version} after repository lifecycle verification`
  };
}

function deactivationBody(snapshot) {
  return {
    schemaVersion: 1,
    channel: snapshot.channel,
    expectedCurrentSnapshotId: snapshot.id,
    expectedCurrentGeneration: undefined,
    expectedCurrentPointerEtag: undefined,
    actor: 'release-engineer',
    runUrl: RUN_URL,
    reason: `Deactivate OpenBurnBar ${snapshot.version} after failed first activation verification`
  };
}

function authHeaders(extra = {}) {
  return { Authorization: `Bearer ${TOKEN}`, ...extra };
}

function uploadAuthHeaders(extra = {}) {
  return { Authorization: `Bearer ${UPLOAD_TOKEN}`, ...extra };
}

async function seedFeedBundle(bucket, snapshot, repositoryPointerEtag, options = {}) {
  const releasePrefix = `linux/releases/linux-v${snapshot.version}`;
  const publicPrefix = `${ORIGIN}/${releasePrefix}`;
  const feed = {
    schemaVersion: 1,
    product: 'OpenBurnBar',
    platform: 'linux',
    version: snapshot.version,
    gitCommit: snapshot.commit,
    publishedAt: '2026-07-10T11:00:00.000Z',
    channel: snapshot.channel,
    artifacts: ['aarch64', 'x86_64'].map((architecture) => {
      const bytes = Buffer.from(`signed artifact:${snapshot.version}:${architecture}\n`);
      const name = `OpenBurnBar-${snapshot.version}-${architecture}.AppImage`;
      return {
        type: 'appimage',
        architecture,
        url: `${publicPrefix}/${name}`,
        sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
        size: bytes.length,
        signatureUrl: `${publicPrefix}/${name}.ed25519.sig`
      };
    }),
    signature: {
      algorithm: 'Ed25519',
      publicKeySpkiSha256: TEST_FEED_FINGERPRINT,
      url: `${publicPrefix}/latest-linux.json.ed25519.sig`
    }
  };
  if (options.notes !== undefined) feed.notes = options.notes;
  const feedBytes = `${JSON.stringify(feed, null, 2)}\n`;
  const signatureBytes = new Uint8Array(await crypto.webcrypto.subtle.sign(
    'Ed25519', TEST_FEED_KEYS.privateKey, new TextEncoder().encode(feedBytes)
  ));
  const key = `${releasePrefix}/latest-linux.json`;
  const signatureKey = `${key}.ed25519.sig`;
  bucket.seed(key, feedBytes, { contentType: 'application/json; charset=utf-8' });
  bucket.seed(signatureKey, signatureBytes, { contentType: 'application/octet-stream' });
  for (const artifact of feed.artifacts) {
    const artifactBytes = Buffer.from(`signed artifact:${snapshot.version}:${artifact.architecture}\n`);
    bucket.seed(new URL(artifact.url).pathname.slice(1), artifactBytes, {}, { sha256: artifact.sha256 });
  }
  return {
    schemaVersion: 1,
    channel: snapshot.channel,
    generation: options.repositoryGeneration ?? 1,
    snapshotId: snapshot.id,
    version: snapshot.version,
    sourceCommit: snapshot.commit,
    repositoryPointerEtag,
    feed: {
      key,
      signatureKey,
      sha256: crypto.createHash('sha256').update(feedBytes).digest('hex'),
      size: Buffer.byteLength(feedBytes),
      signatureSha256: crypto.createHash('sha256').update(signatureBytes).digest('hex'),
      signatureSize: Buffer.byteLength(signatureBytes)
    },
    expectedCurrent: options.expectedCurrent ?? { generation: null, etag: null }
  };
}

async function replaceSignedFeed(bucket, publication, document) {
  const feedBytes = `${JSON.stringify(document, null, 2)}\n`;
  const signatureBytes = new Uint8Array(await crypto.webcrypto.subtle.sign(
    'Ed25519', TEST_FEED_KEYS.privateKey, new TextEncoder().encode(feedBytes)
  ));
  bucket.seed(publication.feed.key, feedBytes, { contentType: 'application/json; charset=utf-8' });
  bucket.seed(publication.feed.signatureKey, signatureBytes, { contentType: 'application/octet-stream' });
  publication.feed.sha256 = crypto.createHash('sha256').update(feedBytes).digest('hex');
  publication.feed.size = Buffer.byteLength(feedBytes);
  publication.feed.signatureSha256 = crypto.createHash('sha256').update(signatureBytes).digest('hex');
  publication.feed.signatureSize = signatureBytes.byteLength;
}

function publishFeed(bucket, body) {
  return request(bucket, '/linux/repository-admin/publish-feed', {
    method: 'POST',
    headers: authHeaders({ 'Content-Type': 'application/json' }),
    body: JSON.stringify(body)
  });
}

function rebindFeed(bucket, body) {
  return request(bucket, '/linux/repository-admin/rebind-feed', {
    method: 'POST',
    headers: authHeaders({ 'Content-Type': 'application/json' }),
    body: JSON.stringify(body)
  });
}

async function activate(bucket, body) {
  const current = await currentPointerIdentity(bucket, body.channel);
  const enriched = { ...body };
  if (current && enriched.expectedCurrentGeneration === null
      && enriched.expectedCurrentPointerEtag === null) {
    enriched.expectedCurrentGeneration = current.generation;
    enriched.expectedCurrentPointerEtag = current.etag;
  }
  return request(bucket, '/linux/repository-admin/activate', {
    method: 'POST',
    headers: authHeaders({ 'Content-Type': 'application/json' }),
    body: JSON.stringify(enriched)
  });
}

async function deactivate(bucket, body) {
  const current = await currentPointerIdentity(bucket, body.channel);
  const enriched = { ...body };
  if (enriched.expectedCurrentGeneration === undefined) enriched.expectedCurrentGeneration = current?.generation ?? null;
  if (enriched.expectedCurrentPointerEtag === undefined) enriched.expectedCurrentPointerEtag = current?.etag ?? null;
  return request(bucket, '/linux/repository-admin/deactivate', {
    method: 'POST',
    headers: authHeaders({ 'Content-Type': 'application/json' }),
    body: JSON.stringify(enriched)
  });
}

async function currentPointerIdentity(bucket, channel) {
  const object = await bucket.get(`linux/repository-activations/${channel}.json`);
  if (!object || !('body' in object)) return null;
  const record = JSON.parse(await object.text());
  return { generation: record.generation, etag: object.httpEtag };
}

function request(bucket, path, init = {}) {
  const role = path.startsWith('/linux/repository-admin/')
    ? 'control'
    : path.startsWith('/linux/repository-upload/') || path.startsWith('/linux/repository-preview/')
      ? 'upload'
      : path.startsWith('/latest-linux.json') || path.startsWith('/linux/update/') ? 'feed' : 'serving';
  return requestAsRole(bucket, role, path, init);
}

function requestAsRole(bucket, role, path, init = {}) {
  return handleRequest(new Request(`${ORIGIN}${path}`, init), {
    REPOSITORY_BUCKET: bucket,
    WORKER_ROLE: role,
    OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN: TOKEN,
    OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN: UPLOAD_TOKEN
  }, {
    now: () => new Date('2026-07-10T12:00:00.000Z'),
    feedVerification: { spki: TEST_FEED_SPKI, fingerprint: TEST_FEED_FINGERPRINT }
  });
}

function requestAsRoleWithRawAuthorization(bucket, authorization) {
  return handleRequest({
    url: `${ORIGIN}/linux/repository-admin/status?channel=stable`,
    method: 'GET',
    headers: { get: (name) => name.toLowerCase() === 'authorization' ? authorization : null }
  }, {
    REPOSITORY_BUCKET: bucket,
    WORKER_ROLE: 'control',
    OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN: TOKEN,
    OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN: UPLOAD_TOKEN
  }, {
    now: () => new Date('2026-07-10T12:00:00.000Z'),
    feedVerification: { spki: TEST_FEED_SPKI, fingerprint: TEST_FEED_FINGERPRINT }
  });
}

class FakeR2 {
  #objects = new Map();
  beforeConditionalPut = null;
  beforeHead = null;

  keys() { return this.#objects.keys(); }

  delete(key) { this.#objects.delete(key); }

  seed(key, value, httpMetadata = {}, customMetadata = {}) {
    const bytes = toBytes(value);
    const etag = crypto.createHash('sha256').update(bytes).digest('hex');
    this.#objects.set(key, { bytes, etag, httpMetadata, customMetadata });
  }

  seedSized(key, size, customMetadata = {}) {
    const bytes = new Uint8Array(1);
    const etag = crypto.createHash('sha256').update(bytes).digest('hex');
    this.#objects.set(key, { bytes, reportedSize: size, etag, httpMetadata: {}, customMetadata });
  }

  copy(source, destination) {
    const value = this.#objects.get(source);
    this.seed(destination, value.bytes, value.httpMetadata);
  }

  async text(key) { return new TextDecoder().decode(this.#objects.get(key).bytes); }

  textSync(key) { return new TextDecoder().decode(this.#objects.get(key).bytes); }

  async head(key) {
    this.beforeHead?.(key);
    const value = this.#objects.get(key);
    return value ? fakeObject(value) : null;
  }

  async get(key, options = {}) {
    const value = this.#objects.get(key);
    if (!value) return null;
    const range = options?.range;
    const bytes = range ? value.bytes.slice(range.offset, range.offset + range.length) : value.bytes;
    return fakeObject(value, bytes, range);
  }

  async put(key, value, options = {}) {
    const existing = this.#objects.get(key);
    if (options.onlyIf) this.beforeConditionalPut?.(key, existing);
    const current = this.#objects.get(key);
    if (options.onlyIf instanceof Headers) {
      if (options.onlyIf.get('if-none-match') === '*' && current) return null;
    } else {
      if (options.onlyIf?.etagMatches && current?.etag !== options.onlyIf.etagMatches) return null;
      if (options.onlyIf?.etagDoesNotMatch === '*' && current) return null;
    }
    const bytes = value instanceof ReadableStream
      ? new Uint8Array(await new Response(value).arrayBuffer())
      : toBytes(value);
    if (options.sha256 && crypto.createHash('sha256').update(bytes).digest('hex') !== options.sha256) return null;
    const etag = crypto.createHash('sha256').update(bytes).digest('hex');
    const stored = { bytes, etag, httpMetadata: options.httpMetadata ?? {}, customMetadata: options.customMetadata ?? {} };
    this.#objects.set(key, stored);
    return fakeObject(stored);
  }
}

function fakeObject(value, body = null, range = null) {
  const object = {
    size: value.reportedSize ?? value.bytes.byteLength,
    etag: value.etag,
    httpEtag: `"${value.etag}"`,
    customMetadata: value.customMetadata ?? {},
    writeHttpMetadata(headers) {
      if (value.httpMetadata.contentType) headers.set('Content-Type', value.httpMetadata.contentType);
      if (value.httpMetadata.contentEncoding) headers.set('Content-Encoding', value.httpMetadata.contentEncoding);
    }
  };
  if (body !== null) {
    object.body = body;
    object.range = range;
    object.arrayBuffer = async () => body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength);
    object.text = async () => new TextDecoder().decode(body);
  }
  return object;
}

function toBytes(value) {
  if (value instanceof Uint8Array) return new Uint8Array(value);
  return new TextEncoder().encode(String(value));
}
