#!/usr/bin/env node
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  assertInstalledManifest,
  canonicalJsonBytes,
  collectInstalledFiles,
  createInstalledManifest
} from './lib/linux-installed-manifest.mjs';
import {
  extractNativePackage,
  inspectNativePackageMetadata,
  verifySignedNativePackage
} from './lib/linux-native-package.mjs';
import { withoutLinuxReleasePrivateKey } from './lib/linux-signing-environment.mjs';
import {
  archPkgbuildCommonSources,
  renderReleasePkgbuild
} from './lib/linux-arch-pkgbuild.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const appDir = path.join(repoRoot, 'apps/linux-desktop');
const bundleRoot = path.join(appDir, 'src-tauri/target/release/bundle');
const publicKeyFile = path.join(repoRoot, 'packaging/linux/openburnbar-linux-ed25519.pub.pem');

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function exactRequestKinds(architecture) {
  return new Map([
    [`deb-${architecture}-installed-manifest`, 'installed-manifest'],
    [`rpm-${architecture}-installed-manifest`, 'installed-manifest'],
    [`arch-${architecture}-installed-manifest`, 'installed-manifest'],
    [`appimage-${architecture}-peer-manifest`, 'appimage-peer-manifest']
  ]);
}

export { renderReleasePkgbuild } from './lib/linux-arch-pkgbuild.mjs';

export function extendSigningIndex({ stateDir, version, gitCommit, architecture, manifestBytes }) {
  const indexFile = path.join(stateDir, 'signing-request.json');
  const requestsDir = path.join(stateDir, 'requests');
  const indexBytes = fs.readFileSync(indexFile);
  const index = JSON.parse(indexBytes.toString('utf8'));
  const initialKinds = new Map(exactRequestKinds(architecture));
  initialKinds.delete(`arch-${architecture}-installed-manifest`);
  assertSigningIndex(index, indexBytes, { version, gitCommit, architecture, expectedKinds: initialKinds });
  if (JSON.stringify(fs.readdirSync(requestsDir).sort())
      !== JSON.stringify(index.requests.map((entry) => path.posix.basename(entry.file)).sort())) {
    throw new Error('Arch prepare found unexpected signing request subjects');
  }
  const manifest = assertInstalledManifest(JSON.parse(manifestBytes.toString('utf8')));
  if (manifest.packageFormat !== 'arch' || manifest.packageName !== 'openburnbar'
      || manifest.packageVersion !== version || manifest.gitCommit !== gitCommit
      || manifest.packageArchitecture !== architecture || !manifestBytes.equals(canonicalJsonBytes(manifest))) {
    throw new Error('Arch installed manifest release identity is invalid');
  }
  const id = `arch-${architecture}-installed-manifest`;
  const requestFile = path.join(requestsDir, `arch-${architecture}.installed-manifest.json`);
  fs.writeFileSync(requestFile, manifestBytes, { mode: 0o644, flag: 'wx' });
  index.requests.splice(index.requests.length - 1, 0, {
    id,
    kind: 'installed-manifest',
    file: path.relative(stateDir, requestFile).split(path.sep).join('/'),
    sha256: sha256(manifestBytes),
    size: manifestBytes.length
  });
  const nextBytes = canonicalJsonBytes(index);
  assertSigningIndex(index, nextBytes, {
    version,
    gitCommit,
    architecture,
    expectedKinds: exactRequestKinds(architecture)
  });
  const temporary = `${indexFile}.arch-${process.pid}`;
  fs.writeFileSync(temporary, nextBytes, { mode: 0o644, flag: 'wx' });
  fs.renameSync(temporary, indexFile);
  return index.requests.find((entry) => entry.id === id);
}

