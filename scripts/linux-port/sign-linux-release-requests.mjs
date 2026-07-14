#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { assertInstalledManifest, canonicalJsonBytes } from './lib/linux-installed-manifest.mjs';
import {
  linuxReleasePublicKeySpkiSha256,
  serializeLinuxAppImagePeerManifest,
  validateLinuxAppImagePeerManifest
} from './lib/linux-appimage-peer-manifest.mjs';

const productionPublicKeyFile = new URL(
  '../../packaging/linux/openburnbar-linux-ed25519.pub.pem',
  import.meta.url
);

export function signLinuxReleaseRequests({
  stateDir,
  expectedVersion,
  expectedGitCommit,
  expectedArchitecture,
  privateKeyPem,
  publicKeyPem = fs.readFileSync(productionPublicKeyFile),
  expectedPublicKeySpkiSha256 = linuxReleasePublicKeySpkiSha256
}) {
  const root = path.resolve(stateDir);
  const indexFile = path.join(root, 'signing-request.json');
  const requestsDir = path.join(root, 'requests');
  const signedDir = path.join(root, 'signed');
  if (!privateKeyPem) throw new Error('OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM is required in the isolated signer');
  if (!/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u.test(expectedVersion)
      || !/^[a-f0-9]{40}$/u.test(expectedGitCommit)
      || !['aarch64', 'x86_64'].includes(expectedArchitecture)) {
    throw new Error('isolated signer release identity arguments are invalid');
  }
  assertRegularDirectory(requestsDir, 'signing request directory');
  const privateKey = crypto.createPrivateKey(privateKeyPem);
  const publicKey = crypto.createPublicKey(publicKeyPem);
  if (privateKey.asymmetricKeyType !== 'ed25519' || publicKey.asymmetricKeyType !== 'ed25519') {
    throw new Error('Linux release signer requires Ed25519 keys');
  }
  if (sha256(publicKey.export({ type: 'spki', format: 'der' })) !== expectedPublicKeySpkiSha256) {
    throw new Error('Linux release signer public key is not the pinned AppImage peer key');
  }

  const indexBytes = readRegularNoFollow(indexFile, 'signing request index', 1024 * 1024);
  const index = JSON.parse(indexBytes.toString('utf8'));
  if (JSON.stringify(Object.keys(index).sort()) !== JSON.stringify([
    'architecture', 'gitCommit', 'product', 'requests', 'schemaVersion', 'version'
  ]) || index.schemaVersion !== 1 || index.product !== 'OpenBurnBar'
      || index.version !== expectedVersion || index.gitCommit !== expectedGitCommit
      || index.architecture !== expectedArchitecture
      || !Array.isArray(index.requests) || index.requests.length !== 4
      || !indexBytes.equals(canonicalJsonBytes(index))) {
    throw new Error('invalid Linux release signing request index');
  }
  const expectedRequests = new Map([
    [`deb-${expectedArchitecture}-installed-manifest`, 'installed-manifest'],
    [`rpm-${expectedArchitecture}-installed-manifest`, 'installed-manifest'],
    [`arch-${expectedArchitecture}-installed-manifest`, 'installed-manifest'],
    [`appimage-${expectedArchitecture}-peer-manifest`, 'appimage-peer-manifest']
  ]);
  if (index.requests.some((request) => expectedRequests.get(request.id) !== request.kind)
      || new Set(index.requests.map((request) => request.id)).size !== expectedRequests.size) {
    throw new Error('Linux release signing request subjects are not exact');
  }
  const expectedRequestFiles = index.requests.map((request) => path.posix.basename(request.file)).sort();
  if (JSON.stringify(fs.readdirSync(requestsDir).sort()) !== JSON.stringify(expectedRequestFiles)) {
    throw new Error('Linux release signing request directory contains unexpected subjects');
  }

  const validated = index.requests.map((request) => validateRequest({
    request,
    root,
    requestsDir,
    expectedVersion,
    expectedGitCommit,
    expectedArchitecture,
    expectedPublicKeySpkiSha256
  }));
  fs.rmSync(signedDir, { recursive: true, force: true });
  fs.mkdirSync(signedDir, { recursive: true, mode: 0o700 });
  const signed = validated.map(({ request, bytes }) => {
    const signature = crypto.sign(null, bytes, privateKey);
    if (signature.length !== 64 || !crypto.verify(null, bytes, publicKey, signature)) {
      throw new Error('isolated signer key does not match the pinned Linux release key');
    }
    const signatureFile = path.join(signedDir, `${request.id}.sig`);
    fs.writeFileSync(signatureFile, signature, { mode: 0o600, flag: 'wx' });
    return {
      id: request.id,
      requestSha256: request.sha256,
      signatureFile: path.relative(root, signatureFile).split(path.sep).join('/'),
      signatureSha256: sha256(signature)
    };
  });
  const response = {
    schemaVersion: 1,
    product: 'OpenBurnBar',
    version: index.version,
    gitCommit: index.gitCommit,
    architecture: index.architecture,
    requestIndexSha256: sha256(indexBytes),
    signed
  };
  fs.writeFileSync(
    path.join(signedDir, 'signing-response.json'),
    canonicalJsonBytes(response),
    { mode: 0o644, flag: 'wx' }
  );
  return { stateDir: root, signed };
}

