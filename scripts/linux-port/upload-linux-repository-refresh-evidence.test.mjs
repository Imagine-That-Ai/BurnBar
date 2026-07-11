import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  uploadLinuxRepositoryRefreshEvidence,
  verifyRefreshAttestation
} from './upload-linux-repository-refresh-evidence.mjs';

const token = 'e'.repeat(32);

function identity(file) {
  const bytes = fs.readFileSync(file);
  return { file: path.basename(file), sha256: crypto.createHash('sha256').update(bytes).digest('hex'), size: bytes.length };
}

function writeJson(file, value) {
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function createEvidence() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-refresh-evidence-'));
  const evidenceRoot = path.join(root, 'evidence');
  const transactionRoot = path.join(root, 'transaction');
  fs.mkdirSync(evidenceRoot);
  fs.mkdirSync(transactionRoot);
  const closurePath = path.join(transactionRoot, 'repository-closure.json');
  writeJson(closurePath, {
    schemaVersion: 2,
    product: 'OpenBurnBar',
    channel: 'stable',
    version: '1.2.3',
    gitCommit: 'a'.repeat(40),
    packageSetRootSha256: 'c'.repeat(64),
    repositories: {
      apt: {
        releaseDate: '2026-07-11T12:00:00.000Z',
        validUntil: '2026-07-18T12:00:00.000Z'
      }
    },
    refresh: { kind: 'apt-expiry', previousSnapshotId: 'b'.repeat(64) }
  });
  const snapshotId = identity(closurePath).sha256;
  const closureSignaturePath = `${closurePath}.asc`;
  fs.writeFileSync(closureSignaturePath, 'closure signature\n');
  const activationReceiptPath = path.join(transactionRoot, 'repository-activation.json');
  writeJson(activationReceiptPath, {
    schemaVersion: 1,
    dryRun: false,
    result: {
      activation: {
        mode: 'refresh',
        channel: 'stable',
        version: '1.2.3',
        sourceCommit: 'a'.repeat(40),
        snapshotId,
        generation: 7,
        previousSnapshotId: 'b'.repeat(64)
      }
    }
  });
  const receipts = [
    path.join(evidenceRoot, 'repository-freshness.json'),
    path.join(evidenceRoot, 'repository-refresh-feed-verification.json')
  ];
  writeJson(receipts[0], { schemaVersion: 1, passed: true, status: 'active' });
  writeJson(receipts[1], { schemaVersion: 1, passed: true, feedGeneration: 3 });
  const transactionPath = path.join(evidenceRoot, 'repository-refresh-transaction.json');
  writeJson(transactionPath, {
    schemaVersion: 1,
    operation: 'linux-repository-metadata-refresh',
    channel: 'stable',
    version: '1.2.3',
    sourceCommit: 'a'.repeat(40),
    toolCommit: 'd'.repeat(40),
    runUrl: 'https://github.com/Imagine-That-Ai/BurnBar/actions/runs/123',
    snapshotId,
    activationGeneration: 7,
    previousSnapshotId: 'b'.repeat(64),
    packageSetRootSha256: 'c'.repeat(64),
    releaseDate: '2026-07-11T12:00:00.000Z',
    validUntil: '2026-07-18T12:00:00.000Z',
    receipts: receipts.map(identity).sort((left, right) => left.file.localeCompare(right.file)),
    transactionInputs: [activationReceiptPath, closurePath, closureSignaturePath]
      .map(identity).sort((left, right) => left.file.localeCompare(right.file))
  });
  const predicatePath = path.join(evidenceRoot, 'repository-refresh-predicate.json');
  const transaction = JSON.parse(fs.readFileSync(transactionPath, 'utf8'));
  writeJson(predicatePath, {
    predicateType: 'https://openburnbar.dev/attestations/linux-repository-refresh/v1',
    subject: identity(transactionPath),
    transaction
  });
  const predicate = JSON.parse(fs.readFileSync(predicatePath, 'utf8'));
  const bundlePath = `${transactionPath}.sigstore.json`;
  writeJson(bundlePath, {
    mediaType: 'application/vnd.dev.sigstore.bundle.v0.3+json',
    dsseEnvelope: {
      payloadType: 'application/vnd.in-toto+json',
      payload: Buffer.from(JSON.stringify({
        _type: 'https://in-toto.io/Statement/v1',
        subject: [{ name: path.basename(transactionPath), digest: { sha256: identity(transactionPath).sha256 } }],
        predicateType: 'https://openburnbar.dev/attestations/linux-repository-refresh/v1',
        predicate
      })).toString('base64'),
      signatures: [{ sig: 'test-signature' }]
    }
  });
  return {
    root,
    evidenceRoot,
    closurePath,
    closureSignaturePath,
    activationReceiptPath,
    transactionPath,
    bundlePath,
    snapshotId,
    manifestPath: path.join(evidenceRoot, 'repository-refresh-evidence-closure.json'),
    receiptPath: path.join(root, 'repository-refresh-evidence-upload.json')
  };
}