function assertSigningIndex(index, bytes, { version, gitCommit, architecture, expectedKinds }) {
  if (JSON.stringify(Object.keys(index ?? {}).sort()) !== JSON.stringify([
    'architecture', 'gitCommit', 'product', 'requests', 'schemaVersion', 'version'
  ]) || index.schemaVersion !== 1 || index.product !== 'OpenBurnBar'
      || index.version !== version || index.gitCommit !== gitCommit
      || index.architecture !== architecture || !Array.isArray(index.requests)
      || index.requests.length !== expectedKinds.size || !bytes.equals(canonicalJsonBytes(index))) {
    throw new Error('Arch signing request index does not match the release identity');
  }
  const ids = new Set();
  for (const request of index.requests) {
    if (JSON.stringify(Object.keys(request ?? {}).sort()) !== JSON.stringify(['file', 'id', 'kind', 'sha256', 'size'])
        || expectedKinds.get(request.id) !== request.kind || ids.has(request.id)
        || path.posix.dirname(request.file) !== 'requests'
        || !/^[a-f0-9]{64}$/u.test(request.sha256)
        || !Number.isSafeInteger(request.size) || request.size <= 0) {
      throw new Error('Arch signing request index subjects are not exact');
    }
    ids.add(request.id);
  }
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? repoRoot,
    env: { ...withoutLinuxReleasePrivateKey(process.env), ...(options.env ?? {}) },
    encoding: 'utf8',
    maxBuffer: 512 * 1024 * 1024
  });
  if (result.error || result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed\n${result.stdout ?? ''}\n${result.stderr ?? ''}`);
  }
  return result;
}

function findFiles(root, suffix) {
  const found = [];
  const pending = [root];
  while (pending.length > 0) {
    const current = pending.pop();
    if (!fs.existsSync(current)) continue;
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) pending.push(full);
      else if (entry.isFile() && entry.name.endsWith(suffix)) found.push(full);
    }
  }
  return found.sort();
}

function findSingle(root, suffix) {
  const found = findFiles(root, suffix);
  if (found.length !== 1) throw new Error(`expected exactly one ${suffix} input, found ${found.length}`);
  return found[0];
}

function findPackageArtifacts(root) {
  const found = [];
  const pending = [root];
  while (pending.length > 0) {
    const current = pending.pop();
    if (!fs.existsSync(current)) continue;
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name);
      const stat = fs.lstatSync(full);
      if (stat.isDirectory() && !stat.isSymbolicLink()) pending.push(full);
      else if (entry.name.endsWith('.pkg.tar.zst')) found.push(full);
    }
  }
  return found.sort();
}

export function selectArchPackageArtifact(packageDir, { version, architecture }) {
  if (!/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u.test(version)) {
    throw new Error(`Arch package artifact version is invalid: ${version}`);
  }
  if (!['aarch64', 'x86_64'].includes(architecture)) {
    throw new Error(`Arch package artifact architecture is invalid: ${architecture}`);
  }
  const artifacts = findPackageArtifacts(packageDir);
  const canonicalName = `openburnbar-${version}-1-${architecture}.pkg.tar.zst`;
  const canonical = artifacts.filter((file) => path.basename(file) === canonicalName);
  if (canonical.length !== 1) {
    throw new Error(
      `expected exactly one canonical Arch package input ${canonicalName}, found ${canonical.length}`
    );
  }
  const canonicalStat = fs.lstatSync(canonical[0]);
  if (!canonicalStat.isFile() || canonicalStat.isSymbolicLink()) {
    throw new Error(`canonical Arch package output is not a regular file: ${canonical[0]}`);
  }
  const debugName = `openburnbar-debug-${version}-1-${architecture}.pkg.tar.zst`;
  const extras = artifacts.filter((file) => path.basename(file) !== canonicalName);
  const unexpected = extras.filter((file) => path.basename(file) !== debugName);
  if (unexpected.length > 0) {
    throw new Error(`unexpected Arch package outputs: ${unexpected.map((file) => path.basename(file)).join(', ')}`);
  }
  for (const debugFile of extras) {
    const stat = fs.lstatSync(debugFile);
    if (!stat.isFile() || stat.isSymbolicLink()) {
      throw new Error(`Arch debug package output is not a regular file: ${debugFile}`);
    }
    fs.rmSync(debugFile);
  }
  return canonical[0];
}

function sourceInputs({ version, architecture, manifestBytes, signatureBytes }) {
  const appImage = findSingle(path.join(bundleRoot, 'appimage'), '.AppImage');
  const daemon = path.join(appDir, 'src-tauri/target/openburnbar-package-payload/openburnbar-daemon');
  if (!fs.existsSync(daemon)) throw new Error(`Arch package daemon input is missing: ${daemon}`);
  const appImageArchitecture = architecture === 'x86_64' ? 'amd64' : architecture;
  const suffix = architecture.toUpperCase();
  const commonNames = new Map([
    ['DESKTOP', 'openburnbar.desktop'],
    ['SAFE_MODE_DESKTOP', 'openburnbar-safe-mode.desktop'],
    ['SERVICE', 'openburnbar-daemon.service'],
    ['LAUNCH', 'openburnbar-daemon-launch'],
    ['DESKTOP_LAUNCHER', 'openburnbar-linux-desktop'],
    ['ICON', 'openburnbar-icon.png'],
    ['COMPUTER_USE_POLKIT_POLICY', 'com.openburnbar.computer-use.policy'],
    ['PLAYWRIGHT_BRIDGE', 'openburnbar-playwright-bridge.js'],
    ['BROWSER_RUNTIME_PROBE', 'openburnbar-browser-runtime-probe'],
    ['BROWSER_RUNTIME_REQUIREMENTS', 'browser-runtime-requirements.json'],
    ['RELEASE_PUBLIC_KEY', 'release-ed25519.pub.pem']
  ]);
  return new Map([
    [`APPIMAGE_${suffix}`, [`OpenBurnBar_${version}_${appImageArchitecture}.AppImage`, appImage]],
    [`DAEMON_${suffix}`, [`openburnbar-daemon-${version}-${architecture}`, daemon]],
    ...archPkgbuildCommonSources.map(([slot, relativeFile]) => [
      slot,
      [commonNames.get(slot), path.join(repoRoot, relativeFile)]
    ]),
    [`INSTALLED_MANIFEST_${suffix}`, ['installed-manifest.json', manifestBytes]],
    [`INSTALLED_MANIFEST_SIGNATURE_${suffix}`, ['installed-manifest.ed25519', signatureBytes]]
  ]);
}

function buildArchPackage({ version, architecture, manifestBytes, signatureBytes }) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-arch-makepkg-'));
  try {
    const buildDir = path.join(root, 'build');
    const sourceDir = path.join(root, 'sources');
    const packageDir = path.join(root, 'packages');
    const home = path.join(root, 'home');
    for (const directory of [buildDir, sourceDir, packageDir, home]) fs.mkdirSync(directory, { recursive: true });
    const sources = sourceInputs({ version, architecture, manifestBytes, signatureBytes });
    const checksums = {};
    for (const [slot, [rawName, value]] of sources) {
      const name = rawName;
      const bytes = Buffer.isBuffer(value) ? value : fs.readFileSync(value);
      fs.writeFileSync(path.join(sourceDir, name), bytes, { mode: 0o644 });
      fs.writeFileSync(path.join(buildDir, name), bytes, { mode: 0o644 });
      checksums[slot] = sha256(bytes);
    }
    for (const inactiveArchitecture of ['X86_64', 'AARCH64'].filter((entry) => entry !== architecture.toUpperCase())) {
      for (const slot of ['APPIMAGE', 'DAEMON', 'INSTALLED_MANIFEST', 'INSTALLED_MANIFEST_SIGNATURE']) {
        checksums[`${slot}_${inactiveArchitecture}`] = '0'.repeat(64);
      }
    }
    const template = fs.readFileSync(path.join(repoRoot, 'packaging/linux/aur/PKGBUILD.in'), 'utf8');
    fs.writeFileSync(path.join(buildDir, 'PKGBUILD'), renderReleasePkgbuild(template, { version, checksums }));
    run('chown', ['-R', 'openburnbar-builder:openburnbar-builder', root]);
    const makepkgConfig = path.join(root, 'makepkg.conf');
    const config = fs.readFileSync('/etc/makepkg.conf', 'utf8').replace(/^CARCH=.*$/mu, `CARCH="${architecture}"`);
    fs.writeFileSync(makepkgConfig, config);
    fs.chownSync(makepkgConfig, 1000, 1000);
    run('runuser', ['-u', 'openburnbar-builder', '--', 'env',
      `HOME=${home}`, `SRCDEST=${sourceDir}`, `PKGDEST=${packageDir}`,
      'makepkg', '--config', makepkgConfig, '--cleanbuild', '--force', '--nodeps', '--noconfirm'
    ], { cwd: buildDir });
    const artifact = selectArchPackageArtifact(packageDir, { version, architecture });
    const destination = path.join(root, path.basename(artifact));
    fs.copyFileSync(artifact, destination);
    return { root, artifact: destination };
  } catch (error) {
    fs.rmSync(root, { recursive: true, force: true });
    throw error;
  }
}

function readSignedArchRequest({ stateDir, version, gitCommit, architecture }) {
  const indexFile = path.join(stateDir, 'signing-request.json');
  const indexBytes = fs.readFileSync(indexFile);
  const index = JSON.parse(indexBytes.toString('utf8'));
  assertSigningIndex(index, indexBytes, { version, gitCommit, architecture, expectedKinds: exactRequestKinds(architecture) });
  const request = index.requests.find((entry) => entry.id === `arch-${architecture}-installed-manifest`);
  const manifestBytes = fs.readFileSync(path.join(stateDir, request.file));
  if (manifestBytes.length !== request.size || sha256(manifestBytes) !== request.sha256) {
    throw new Error('Arch signed request bytes drifted');
  }
  const responseBytes = fs.readFileSync(path.join(stateDir, 'signed/signing-response.json'));
  const response = JSON.parse(responseBytes.toString('utf8'));
  const expectedSignedFiles = [
    'signing-response.json',
    ...index.requests.map((entry) => `${entry.id}.sig`)
  ].sort();
  if (JSON.stringify(Object.keys(response ?? {}).sort()) !== JSON.stringify([
    'architecture', 'gitCommit', 'product', 'requestIndexSha256', 'schemaVersion', 'signed', 'version'
  ]) || JSON.stringify(fs.readdirSync(path.join(stateDir, 'signed')).sort()) !== JSON.stringify(expectedSignedFiles)
      || response.schemaVersion !== 1 || response.product !== 'OpenBurnBar'
      || response.requestIndexSha256 !== sha256(indexBytes) || response.version !== version
      || response.gitCommit !== gitCommit || response.architecture !== architecture
      || !Array.isArray(response.signed) || response.signed.length !== 4
      || !responseBytes.equals(canonicalJsonBytes(response))) {
    throw new Error('Arch isolated signer response does not match the request index');
  }
  const records = new Map(response.signed.map((entry) => [entry.id, entry]));
  if (records.size !== index.requests.length) throw new Error('Arch isolated signer response contains duplicate subjects');
  for (const indexedRequest of index.requests) {
    const signedRecord = records.get(indexedRequest.id);
    if (!signedRecord || JSON.stringify(Object.keys(signedRecord).sort()) !== JSON.stringify([
      'id', 'requestSha256', 'signatureFile', 'signatureSha256'
    ]) || signedRecord.requestSha256 !== indexedRequest.sha256
        || signedRecord.signatureFile !== `signed/${indexedRequest.id}.sig`) {
      throw new Error(`Arch isolated signer response subject drift: ${indexedRequest.id}`);
    }
    const bytes = fs.readFileSync(path.join(stateDir, signedRecord.signatureFile));
    if (bytes.length !== 64 || signedRecord.signatureSha256 !== sha256(bytes)) {
      throw new Error(`Arch isolated signer signature drift: ${indexedRequest.id}`);
    }
  }
  const record = records.get(request.id);
  const signatureBytes = fs.readFileSync(path.join(stateDir, record.signatureFile));
  const publicKeyPem = fs.readFileSync(publicKeyFile);
  if (!crypto.verify(null, manifestBytes, crypto.createPublicKey(publicKeyPem), signatureBytes)) {
    throw new Error('Arch installed manifest signature is invalid');
  }
  return { manifestBytes, signatureBytes, publicKeyPem };
}

export function buildSignedArchPackage({ phase, version, gitCommit, architecture, stateDir, firebaseAppId }) {
  if (!['prepare', 'finalize'].includes(phase)) throw new Error('Arch package phase must be prepare or finalize');
  if (!['aarch64', 'x86_64'].includes(architecture)) throw new Error('Arch package architecture is unsupported');
  if (process.env.OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM) {
    throw new Error('Arch package build must not receive the Linux release private key');
  }
  if (phase === 'prepare') {
    const probe = buildArchPackage({ version, architecture, manifestBytes: Buffer.from('{}\n'), signatureBytes: Buffer.alloc(64) });
    const extracted = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-arch-probe-'));
    try {
      const metadata = inspectNativePackageMetadata('arch', probe.artifact);
      if (metadata.packageName !== 'openburnbar' || metadata.packageVersion !== version
          || metadata.packageArchitecture !== architecture) {
        throw new Error('Arch package manager metadata does not match the requested release identity');
      }
      extractNativePackage('arch', probe.artifact, extracted);
      const manifest = createInstalledManifest({
        files: collectInstalledFiles(extracted),
        packageVersion: version,
        gitCommit,
        packageArchitecture: architecture,
        packageFormat: 'arch',
        firebaseAppId
      });
      const request = extendSigningIndex({
        stateDir,
        version,
        gitCommit,
        architecture,
        manifestBytes: canonicalJsonBytes(manifest)
      });
      return { phase, request, installedFileCount: manifest.files.length };
    } finally {
      fs.rmSync(extracted, { recursive: true, force: true });
      fs.rmSync(probe.root, { recursive: true, force: true });
    }
  }
  const signed = readSignedArchRequest({ stateDir, version, gitCommit, architecture });
  const built = buildArchPackage({ version, architecture, ...signed });
  try {
    const manifest = verifySignedNativePackage({
      format: 'arch', artifact: built.artifact, ...signed
    });
    const archBundle = path.join(bundleRoot, 'arch');
    const attestationBundle = path.join(bundleRoot, 'attestation');
    fs.rmSync(archBundle, { recursive: true, force: true });
    fs.mkdirSync(archBundle, { recursive: true });
    fs.mkdirSync(attestationBundle, { recursive: true });
    const artifact = path.join(archBundle, path.basename(built.artifact));
    const manifestFile = path.join(attestationBundle, `arch-${architecture}.installed-manifest.json`);
    fs.copyFileSync(built.artifact, artifact);
    fs.writeFileSync(manifestFile, signed.manifestBytes, { mode: 0o644 });
    fs.writeFileSync(`${manifestFile}.sig`, signed.signatureBytes, { mode: 0o644 });
    return { phase, artifact, manifest: manifestFile, signature: `${manifestFile}.sig`, installedFileCount: manifest.files.length };
  } finally {
    fs.rmSync(built.root, { recursive: true, force: true });
  }
}

function requiredArgument(name) {
  const index = process.argv.indexOf(name);
  const value = index >= 0 ? process.argv[index + 1]?.trim() : '';
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function main() {
  const result = buildSignedArchPackage({
    phase: requiredArgument('--phase'),
    version: requiredArgument('--version'),
    gitCommit: requiredArgument('--git-commit'),
    architecture: requiredArgument('--architecture'),
    stateDir: path.resolve(requiredArgument('--state-dir')),
    firebaseAppId: process.env.OPENBURNBAR_LINUX_APP_CHECK_APP_ID?.trim() ?? ''
  });
  console.log(JSON.stringify(result, null, 2));
}

if (path.resolve(process.argv[1] ?? '') === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    console.error(`build-signed-arch-package: ${error.message}`);
    process.exit(1);
  }
}