function validateRequest({
  request,
  root,
  requestsDir,
  expectedVersion,
  expectedGitCommit,
  expectedArchitecture,
  expectedPublicKeySpkiSha256
}) {
  const requestKeys = Object.keys(request ?? {}).sort();
  if (JSON.stringify(requestKeys) !== JSON.stringify(['file', 'id', 'kind', 'sha256', 'size'])
      || !['installed-manifest', 'appimage-peer-manifest'].includes(request.kind)
      || !/^[a-z0-9_-]+$/u.test(request.id ?? '')
      || !/^[a-f0-9]{64}$/u.test(request.sha256 ?? '')
      || !Number.isSafeInteger(request.size) || request.size <= 0 || request.size > 16 * 1024 * 1024) {
    throw new Error('invalid Linux release signing request');
  }
  const file = path.resolve(root, request.file);
  if (path.dirname(file) !== requestsDir) throw new Error('signing request path escapes request directory');
  const bytes = readRegularNoFollow(file, `signing request ${request.id}`, 16 * 1024 * 1024);
  if (bytes.length !== request.size || sha256(bytes) !== request.sha256) {
    throw new Error(`signing request drift: ${request.id}`);
  }
  if (request.kind === 'installed-manifest') {
    const manifest = assertInstalledManifest(JSON.parse(bytes.toString('utf8')));
    const expectedFormat = request.id.startsWith('deb-') ? 'deb'
      : request.id.startsWith('rpm-') ? 'rpm' : 'arch';
    if (manifest.packageVersion !== expectedVersion
        || manifest.gitCommit !== expectedGitCommit
        || manifest.packageArchitecture !== expectedArchitecture
        || manifest.packageFormat !== expectedFormat) {
      throw new Error(`installed manifest release identity drift: ${request.id}`);
    }
    if (!bytes.equals(canonicalJsonBytes(manifest))) {
      throw new Error(`installed manifest is not canonical: ${request.id}`);
    }
  } else {
    const manifest = validateLinuxAppImagePeerManifest(
      JSON.parse(bytes.toString('utf8')),
      { trustedKeyId: expectedPublicKeySpkiSha256 }
    );
    if (!bytes.equals(serializeLinuxAppImagePeerManifest(
      manifest,
      { trustedKeyId: expectedPublicKeySpkiSha256 }
    ))) {
      throw new Error(`AppImage peer manifest is not canonical: ${request.id}`);
    }
  }
  return { request, bytes };
}

function assertRegularDirectory(directory, label) {
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error(`${label} is not a regular directory`);
}

function readRegularNoFollow(file, label, maximumBytes) {
  const noFollow = fs.constants.O_NOFOLLOW ?? 0;
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | noFollow);
  } catch (error) {
    if (error?.code === 'ELOOP') throw new Error(`${label} is not a regular file`, { cause: error });
    throw error;
  }
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.size <= 0 || stat.size > maximumBytes) {
      throw new Error(`${label} is not a bounded regular file`);
    }
    return fs.readFileSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function requiredArgument(name) {
  const index = process.argv.indexOf(name);
  const value = index >= 0 ? process.argv[index + 1]?.trim() : '';
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function main() {
  const result = signLinuxReleaseRequests({
    stateDir: requiredArgument('--state-dir'),
    expectedVersion: requiredArgument('--version'),
    expectedGitCommit: requiredArgument('--git-commit'),
    expectedArchitecture: requiredArgument('--architecture'),
    privateKeyPem: process.env.OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM
  });
  console.log(JSON.stringify(result, null, 2));
}

if (path.resolve(process.argv[1] ?? '') === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    console.error(`sign-linux-release-requests: ${error.message}`);
    process.exit(1);
  }
}
