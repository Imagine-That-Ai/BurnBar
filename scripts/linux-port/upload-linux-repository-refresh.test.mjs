import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { uploadLinuxRepositoryRefresh } from './upload-linux-repository-refresh.mjs';

const token = 'u'.repeat(32);

function createRepository(options = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-upload-refresh-'));
  const repositoryRoot = path.join(root, 'repository');
  fs.mkdirSync(repositoryRoot);
  const files = new Map([
    ['apt/pool/main/o/openburnbar/OpenBurnBar_1.2.3_amd64.deb', Buffer.from('deb\n')],
    ['rpm/stable/x86_64/OpenBurnBar-1.2.3-1.x86_64.rpm', Buffer.from('rpm\n')],
    ['apt/dists/stable/main/binary-amd64/by-hash/SHA256/abcd', Buffer.from('by-hash\n')],
    ['rpm/stable/x86_64/repodata/abcd-primary.xml.gz', Buffer.from('primary\n')],
    ['apt/dists/stable/InRelease', Buffer.from('inrelease\n')]
  ]);
  for (const [relative, bytes] of files) {
    const file = path.join(repositoryRoot, ...relative.split('/'));
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, bytes);
  }
  const rows = [...files].map(([file, bytes]) => ({
    file,
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    size: bytes.length
  }));
  if (options.duplicate) rows.push({ ...rows[0] });
  const closureBytes = Buffer.from(`${JSON.stringify({
    schemaVersion: 2,
    channel: 'stable',
    version: '1.2.3',
    gitCommit: 'a'.repeat(40),
    files: rows
  })}\n`);
  fs.writeFileSync(path.join(repositoryRoot, 'repository-closure.json'), closureBytes);
  fs.writeFileSync(path.join(repositoryRoot, 'repository-closure.json.asc'), 'signature\n');
  if (options.lifecycle !== false) fs.writeFileSync(path.join(repositoryRoot, 'repository-lifecycle.json'), '{}\n');
  return {
    root,
    repositoryRoot,
    files,
    rows,
    snapshotId: crypto.createHash('sha256').update(closureBytes).digest('hex')
  };
}

async function requestBody(body) {
  const chunks = [];
  for await (const chunk of body) chunks.push(chunk);
  return Buffer.concat(chunks);
}

function uploadService(overrides = {}) {
  const requests = [];
  const fetchImpl = async (input, init = {}) => {
    const bytes = await requestBody(init.body);
    requests.push({ url: new URL(input), init, bytes });
    const key = init.headers['X-OpenBurnBar-Object-Key'];
    const sha256 = init.headers['X-OpenBurnBar-Object-Sha256'];
    const size = Number(init.headers['Content-Length']);
    if (overrides.failureStatus) return new Response('{"error":"conflict"}', { status: overrides.failureStatus });
    const result = {
      schemaVersion: 1,
      status: 'created',
      key,
      sha256,
      size,
      etag: `"${'e'.repeat(32)}"`,
      ...(overrides.response ?? {})
    };
    return new Response(JSON.stringify(result), { status: overrides.httpStatus ?? 201 });
  };
  return { requests, fetchImpl };
}

test('uploads shared checksum leaves first and then the complete closure-addressed snapshot', async (t) => {
  const value = createRepository();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const receiptPath = path.join(value.root, 'upload-receipt.json');
  const service = uploadService();
  const receipt = await uploadLinuxRepositoryRefresh({
    repositoryRoot: value.repositoryRoot,
    receiptPath,
    baseUrl: 'http://127.0.0.1:8787',
    allowLocalTestOrigin: true,
    token
  }, service.fetchImpl);

  const sharedRelatives = value.rows.slice(0, 4).map((row) => row.file);
  const snapshotRelatives = [
    'repository-closure.json',
    'repository-closure.json.asc',
    ...value.rows.map((row) => row.file),
    'repository-lifecycle.json'
  ];
  const expectedKeys = [
    ...sharedRelatives.map((relative) => `linux/${relative}`),
    ...snapshotRelatives.map((relative) => `linux/repository-snapshots/stable/${value.snapshotId}/${relative}`)
  ];
  assert.deepEqual(service.requests.map(({ init }) => init.headers['X-OpenBurnBar-Object-Key']), expectedKeys);
  assert.equal(receipt.sharedObjectCount, 4);
  assert.equal(receipt.snapshotObjectCount, snapshotRelatives.length);
  assert.equal(receipt.operationCount, expectedKeys.length);
  assert.equal(receipt.snapshotId, value.snapshotId);
  assert.deepEqual(JSON.parse(fs.readFileSync(receiptPath, 'utf8')), receipt);

  for (const request of service.requests) {
    assert.equal(request.url.href, 'http://127.0.0.1:8787/linux/repository-upload/immutable');
    assert.equal(request.init.method, 'PUT');
    assert.equal(request.init.redirect, 'error');
    assert.equal(request.init.headers.Authorization, `Bearer ${token}`);
    assert.equal(request.init.headers['Content-Length'], String(request.bytes.length));
    assert.equal(request.init.headers['X-OpenBurnBar-Object-Sha256'],
      crypto.createHash('sha256').update(request.bytes).digest('hex'));
  }
});

