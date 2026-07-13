import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { signProductProofClosure } from './sign-product-proof-closure.mjs';

test('product proof closure signing emits a pinned, self-verifying sidecar', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-closure-sign-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const closureFile = path.join(root, 'product-proof-closure.json');
  const signatureFile = path.join(root, 'product-proof-closure.json.ed25519.sig');
  const document = {
    schemaVersion: 1,
    status: 'passed',
    stage: 'candidate',
    targetHead: 'a'.repeat(40),
    sourceCommit: 'a'.repeat(40),
    git: { commit: 'a'.repeat(40), dirty: false }
  };
  fs.writeFileSync(closureFile, `${JSON.stringify(document, null, 2)}\n`);
  const result = signProductProofClosure({
    closureFile,
    signatureFile,
    privateKeyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }),
    publicKeyPem: publicKey.export({ type: 'spki', format: 'pem' })
  });
  assert.equal(result.size, 64);
  assert.equal(
    crypto.verify(null, fs.readFileSync(closureFile), publicKey, fs.readFileSync(signatureFile)),
    true
  );
  fs.appendFileSync(closureFile, 'mutation\n');
  assert.equal(
    crypto.verify(null, fs.readFileSync(closureFile), publicKey, fs.readFileSync(signatureFile)),
    false
  );
});

test('product proof closure signing rejects a mismatched key and unpassed closure', () => {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const other = crypto.generateKeyPairSync('ed25519');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-closure-sign-invalid-'));
  try {
    const file = path.join(root, 'closure.json');
    fs.writeFileSync(file, JSON.stringify({ status: 'blocked' }));
    assert.throws(() => signProductProofClosure({
      closureFile: file,
      signatureFile: path.join(root, 'closure.sig'),
      privateKeyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }),
      publicKeyPem: publicKey.export({ type: 'spki', format: 'pem' })
    }), /clean, passed/u);
    const valid = {
      schemaVersion: 1,
      status: 'passed',
      stage: 'candidate',
      targetHead: 'b'.repeat(40),
      sourceCommit: 'b'.repeat(40),
      git: { commit: 'b'.repeat(40), dirty: false }
    };
    fs.writeFileSync(file, JSON.stringify(valid));
    assert.throws(() => signProductProofClosure({
      closureFile: file,
      signatureFile: path.join(root, 'closure.sig'),
      privateKeyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }),
      publicKeyPem: other.publicKey.export({ type: 'spki', format: 'pem' })
    }), /does not match/u);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