async function requestBody(body) {
  const chunks = [];
  for await (const chunk of body) chunks.push(chunk);
  return Buffer.concat(chunks);
}

function uploadService(overrides = {}) {
  const requests = [];
  const fetchImpl = async (input, init) => {
    const bytes = await requestBody(init.body);
    requests.push({ url: new URL(input), init, bytes });
    if (overrides.status) return new Response('{"error":"conflict"}', { status: overrides.status });
    const result = {
      schemaVersion: 1,
      status: overrides.uploadStatus ?? 'created',
      key: init.headers['X-OpenBurnBar-Object-Key'],
      sha256: init.headers['X-OpenBurnBar-Object-Sha256'],
      size: Number(init.headers['Content-Length']),
      etag: `"${'f'.repeat(64)}"`,
      ...(overrides.response ?? {})
    };
    return new Response(JSON.stringify(result), { status: overrides.httpStatus ?? 201 });
  };
  return { requests, fetchImpl };
}

function options(value, overrides = {}) {
  return {
    evidenceRoot: value.evidenceRoot,
    activationReceiptPath: value.activationReceiptPath,
    repositoryClosurePath: value.closurePath,
    repositoryClosureSignaturePath: value.closureSignaturePath,
    manifestPath: value.manifestPath,
    receiptPath: value.receiptPath,
    baseUrl: 'http://127.0.0.1:8787',
    allowLocalTestOrigin: true,
    token,
    verifyAttestation: async () => ({
      type: 'https://openburnbar.dev/attestations/linux-repository-refresh/v1',
      issuer: 'https://token.actions.githubusercontent.com',
      identity: 'https://github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-repository-refresh.yml@refs/heads/main'
    }),
    ...overrides
  };
}

