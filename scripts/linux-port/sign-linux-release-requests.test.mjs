import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  canonicalJsonBytes,
  createInstalledManifest,
  installedFilesRoot,
  RELEASE_PUBLIC_KEY_PATH,
  sha256Bytes
} from './lib/linux-installed-manifest.mjs';
import {
  createLinuxAppImagePeerManifest,
  serializeLinuxAppImagePeerManifest
} from './lib/linux-appimage-peer-manifest.mjs';
import { signLinuxReleaseRequests } from './sign-linux-release-requests.mjs';

test('isolated signer signs the exact canonical release request set', (t) => {
  const value = fixture(t);
  const result = sign(value);
  assert.equal(result.signed.length, 4);
  const response = JSON.parse(fs.readFileSync(
    path.join(value.root, 'signed/signing-response.json'),
    'utf8'
  ));
  assert.equal(response.version, value.version);
  assert.equal(response.gitCommit, value.gitCommit);
  assert.equal(response.architecture, value.architecture);
  for (const record of response.signed) {
    const request = value.index.requests.find((entry) => entry.id === record.id);
    const bytes = fs.readFileSync(path.join(value.root, request.file));
    const signature = fs.readFileSync(path.join(value.root, record.signatureFile));
    assert.equal(crypto.verify(null, bytes, value.publicKey, signature), true);
    assert.equal(record.requestSha256, request.sha256);
    assert.equal(record.signatureSha256, sha256Bytes(signature));
  }
});

test('isolated signer accepts x86_64 request subjects', (t) => {
  const value = fixture(t, 'x86_64');
  assert.equal(sign(value).signed.length, 4);
});

for (const [name, mutate, pattern] of [
  ['workflow identity drift', () => ({ expectedVersion: '9.9.9' }), /invalid Linux release signing request index/u],
  ['non-canonical index', (value) => {
    fs.writeFileSync(value.indexFile, `${JSON.stringify(value.index, null, 2)}\n`);
  }, /invalid Linux release signing request index/u],
  ['unexpected request subject', (value) => {
    fs.writeFileSync(path.join(value.requestsDir, 'extra.json'), '{}\n');
  }, /unexpected subjects/u],
  ['duplicate request record', (value) => {
    value.index.requests.push({ ...value.index.requests[0] });
    writeIndex(value);
  }, /invalid Linux release signing request index/u],
  ['request path escape', (value) => {
    const request = value.index.requests[0];
    const original = path.join(value.root, request.file);
    const bytes = fs.readFileSync(original);
    fs.rmSync(original);
    fs.writeFileSync(path.join(value.requestsDir, 'outside.json'), bytes);
    fs.writeFileSync(path.join(value.root, 'outside.json'), bytes);
    request.file = 'outside.json';
    writeIndex(value);
  }, /path escapes/u],
  ['symlinked request', (value) => {
    const request = value.index.requests[0];
    const original = path.join(value.root, request.file);
    const copy = path.join(value.root, 'request-copy.json');
    fs.copyFileSync(original, copy);
    fs.rmSync(original);
    fs.symlinkSync(copy, original);
  }, /regular file/u],
  ['non-canonical manifest', (value) => {
    const request = value.index.requests[0];
    const file = path.join(value.root, request.file);
    const document = JSON.parse(fs.readFileSync(file, 'utf8'));
    const bytes = Buffer.from(`${JSON.stringify(document, null, 2)}\n`);
    fs.writeFileSync(file, bytes);
    request.size = bytes.length;
    request.sha256 = sha256Bytes(bytes);
    writeIndex(value);
  }, /not canonical/u],
  ['nested inventory fields', (value) => {
    mutateInstalledRequest(value, (document) => {
      document.files[0].chosenMessage = 'not part of the signed schema';
    });
  }, /unexpected fields/u],
  ['duplicate inventory paths', (value) => {
    mutateInstalledRequest(value, (document) => {
      document.files.splice(1, 0, { ...document.files[0] });
    });
  }, /strictly sorted and unique/u]
]) {
  test(`isolated signer rejects ${name}`, (t) => {
    const value = fixture(t);
    const overrides = mutate(value) ?? {};
    assert.throws(() => sign(value, overrides), pattern);
    assert.equal(fs.existsSync(path.join(value.root, 'signed/signing-response.json')), false);
  });
}

