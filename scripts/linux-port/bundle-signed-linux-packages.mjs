#!/usr/bin/env node
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  canonicalJsonBytes,
  collectInstalledFiles,
  createInstalledManifest,
  INSTALLED_MANIFEST_PATH,
  INSTALLED_MANIFEST_SIGNATURE_PATH
} from './lib/linux-installed-manifest.mjs';
import {
  extractNativePackage,
  extractPreflightedArchiveBytes,
  inspectNativePackageMetadata,
  isAllowedNativeNonUsrPath,
  NATIVE_PACKAGE_NON_USR_PATH_ALLOWLIST,
  verifySignedNativePackage
} from './lib/linux-native-package.mjs';
import { replaceRpmAttestationFromPayload } from './lib/linux-rpm-attestation.mjs';
import {
  embedLinuxAppImagePayload,
  prepareLinuxAppImagePeerManifest
} from './embed-linux-appimage-payload.mjs';
import { withoutLinuxReleasePrivateKey } from './lib/linux-signing-environment.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const appDir = path.join(repoRoot, 'apps/linux-desktop');
const bundleRoot = path.join(appDir, 'src-tauri/target/release/bundle');
const payloadAttestation = path.join(appDir, 'src-tauri/target/openburnbar-package-payload/attestation');
const publicKeyFile = path.join(repoRoot, 'packaging/linux/openburnbar-linux-ed25519.pub.pem');
const packagePayloadRoot = path.join(appDir, 'src-tauri/target/openburnbar-package-payload');
const phase = requiredArgument('--phase');
const version = requiredArgument('--version');
const gitCommit = requiredArgument('--git-commit');
const stateDir = path.resolve(requiredArgument('--state-dir'));
const architecture = process.arch === 'arm64' ? 'aarch64'
  : process.arch === 'x64' ? 'x86_64' : process.arch;
const firebaseAppId = process.env.OPENBURNBAR_LINUX_APP_CHECK_APP_ID?.trim() ?? '';
const childEnvironment = withoutLinuxReleasePrivateKey(process.env);
const requestsDir = path.join(stateDir, 'requests');
const signedDir = path.join(stateDir, 'signed');
const indexFile = path.join(stateDir, 'signing-request.json');

if (!['prepare', 'finalize'].includes(phase)) throw new Error('--phase must be prepare or finalize');
if (!['aarch64', 'x86_64'].includes(architecture)) throw new Error(`unsupported release architecture: ${architecture}`);
if (process.env.OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM) {
  throw new Error(`${phase} packaging must not receive OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM`);
}

const result = phase === 'prepare' ? prepareSigningRequests() : finalizeSignedPackages();
console.log(JSON.stringify(result, null, 2));

function requiredArgument(name) {
  const index = process.argv.indexOf(name);
  const value = index >= 0 ? process.argv[index + 1]?.trim() : '';
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? repoRoot,
    env: { ...childEnvironment, ...(options.env ?? {}) },
    encoding: options.encoding ?? 'utf8',
    input: options.input,
    maxBuffer: 512 * 1024 * 1024
  });
  if (result.error || (result.status ?? 1) !== 0) {
    throw new Error([
      `${command} ${args.join(' ')} failed`,
      result.error?.message,
      Buffer.isBuffer(result.stdout) ? '' : result.stdout,
      Buffer.isBuffer(result.stderr) ? '' : result.stderr
    ].filter(Boolean).join('\n'));
  }
  return result;
}

function bundleFormat(format, options = {}) {
  if (format === 'rpm') {
    return bundleRpmFromDeb(options.debArtifact);
  }
  const output = path.join(bundleRoot, format);
  fs.rmSync(output, { recursive: true, force: true });
  run('npm', ['run', 'tauri:bundle', '--', '--bundles', format], { cwd: appDir });
  return findSingleArtifact(output, format);
}

/**
 * Tauri's RPM bundler can emit an archive that rpm2cpio rejects after it has
 * already written the payload. Build the RPM from the known-good Tauri DEB
 * data archive instead, so both native package formats own the same files.
 */
