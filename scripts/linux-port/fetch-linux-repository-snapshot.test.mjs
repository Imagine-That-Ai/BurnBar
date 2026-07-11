import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fetchLinuxRepositorySnapshot } from './fetch-linux-repository-snapshot.mjs';

const token = 'a'.repeat(32);
const pointerEtag = `"${'b'.repeat(32)}"`;
const sourceCommit = 'c'.repeat(40);

function fixture(overrides = {}) {
  const files = overrides.files ?? new Map([
    ['apt/pool/openburnbar.deb', Buffer.from('deb-package\n')],
    ['rpm/stable/x86_64/openburnbar.rpm', Buffer.from('rpm-package\n')]
  ]);
  const rows = overrides.rows ?? [...files].map(([file, bytes]) => ({
    file,
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    size: bytes.length
  }));
  const closure = {
    schemaVersion: 1,
    channel: 'stable',
    version: '1.2.3',
    gitCommit: sourceCommit,
    files: rows
  };
  const closureBytes = Buffer.from(`${JSON.stringify(closure)}\n`);
  const snapshotId = crypto.createHash('sha256').update(closureBytes).digest('hex');
  return { files, rows, closureBytes, snapshotId, signature: Buffer.from('detached-signature\n') };
}

function activeStatus(value, changes = {}) {
  const etag = changes.pointerEtag ?? pointerEtag;
  return new Response(JSON.stringify({
    schemaVersion: 1,
    status: 'active',
    channel: 'stable',
    activation: {
      channel: 'stable',
      snapshotId: changes.snapshotId ?? value.snapshotId,
      version: '1.2.3',
      generation: changes.generation ?? 4,
      sourceCommit
    },
    pointerEtag: etag
  }), { status: 200, headers: { 'Content-Type': 'application/json', ETag: etag } });
}

function previewResponse(bytes, snapshotId, status = 200) {
  return new Response(bytes, {
    status,
    headers: {
      'Content-Length': String(bytes.length),
      'X-OpenBurnBar-Repository-Snapshot': snapshotId
    }
  });
}

function fakeService(value, options = {}) {
  const requests = [];
  let statusReads = 0;
  const fetchImpl = async (input, init = {}) => {
    const url = new URL(input);
    requests.push({ url, init });
    if (url.pathname === '/linux/repository-admin/status') {
      statusReads += 1;
      return activeStatus(value, statusReads === 2 ? options.finalStatus : undefined);
    }
    const prefix = `/linux/repository-preview/stable/${value.snapshotId}/`;
    assert.ok(url.pathname.startsWith(prefix));
    const relative = url.pathname.slice(prefix.length);
    if (relative === 'repository-closure.json') {
      return previewResponse(options.closureBytes ?? value.closureBytes, value.snapshotId);
    }
    if (relative === 'repository-closure.json.asc') return previewResponse(value.signature, value.snapshotId);
    const bytes = options.fileBytes?.get(relative) ?? value.files.get(relative);
    assert.ok(bytes, `unexpected preview request: ${relative}`);
    return previewResponse(bytes, value.snapshotId);
  };
  return { requests, fetchImpl };
}

test('fetches the exact active closure, signature, and closure-listed files with a stable status receipt', async (t) => {
  const value = fixture();
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-fetch-snapshot-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const outputDirectory = path.join(root, 'parent');
  const receiptPath = path.join(root, 'receipt.json');
  const service = fakeService(value);
  const receipt = await fetchLinuxRepositorySnapshot({
    channel: 'stable', token, baseUrl: 'http://127.0.0.1:8787', allowLocalTestOrigin: true,
    outputDirectory, receiptPath
  }, service.fetchImpl);

  assert.equal(receipt.snapshotId, value.snapshotId);
  assert.equal(receipt.generation, 4);
  assert.equal(receipt.pointerEtag, pointerEtag);
  assert.equal(receipt.sourceCommit, sourceCommit);
  assert.deepEqual(fs.readFileSync(path.join(outputDirectory, 'repository-closure.json')), value.closureBytes);
  assert.deepEqual(fs.readFileSync(path.join(outputDirectory, 'repository-closure.json.asc')), value.signature);
  for (const [relative, bytes] of value.files) {
    assert.deepEqual(fs.readFileSync(path.join(outputDirectory, ...relative.split('/'))), bytes);
  }
  assert.deepEqual(JSON.parse(fs.readFileSync(receiptPath, 'utf8')), receipt);
  const statusRequests = service.requests.filter(({ url }) => url.pathname.includes('/repository-admin/status'));
  const previewRequests = service.requests.filter(({ url }) => url.pathname.includes('/repository-preview/'));
  assert.equal(statusRequests.length, 2);
  assert.ok(statusRequests.every(({ init }) => init.headers.Authorization === `Bearer ${token}`));
  assert.ok(previewRequests.every(({ init }) => init.headers.Authorization === undefined));
  assert.ok(service.requests.every(({ init }) => init.redirect === 'error'));
});