function fixture(t, architecture = 'aarch64') {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-release-signer-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const requestsDir = path.join(root, 'requests');
  fs.mkdirSync(requestsDir);
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const privateKeyPem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const publicKeyPem = publicKey.export({ type: 'spki', format: 'pem' });
  const keyId = sha256Bytes(publicKey.export({ type: 'spki', format: 'der' }));
  const version = '1.2.3';
  const gitCommit = 'a'.repeat(40);
  const files = [
    file('/usr/bin/openburnbar-daemon', 'daemon', '0755'),
    file('/usr/bin/openburnbar-linux-desktop', 'desktop', '0755'),
    file(RELEASE_PUBLIC_KEY_PATH, publicKeyPem, '0644')
  ];
  const requests = [];
  for (const format of ['deb', 'rpm', 'arch']) {
    const manifest = createInstalledManifest({
      files,
      packageVersion: version,
      gitCommit,
      packageArchitecture: architecture,
      packageFormat: format,
      firebaseAppId: '1:123456789012:web:abcdef1234567890'
    });
    const bytes = canonicalJsonBytes(manifest);
    requests.push(writeRequest({
      root,
      requestsDir,
      id: `${format}-${architecture}-installed-manifest`,
      kind: 'installed-manifest',
      name: `${format}-${architecture}.installed-manifest.json`,
      bytes
    }));
  }
  const executable = path.join(root, 'openburnbar-linux-desktop');
  fs.writeFileSync(executable, 'desktop\n', { mode: 0o755 });
  const peer = createLinuxAppImagePeerManifest({ executable, keyId });
  requests.push(writeRequest({
    root,
    requestsDir,
    id: `appimage-${architecture}-peer-manifest`,
    kind: 'appimage-peer-manifest',
    name: `appimage-${architecture}.peer-manifest.json`,
    bytes: serializeLinuxAppImagePeerManifest(peer, { trustedKeyId: keyId })
  }));
  const index = {
    schemaVersion: 1,
    product: 'OpenBurnBar',
    version,
    gitCommit,
    architecture,
    requests
  };
  const value = {
    root,
    requestsDir,
    indexFile: path.join(root, 'signing-request.json'),
    index,
    version,
    gitCommit,
    architecture,
    privateKeyPem,
    publicKeyPem,
    publicKey,
    keyId
  };
  writeIndex(value);
  return value;
}

function file(installedPath, content, mode) {
  const bytes = Buffer.from(content);
  return {
    path: installedPath,
    type: 'file',
    sha256: sha256Bytes(bytes),
    size: bytes.length,
    mode,
    uid: 0,
    gid: 0
  };
}

function writeRequest({ root, requestsDir, id, kind, name, bytes }) {
  const destination = path.join(requestsDir, name);
  fs.writeFileSync(destination, bytes);
  return {
    id,
    kind,
    file: path.relative(root, destination).split(path.sep).join('/'),
    sha256: sha256Bytes(bytes),
    size: bytes.length
  };
}

function writeIndex(value) {
  fs.writeFileSync(value.indexFile, canonicalJsonBytes(value.index));
}

function mutateInstalledRequest(value, mutate) {
  const request = value.index.requests[0];
  const file = path.join(value.root, request.file);
  const document = JSON.parse(fs.readFileSync(file, 'utf8'));
  mutate(document);
  document.installedFilesRootSha256 = installedFilesRoot(document.files);
  const bytes = canonicalJsonBytes(document);
  fs.writeFileSync(file, bytes);
  request.size = bytes.length;
  request.sha256 = sha256Bytes(bytes);
  writeIndex(value);
}

function sign(value, overrides = {}) {
  return signLinuxReleaseRequests({
    stateDir: value.root,
    expectedVersion: value.version,
    expectedGitCommit: value.gitCommit,
    expectedArchitecture: value.architecture,
    privateKeyPem: value.privateKeyPem,
    publicKeyPem: value.publicKeyPem,
    expectedPublicKeySpkiSha256: value.keyId,
    ...overrides
  });
}