function bundleRpmFromDeb(debArtifact) {
  if (!debArtifact || !path.isAbsolute(debArtifact)) {
    throw new Error('RPM bundling requires the absolute Tauri DEB artifact path');
  }
  const debMetadata = inspectNativePackageMetadata('deb', debArtifact, { env: childEnvironment });
  if (debMetadata.packageName !== 'open-burn-bar'
      || debMetadata.packageVersion !== version
      || debMetadata.packageArchitecture !== architecture) {
    throw new Error('RPM source DEB metadata does not match requested release identity');
  }

  const output = path.join(bundleRoot, 'rpm');
  fs.rmSync(output, { recursive: true, force: true });
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-rpm-from-deb-'));
  const extractedRoot = path.join(temporary, 'root');
  const top = path.join(temporary, 'rpmbuild');
  for (const directory of ['BUILD', 'BUILDROOT', 'RPMS', 'SOURCES', 'SPECS', 'SRPMS']) {
    fs.mkdirSync(path.join(top, directory), { recursive: true });
  }

  try {
    const dataArchive = run('dpkg-deb', ['--fsys-tarfile', debArtifact], {
      encoding: 'buffer',
      env: childEnvironment
    }).stdout;
    extractPreflightedArchiveBytes(dataArchive, extractedRoot, {
      env: childEnvironment,
      allowedPaths: NATIVE_PACKAGE_NON_USR_PATH_ALLOWLIST
    });
    replaceRpmAttestationFromPayload({
      extractedRoot,
      payloadAttestation
    });

    const entries = collectRpmFileEntries(extractedRoot);
    const spec = path.join(top, 'SPECS/open-burn-bar.spec');
    fs.writeFileSync(spec, [
      'Name: open-burn-bar',
      `Version: ${rpmSpecToken(version, 'version')}`,
      'Release: 1',
      'Summary: OpenBurnBar Linux desktop client',
      'License: Proprietary',
      `BuildArch: ${rpmSpecToken(architecture, 'architecture')}`,
      'Requires: libsecret',
      '%description',
      'OpenBurnBar Linux desktop client and daemon.',
      '%install',
      'mkdir -p %{buildroot}',
      `cp -a ${shellQuote(extractedRoot)}/. %{buildroot}/`,
      '%files',
      '%defattr(-,root,root,-)',
      ...entries,
      ''
    ].join('\n'));

    run('rpmbuild', ['--define', `_topdir ${top}`, '-bb', spec], {
      env: childEnvironment
    });
    const built = findSingleArtifact(path.join(top, 'RPMS'), 'rpm');
    fs.mkdirSync(output, { recursive: true });
    const destination = path.join(output, `OpenBurnBar-${version}-1.${architecture}.rpm`);
    fs.copyFileSync(built, destination);
    fs.chmodSync(destination, 0o644);
    return destination;
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}

function collectRpmFileEntries(root) {
  const entries = [];
  const walk = (current, relative) => {
    const stat = fs.lstatSync(current);
    if (stat.isDirectory()) {
      if (relative) entries.push(`%dir ${rpmSpecPath(`/${relative}`)}`);
      for (const name of fs.readdirSync(current).sort()) {
        walk(path.join(current, name), relative ? path.posix.join(relative, name) : name);
      }
      return;
    }
    if (stat.isFile() || stat.isSymbolicLink()) {
      entries.push(rpmSpecPath(`/${relative}`));
      return;
    }
    throw new Error(`RPM source DEB contains unsupported file type: /${relative}`);
  };
  walk(root, '');
  return [...new Set(entries)].sort();
}

function rpmSpecPath(value) {
  const packagePath = value.startsWith('/') ? value.slice(1) : value;
  if ((value !== '/usr' && !value.startsWith('/usr/') && !isAllowedNativeNonUsrPath(packagePath))
      || /[\u0000-\u001f\u007f\s]/u.test(value)) {
    throw new Error(`RPM source DEB contains an unsafe payload path: ${JSON.stringify(value)}`);
  }
  return value.replaceAll('%', '%%');
}

function rpmSpecToken(value, label) {
  if (!/^[A-Za-z0-9][A-Za-z0-9.+_]*$/u.test(value)) {
    throw new Error(`RPM ${label} is not representable in the package spec: ${value}`);
  }
  return value;
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

function findSingleArtifact(root, format) {
  const extension = format === 'deb' ? '.deb' : format === 'rpm' ? '.rpm' : '.AppImage';
  const matches = [];
  const pending = [root];
  while (pending.length > 0) {
    const current = pending.pop();
    if (!fs.existsSync(current)) continue;
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) pending.push(full);
      else if (entry.isFile() && entry.name.endsWith(extension)) matches.push(full);
    }
  }
  if (matches.length !== 1) throw new Error(`expected exactly one ${format} artifact, found ${matches.length}`);
  return matches[0];
}