test('uploads the exact attested transaction closure under its snapshot and activation generation', async (t) => {
  const value = createEvidence();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const service = uploadService();
  const receipt = await uploadLinuxRepositoryRefreshEvidence(options(value), service.fetchImpl);

  const prefix = `linux/repository-refresh-evidence/stable/${value.snapshotId}/7`;
  assert.equal(receipt.prefix, prefix);
  assert.equal(receipt.activationGeneration, 7);
  assert.equal(receipt.objectCount, 9);
  assert.equal(receipt.operations.at(-1).key, `${prefix}/repository-refresh-evidence-closure.json`);
  assert.ok(receipt.operations.every((row) => row.key.startsWith(`${prefix}/`)));
  assert.ok(receipt.operations.every((row) => !row.key.endsWith('repository-refresh-evidence-upload.json')));
  assert.deepEqual(JSON.parse(fs.readFileSync(value.receiptPath, 'utf8')), receipt);

  const closure = JSON.parse(fs.readFileSync(value.manifestPath, 'utf8'));
  assert.equal(closure.snapshotId, value.snapshotId);
  assert.equal(closure.activationGeneration, 7);
  assert.equal(closure.attestation.identity,
    'https://github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-repository-refresh.yml@refs/heads/main');
  assert.equal(closure.files.length, 8);
  assert.deepEqual(new Set(closure.files.map((row) => row.role)), new Set([
    'evidence', 'activation-receipt', 'repository-closure', 'repository-closure-signature'
  ]));
  for (const required of [
    'repository-refresh-transaction.json',
    'repository-refresh-predicate.json',
    'repository-refresh-transaction.json.sigstore.json',
    'repository-activation.json',
    'repository-closure.json',
    'repository-closure.json.asc'
  ]) assert.ok(closure.files.some((row) => row.file === required), required);

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

test('verifies the exact manifest bundle, predicate type, issuer, and workflow identity before upload', async (t) => {
  const value = createEvidence();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const calls = [];
  const result = verifyRefreshAttestation({
    bundlePath: value.bundlePath,
    transactionPath: value.transactionPath
  }, (command, args, options) => {
    calls.push({ command, args, options });
    return { status: 0, stdout: '', stderr: '' };
  });
  assert.deepEqual(result, {
    type: 'https://openburnbar.dev/attestations/linux-repository-refresh/v1',
    issuer: 'https://token.actions.githubusercontent.com',
    identity: 'https://github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-repository-refresh.yml@refs/heads/main'
  });
  assert.deepEqual(calls[0].args, [
    'verify-blob-attestation',
    '--bundle', value.bundlePath,
    '--type', 'https://openburnbar.dev/attestations/linux-repository-refresh/v1',
    '--certificate-identity',
    'https://github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-repository-refresh.yml@refs/heads/main',
    '--certificate-oidc-issuer', 'https://token.actions.githubusercontent.com',
    value.transactionPath
  ]);
  assert.throws(() => verifyRefreshAttestation({
    bundlePath: value.bundlePath,
    transactionPath: value.transactionPath
  }, () => ({ status: 1, stderr: 'wrong subject, predicate, issuer, or identity' })),
  /Sigstore attestation verification failed/u);
});

test('rejects drifted transaction inputs, receipts, predicates, and missing attestation bundle before network access', async (t) => {
  for (const scenario of ['input', 'receipt', 'predicate', 'bundle']) {
    const value = createEvidence();
    t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
    if (scenario === 'input') fs.appendFileSync(value.activationReceiptPath, ' ');
    if (scenario === 'receipt') writeJson(path.join(value.evidenceRoot, 'repository-freshness.json'), { passed: false });
    if (scenario === 'predicate') writeJson(path.join(value.evidenceRoot, 'repository-refresh-predicate.json'), {
      predicateType: 'https://openburnbar.dev/attestations/linux-repository-refresh/v1',
      subject: { file: 'wrong.json', sha256: '0'.repeat(64), size: 1 },
      transaction: {}
    });
    if (scenario === 'bundle') fs.rmSync(value.bundlePath);
    let calls = 0;
    await assert.rejects(() => uploadLinuxRepositoryRefreshEvidence(options(value), async () => {
      calls += 1;
      throw new Error('must not call');
    }), scenario === 'bundle' ? /missing required attestation input/u : /does not bind/u, scenario);
    assert.equal(calls, 0, scenario);
    assert.equal(fs.existsSync(value.receiptPath), false, scenario);
  }
});

test('rejects every duplicated transaction identity field before Sigstore or network access', async (t) => {
  const fields = [
    'version', 'sourceCommit', 'previousSnapshotId', 'packageSetRootSha256', 'releaseDate', 'validUntil'
  ];
  for (const field of fields) {
    const value = createEvidence();
    t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
    const transaction = JSON.parse(fs.readFileSync(value.transactionPath, 'utf8'));
    transaction[field] = field === 'version' ? '9.9.9' : `drift-${field}`;
    writeJson(value.transactionPath, transaction);
    let verifierCalls = 0;
    let networkCalls = 0;
    await assert.rejects(() => uploadLinuxRepositoryRefreshEvidence(options(value, {
      verifyAttestation: async () => { verifierCalls += 1; }
    }), async () => { networkCalls += 1; }), /transaction identity is invalid/u, field);
    assert.equal(verifierCalls, 0, field);
    assert.equal(networkCalls, 0, field);
  }
});

test('fails closed before upload when Sigstore verification cannot prove the bundle', async (t) => {
  const value = createEvidence();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  let networkCalls = 0;
  await assert.rejects(() => uploadLinuxRepositoryRefreshEvidence(options(value, {
    verifyAttestation: async () => { throw new Error('malformed or wrong-identity Sigstore bundle'); }
  }), async () => { networkCalls += 1; }), /wrong-identity Sigstore bundle/u);
  assert.equal(networkCalls, 0);
  assert.equal(fs.existsSync(value.receiptPath), false);
});

test('rejects a verified same-subject bundle whose embedded predicate differs from the local predicate', async (t) => {
  const value = createEvidence();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const bundle = JSON.parse(fs.readFileSync(value.bundlePath, 'utf8'));
  const statement = JSON.parse(Buffer.from(bundle.dsseEnvelope.payload, 'base64').toString('utf8'));
  statement.predicate.transaction.version = '9.9.9';
  bundle.dsseEnvelope.payload = Buffer.from(JSON.stringify(statement)).toString('base64');
  writeJson(value.bundlePath, bundle);
  let verifierCalls = 0;
  let networkCalls = 0;
  await assert.rejects(() => uploadLinuxRepositoryRefreshEvidence(options(value, {
    verifyAttestation: async () => {
      verifierCalls += 1;
      return {
        type: 'https://openburnbar.dev/attestations/linux-repository-refresh/v1',
        issuer: 'https://token.actions.githubusercontent.com',
        identity: 'https://github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-repository-refresh.yml@refs/heads/main'
      };
    }
  }), async () => { networkCalls += 1; }), /statement predicate does not equal/u);
  assert.equal(verifierCalls, 0);
  assert.equal(networkCalls, 0);
});

test('rejects arbitrary evidence entries, symlinks, unsafe output placement, and duplicate basenames', async (t) => {
  const cases = [
    ['directory', (value) => fs.mkdirSync(path.join(value.evidenceRoot, 'nested'))],
    ['symlink', (value) => fs.symlinkSync('repository-freshness.json', path.join(value.evidenceRoot, 'linked.json'))],
    ['non-json', (value) => fs.writeFileSync(path.join(value.evidenceRoot, 'notes.txt'), 'no')],
    ['unknown-json', (value) => writeJson(path.join(value.evidenceRoot, 'unknown.json'), {})],
    ['duplicate', (value) => writeJson(path.join(value.evidenceRoot, 'repository-activation.json'), {})]
  ];
  for (const [name, mutate] of cases) {
    const value = createEvidence();
    t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
    mutate(value);
    let calls = 0;
    await assert.rejects(() => uploadLinuxRepositoryRefreshEvidence(options(value), async () => {
      calls += 1;
      throw new Error('must not call');
    }), /unsupported entry|duplicate basenames/u, name);
    assert.equal(calls, 0, name);
  }

  const inside = createEvidence();
  t.after(() => fs.rmSync(inside.root, { recursive: true, force: true }));
  await assert.rejects(() => uploadLinuxRepositoryRefreshEvidence(options(inside, {
    receiptPath: path.join(inside.evidenceRoot, 'upload-receipt.json')
  })), /receipt must be outside/u);
  await assert.rejects(() => uploadLinuxRepositoryRefreshEvidence(options(inside, {
    manifestPath: path.join(inside.root, 'elsewhere.json')
  })), /canonical basename directly inside/u);
});

test('pins production origin and validates exact immutable upload responses', async (t) => {
  const invalidOrigin = createEvidence();
  t.after(() => fs.rmSync(invalidOrigin.root, { recursive: true, force: true }));
  let calls = 0;
  await assert.rejects(() => uploadLinuxRepositoryRefreshEvidence(options(invalidOrigin, {
    baseUrl: 'https://example.com', allowLocalTestOrigin: false
  }), async () => { calls += 1; }), /must use https:\/\/downloads\.burnbar\.ai/u);
  assert.equal(calls, 0);

  const invalidToken = createEvidence();
  t.after(() => fs.rmSync(invalidToken.root, { recursive: true, force: true }));
  await assert.rejects(() => uploadLinuxRepositoryRefreshEvidence(options(invalidToken, { token: 'short' })), /upload token/u);

  for (const response of [
    { key: 'linux/repository-refresh-evidence/stable/wrong' },
    { sha256: '0'.repeat(64) },
    { size: 999 },
    { etag: 'not-an-etag' },
    { status: 'invented' }
  ]) {
    const value = createEvidence();
    t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
    await assert.rejects(() => uploadLinuxRepositoryRefreshEvidence(options(value),
      uploadService({ response }).fetchImpl), /response does not bind/u);
    assert.equal(fs.existsSync(value.receiptPath), false);
  }
});