test('never addresses release, feed, activation, or other mutable namespaces', async (t) => {
  const value = createRepository();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const service = uploadService();
  await uploadLinuxRepositoryRefresh({
    repositoryRoot: value.repositoryRoot,
    baseUrl: 'http://localhost:8787',
    allowLocalTestOrigin: true,
    token
  }, service.fetchImpl);
  const keys = service.requests.map(({ init }) => init.headers['X-OpenBurnBar-Object-Key']);
  assert.ok(keys.every((key) => key.startsWith('linux/apt/') || key.startsWith('linux/rpm/')
    || key.startsWith(`linux/repository-snapshots/stable/${value.snapshotId}/`)));
  assert.ok(keys.every((key) => !/(?:releases|update-feed|latest-linux|activations)/u.test(key)));
  assert.ok(service.requests.every(({ url }) => url.pathname === '/linux/repository-upload/immutable'));
});

test('requires exact response key, checksum, size, status, ETag, and HTTP binding', async (t) => {
  for (const response of [
    { key: 'linux/apt/wrong' },
    { sha256: 'f'.repeat(64) },
    { size: 999 },
    { status: 'created', etag: 'not-an-etag' },
    { status: 'invented' }
  ]) {
    const value = createRepository({ lifecycle: false });
    t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
    const receiptPath = path.join(value.root, 'receipt.json');
    await assert.rejects(() => uploadLinuxRepositoryRefresh({
      repositoryRoot: value.repositoryRoot,
      receiptPath,
      baseUrl: 'http://127.0.0.1:8787',
      allowLocalTestOrigin: true,
      token
    }, uploadService({ response }).fetchImpl), /response does not bind/u);
    assert.equal(fs.existsSync(receiptPath), false);
  }
  const value = createRepository({ lifecycle: false });
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  await assert.rejects(() => uploadLinuxRepositoryRefresh({
    repositoryRoot: value.repositoryRoot,
    baseUrl: 'http://127.0.0.1:8787', allowLocalTestOrigin: true, token
  }, uploadService({ response: { status: 'unchanged' }, httpStatus: 201 }).fetchImpl), /response does not bind/u);
});

test('validates every local byte and rejects symlinks before the first network request', async (t) => {
  const drifted = createRepository();
  t.after(() => fs.rmSync(drifted.root, { recursive: true, force: true }));
  fs.writeFileSync(path.join(drifted.repositoryRoot, ...drifted.rows[0].file.split('/')), 'changed\n');
  let calls = 0;
  const noNetwork = async () => { calls += 1; throw new Error('must not call'); };
  await assert.rejects(() => uploadLinuxRepositoryRefresh({
    repositoryRoot: drifted.repositoryRoot, baseUrl: 'https://downloads.burnbar.ai', token
  }, noNetwork), /does not match its closure/u);

  const linked = createRepository();
  t.after(() => fs.rmSync(linked.root, { recursive: true, force: true }));
  const target = path.join(linked.repositoryRoot, ...linked.rows[0].file.split('/'));
  fs.rmSync(target);
  fs.symlinkSync(path.join(linked.repositoryRoot, ...linked.rows[1].file.split('/')), target);
  await assert.rejects(() => uploadLinuxRepositoryRefresh({
    repositoryRoot: linked.repositoryRoot, baseUrl: 'https://downloads.burnbar.ai', token
  }, noNetwork), /symbolic link/u);
  assert.equal(calls, 0);
});

test('rejects invalid closure rows and unexpected repository files before upload', async (t) => {
  const duplicate = createRepository({ duplicate: true });
  t.after(() => fs.rmSync(duplicate.root, { recursive: true, force: true }));
  let calls = 0;
  const noNetwork = async () => { calls += 1; throw new Error('must not call'); };
  await assert.rejects(() => uploadLinuxRepositoryRefresh({
    repositoryRoot: duplicate.repositoryRoot, baseUrl: 'https://downloads.burnbar.ai', token
  }, noNetwork), /invalid or duplicate/u);

  const unexpected = createRepository();
  t.after(() => fs.rmSync(unexpected.root, { recursive: true, force: true }));
  fs.writeFileSync(path.join(unexpected.repositoryRoot, 'latest-linux.json'), '{}\n');
  await assert.rejects(() => uploadLinuxRepositoryRefresh({
    repositoryRoot: unexpected.repositoryRoot, baseUrl: 'https://downloads.burnbar.ai', token
  }, noNetwork), /does not exactly match its closure/u);
  assert.equal(calls, 0);
});

test('pins production origin, validates token before network, and fails closed on conflict', async (t) => {
  const value = createRepository();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let calls = 0;
  const noNetwork = async () => { calls += 1; throw new Error('must not call'); };
  await assert.rejects(() => uploadLinuxRepositoryRefresh({
    repositoryRoot: value.repositoryRoot, baseUrl: 'https://example.com', token
  }, noNetwork), /must use https:\/\/downloads\.burnbar\.ai/u);
  await assert.rejects(() => uploadLinuxRepositoryRefresh({
    repositoryRoot: value.repositoryRoot, baseUrl: 'https://downloads.burnbar.ai', token: 'short'
  }, noNetwork), /upload token/u);
  assert.equal(calls, 0);

  const receiptPath = path.join(value.root, 'conflict-receipt.json');
  await assert.rejects(() => uploadLinuxRepositoryRefresh({
    repositoryRoot: value.repositoryRoot, receiptPath,
    baseUrl: 'http://127.0.0.1:8787', allowLocalTestOrigin: true, token
  }, uploadService({ failureStatus: 409 }).fetchImpl), /HTTP 409/u);
  assert.equal(fs.existsSync(receiptPath), false);
});