function writeAttestation(manifestBytes, signatureBytes) {
  fs.mkdirSync(payloadAttestation, { recursive: true });
  const manifestFile = path.join(payloadAttestation, path.posix.basename(INSTALLED_MANIFEST_PATH));
  const signatureFile = path.join(payloadAttestation, path.posix.basename(INSTALLED_MANIFEST_SIGNATURE_PATH));
  fs.writeFileSync(manifestFile, manifestBytes, { mode: 0o644 });
  fs.writeFileSync(signatureFile, signatureBytes, { mode: 0o644 });
  fs.chmodSync(manifestFile, 0o644);
  fs.chmodSync(signatureFile, 0o644);
}

function writeProbeAttestation() {
  writeAttestation(Buffer.from('{}\n', 'utf8'), Buffer.alloc(64));
}

function signingRequest(id, kind, file, bytes) {
  fs.writeFileSync(file, bytes, { mode: 0o644, flag: 'wx' });
  return {
    id,
    kind,
    file: path.relative(stateDir, file).split(path.sep).join('/'),
    sha256: sha256(bytes),
    size: bytes.length
  };
}

function prepareSigningRequests() {
  fs.rmSync(stateDir, { recursive: true, force: true });
  fs.mkdirSync(requestsDir, { recursive: true });
  writeProbeAttestation();
  const requests = [];
  const packages = [];
  let debArtifact = null;
  for (const format of ['deb', 'rpm']) {
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), `openburnbar-${format}-request-`));
    try {
      const artifact = bundleFormat(format, format === 'rpm' ? { debArtifact } : undefined);
      if (format === 'deb') debArtifact = artifact;
      const packageMetadata = inspectNativePackageMetadata(format, artifact, { env: childEnvironment });
      if (packageMetadata.packageName !== 'open-burn-bar'
          || packageMetadata.packageVersion !== version
          || packageMetadata.packageArchitecture !== architecture) {
        throw new Error(`${format} manager metadata does not match requested release identity`);
      }
      extractNativePackage(format, artifact, temporary, { env: childEnvironment });
      const manifest = createInstalledManifest({
        files: collectInstalledFiles(temporary),
        packageVersion: packageMetadata.packageVersion,
        gitCommit,
        packageArchitecture: packageMetadata.packageArchitecture,
        packageFormat: format,
        firebaseAppId
      });
      const manifestBytes = canonicalJsonBytes(manifest);
      requests.push(signingRequest(
        `${format}-${architecture}-installed-manifest`,
        'installed-manifest',
        path.join(requestsDir, `${format}-${architecture}.installed-manifest.json`),
        manifestBytes
      ));
      packages.push({ format, packageMetadata, installedFileCount: manifest.files.length });
    } finally {
      fs.rmSync(temporary, { recursive: true, force: true });
    }
  }
  const appImage = bundleFormat('appimage');
  const peer = prepareLinuxAppImagePeerManifest({ appImage, env: childEnvironment });
  requests.push(signingRequest(
    `appimage-${architecture}-peer-manifest`,
    'appimage-peer-manifest',
    path.join(requestsDir, `appimage-${architecture}.peer-manifest.json`),
    peer.manifestBytes
  ));
  // Arch's makepkg lifecycle runs after this prepare phase but before the
  // isolated signer can provide the AppImage peer signature. Give the Arch
  // recipe the exact runtime payload now, while keeping peer attestation out
  // of the intermediate image. Finalize rewrites the same image with the
  // signed peer files before publication; the PKGBUILD deliberately strips
  // those AppImage-only files from the Arch AppDir.
  const intermediateEnvironment = { ...childEnvironment };
  delete intermediateEnvironment.OPENBURNBAR_LINUX_RELEASE_BUILD;
  embedLinuxAppImagePayload({
    appImage,
    payloadRoot: packagePayloadRoot,
    peerManifestBytes: null,
    peerSignature: null,
    env: intermediateEnvironment
  });
  const index = {
    schemaVersion: 1,
    product: 'OpenBurnBar',
    version,
    gitCommit,
    architecture,
    requests
  };
  fs.writeFileSync(indexFile, canonicalJsonBytes(index), { mode: 0o644, flag: 'wx' });
  return { phase, stateDir, indexFile, packages, requests };
}