test('fails closed and removes staging output when a closure-listed file has different bytes', async (t) => {
  const value = fixture();
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-fetch-drift-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const outputDirectory = path.join(root, 'parent');
  const changed = new Map([['apt/pool/openburnbar.deb', Buffer.from('different bytes')]]);
  await assert.rejects(() => fetchLinuxRepositorySnapshot({
    channel: 'stable', token, baseUrl: 'http://localhost:8787', allowLocalTestOrigin: true, outputDirectory
  }, fakeService(value, { fileBytes: changed }).fetchImpl), /(?:size|checksum) mismatch/u);
  assert.equal(fs.existsSync(outputDirectory), false);
  assert.deepEqual(fs.readdirSync(root), []);
});

test('rejects closure hash mismatches before downloading closure-listed objects', async (t) => {
  const value = fixture();
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-fetch-closure-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const service = fakeService(value, { closureBytes: Buffer.from('{}\n') });
  await assert.rejects(() => fetchLinuxRepositorySnapshot({
    channel: 'stable', token, baseUrl: 'http://127.0.0.1:8787', allowLocalTestOrigin: true,
    outputDirectory: path.join(root, 'parent')
  }, service.fetchImpl), /closure checksum/u);
  assert.equal(service.requests.some(({ url }) => url.pathname.endsWith('.deb')), false);
});

test('rejects a parent generation or ETag race after all bytes are acquired', async (t) => {
  const value = fixture();
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-fetch-race-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  await assert.rejects(() => fetchLinuxRepositorySnapshot({
    channel: 'stable', token, baseUrl: 'http://127.0.0.1:8787', allowLocalTestOrigin: true,
    outputDirectory: path.join(root, 'parent')
  }, fakeService(value, { finalStatus: { generation: 5, pointerEtag: `"${'d'.repeat(32)}"` } }).fetchImpl),
  /changed during acquisition/u);
  assert.deepEqual(fs.readdirSync(root), []);
});

test('rejects unsafe or duplicate closure rows before requesting any listed object', async (t) => {
  const bytes = Buffer.from('same\n');
  const digest = crypto.createHash('sha256').update(bytes).digest('hex');
  for (const rows of [
    [{ file: 'apt/../secret', sha256: digest, size: bytes.length }],
    [
      { file: 'apt/pool/same.deb', sha256: digest, size: bytes.length },
      { file: 'apt/pool/same.deb', sha256: digest, size: bytes.length }
    ]
  ]) {
    const value = fixture({ files: new Map([['apt/pool/same.deb', bytes]]), rows });
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-fetch-invalid-'));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    const service = fakeService(value);
    await assert.rejects(() => fetchLinuxRepositorySnapshot({
      channel: 'stable', token, baseUrl: 'http://127.0.0.1:8787', allowLocalTestOrigin: true,
      outputDirectory: path.join(root, 'parent')
    }, service.fetchImpl), /invalid or duplicate/u);
    assert.equal(service.requests.filter(({ url }) => url.pathname.includes('/repository-preview/')).length, 1);
  }
});

test('pins production origin and validates credentials before any network call', async () => {
  let calls = 0;
  const fetchImpl = async () => { calls += 1; throw new Error('must not call'); };
  await assert.rejects(() => fetchLinuxRepositorySnapshot({
    channel: 'stable', token, baseUrl: 'https://example.com', outputDirectory: '/tmp/unused-openburnbar-fetch'
  }, fetchImpl), /must use https:\/\/downloads\.burnbar\.ai/u);
  await assert.rejects(() => fetchLinuxRepositorySnapshot({
    channel: 'stable', token: 'short', baseUrl: 'https://downloads.burnbar.ai', outputDirectory: '/tmp/unused-openburnbar-fetch'
  }, fetchImpl), /activation token/u);
  assert.equal(calls, 0);
});