function readSigningIndex() {
  const bytes = fs.readFileSync(indexFile);
  const index = JSON.parse(bytes.toString('utf8'));
  if (JSON.stringify(Object.keys(index).sort()) !== JSON.stringify([
    'architecture', 'gitCommit', 'product', 'requests', 'schemaVersion', 'version'
  ]) || index.schemaVersion !== 1 || index.product !== 'OpenBurnBar'
      || index.version !== version || index.gitCommit !== gitCommit
      || index.architecture !== architecture || !Array.isArray(index.requests)
      || index.requests.length !== 4 || !bytes.equals(canonicalJsonBytes(index))) {
    throw new Error('signing request index does not match the requested release identity');
  }
  const expected = new Map([
    [`deb-${architecture}-installed-manifest`, 'installed-manifest'],
    [`rpm-${architecture}-installed-manifest`, 'installed-manifest'],
    [`arch-${architecture}-installed-manifest`, 'installed-manifest'],
    [`appimage-${architecture}-peer-manifest`, 'appimage-peer-manifest']
  ]);
  if (index.requests.some((request) =>
    JSON.stringify(Object.keys(request ?? {}).sort()) !== JSON.stringify(['file', 'id', 'kind', 'sha256', 'size'])
      || expected.get(request.id) !== request.kind)
      || new Set(index.requests.map((request) => request.id)).size !== expected.size) {
    throw new Error('signing request index subjects are not exact');
  }
  return index;
}

function readSigningResponse(index) {
  const responseFile = path.join(signedDir, 'signing-response.json');
  const responseBytes = fs.readFileSync(responseFile);
  const response = JSON.parse(responseBytes.toString('utf8'));
  const expectedFiles = [
    'signing-response.json',
    ...index.requests.map((request) => `${request.id}.sig`)
  ].sort();
  if (JSON.stringify(Object.keys(response).sort()) !== JSON.stringify([
    'architecture', 'gitCommit', 'product', 'requestIndexSha256', 'schemaVersion', 'signed', 'version'
  ]) || JSON.stringify(fs.readdirSync(signedDir).sort()) !== JSON.stringify(expectedFiles)
      || response.schemaVersion !== 1 || response.product !== 'OpenBurnBar'
      || response.version !== version || response.gitCommit !== gitCommit
      || response.architecture !== architecture
      || response.requestIndexSha256 !== sha256(fs.readFileSync(indexFile))
      || !Array.isArray(response.signed) || response.signed.length !== index.requests.length
      || !responseBytes.equals(canonicalJsonBytes(response))) {
    throw new Error('isolated signer response does not exactly match the release request');
  }
  const records = new Map(response.signed.map((record) => [record.id, record]));
  if (records.size !== index.requests.length) throw new Error('isolated signer response contains duplicate ids');
  for (const request of index.requests) {
    const record = records.get(request.id);
    const expectedSignatureFile = `signed/${request.id}.sig`;
    if (!record || JSON.stringify(Object.keys(record).sort()) !== JSON.stringify([
      'id', 'requestSha256', 'signatureFile', 'signatureSha256'
    ]) || record.requestSha256 !== request.sha256
        || record.signatureFile !== expectedSignatureFile) {
      throw new Error(`isolated signer response drift: ${request.id}`);
    }
    const signatureBytes = fs.readFileSync(path.join(stateDir, expectedSignatureFile));
    if (signatureBytes.length !== 64 || record.signatureSha256 !== sha256(signatureBytes)) {
      throw new Error(`isolated signer signature drift: ${request.id}`);
    }
  }
  return records;
}

function signedRequest(index, kind, format = null) {
  const request = index.requests.find((entry) => entry.kind === kind
    && (format === null || entry.id === `${format}-${architecture}-installed-manifest`));
  if (!request) throw new Error(`missing ${format ?? kind} signing request`);
  const manifestFile = path.resolve(stateDir, request.file);
  const relative = path.relative(requestsDir, manifestFile);
  if (relative.startsWith('..') || path.isAbsolute(relative)) throw new Error('signing request path escapes request directory');
  const manifestBytes = fs.readFileSync(manifestFile);
  if (manifestBytes.length !== request.size || sha256(manifestBytes) !== request.sha256) {
    throw new Error(`signing request bytes drifted after signing: ${request.id}`);
  }
  const signatureFile = path.join(signedDir, `${request.id}.sig`);
  const signatureBytes = fs.readFileSync(signatureFile);
  if (signatureBytes.length !== 64) throw new Error(`invalid detached signature length: ${request.id}`);
  return { request, manifestBytes, signatureBytes };
}

function finalizeSignedPackages() {
  const index = readSigningIndex();
  readSigningResponse(index);
  const publicKeyPem = fs.readFileSync(publicKeyFile);
  const reports = [];
  let debArtifact = null;
  for (const format of ['deb', 'rpm']) {
    const signed = signedRequest(index, 'installed-manifest', format);
    if (!crypto.verify(null, signed.manifestBytes, crypto.createPublicKey(publicKeyPem), signed.signatureBytes)) {
      throw new Error(`${format} installed manifest signature is invalid`);
    }
    const parsed = JSON.parse(signed.manifestBytes.toString('utf8'));
    if (parsed.packageFormat !== format || parsed.packageArchitecture !== architecture
        || parsed.packageVersion !== version || parsed.gitCommit !== gitCommit) {
      throw new Error(`${format} signed manifest identity does not match final package`);
    }
    writeAttestation(signed.manifestBytes, signed.signatureBytes);
    const artifact = bundleFormat(format, format === 'rpm' ? { debArtifact } : undefined);
    if (format === 'deb') debArtifact = artifact;
    const manifest = verifySignedNativePackage({
      format,
      artifact,
      manifestBytes: signed.manifestBytes,
      signatureBytes: signed.signatureBytes,
      publicKeyPem,
      env: childEnvironment
    });
    const sidecarRoot = path.join(bundleRoot, 'attestation');
    fs.mkdirSync(sidecarRoot, { recursive: true });
    const manifestSidecar = path.join(sidecarRoot, `${format}-${architecture}.installed-manifest.json`);
    const signatureSidecar = `${manifestSidecar}.sig`;
    fs.writeFileSync(manifestSidecar, signed.manifestBytes, { mode: 0o644 });
    fs.writeFileSync(signatureSidecar, signed.signatureBytes, { mode: 0o644 });
    reports.push({
      format,
      architecture,
      artifact,
      manifest: manifestSidecar,
      signature: signatureSidecar,
      installedFileCount: manifest.files.length,
      installedFilesRootSha256: manifest.installedFilesRootSha256
    });
  }
  const appImageSigned = signedRequest(index, 'appimage-peer-manifest');
  // The prepare phase created the AppImage whose GUI executable was hashed in
  // the signed peer request, then embedded the unsigned runtime payload into
  // that same image. Re-running Tauri's AppImage bundler here can rewrite the
  // GUI binary (for example through linuxdeploy/strip), invalidating the
  // signer-bound digest. Finalization must consume the prepared image and let
  // embedLinuxAppImagePayload perform the final signed-payload verification.
  const appImage = findSingleArtifact(path.join(bundleRoot, 'appimage'), 'appimage');
  const appImageReport = embedLinuxAppImagePayload({
    appImage,
    payloadRoot: packagePayloadRoot,
    peerManifestBytes: appImageSigned.manifestBytes,
    peerSignature: appImageSigned.signatureBytes,
    env: childEnvironment
  });
  return { schemaVersion: 1, phase, version, gitCommit, architecture, packages: reports, appImage: appImageReport };
}
