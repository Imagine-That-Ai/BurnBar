#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { discoverBundleArtifacts, relative, repoRoot } from './lib/linux-release-common.mjs';
import { findAppImageFilesystemOffset } from './lib/appimage-filesystem.mjs';
import {
  createLinuxAppImagePeerManifest,
  linuxAppImagePeerExecutableRelativePath,
  linuxAppImagePeerManifestName,
  linuxAppImagePeerSignatureName,
  serializeLinuxAppImagePeerManifest,
  verifyLinuxAppImagePeerManifest,
} from './lib/linux-appimage-peer-manifest.mjs';
import { withoutLinuxReleasePrivateKey } from './lib/linux-signing-environment.mjs';

export const linuxResourceBundlesRelativePath = 'resource-bundles';

export const requiredPayloadPaths = [
  'openburnbar-cli',
  'openburnbar-daemon',
  linuxResourceBundlesRelativePath,
  'swift',
  'native/libsqlcipher.so.0',
  'native/libopenburnbar_iroh.so',
  'playwright/openburnbar-playwright-bridge.js',
  'playwright/openburnbar-browser-runtime-probe',
  'playwright/browser-runtime-requirements.json',
  'cloud-auth.json'
];

function requirePath(candidate, label, expectedType) {
  if (!fs.existsSync(candidate)) throw new Error(`${label} missing: ${candidate}`);
  const stat = fs.statSync(candidate);
  if (expectedType === 'file' && !stat.isFile()) throw new Error(`${label} is not a file: ${candidate}`);
  if (expectedType === 'directory' && !stat.isDirectory()) throw new Error(`${label} is not a directory: ${candidate}`);
}

function requireRegularResource(candidate, label, expectedMode) {
  if (!fs.existsSync(candidate)) throw new Error(`${label} missing: ${candidate}`);
  const stat = fs.lstatSync(candidate);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error(`${label} is not a regular file: ${candidate}`);
  }
  if ((stat.mode & 0o777) !== expectedMode) {
    throw new Error(`${label} mode must be ${expectedMode.toString(8)}: ${candidate}`);
  }
}

const absolutePackagedDesktopExec = /(?<=[= \t])\/usr\/bin\/openburnbar-linux-desktop(?=[\s%]|$)/gu;
const absolutePackagedAppRunExec = /(?<=[= \t"'])\/usr\/bin\/openburnbar-linux-desktop(?=[\s"']|$)/gu;

/**
 * Installed deb/rpm/AUR launchers intentionally pin Exec=/usr/bin/... so PATH
 * cannot shadow the package. AppImage extract-and-run resolves that absolute
 * path on the host, so rewrite in-AppDir launchers to the basename (or
 * $APPDIR-relative form) before the squashfs is rebuilt.
 */
export function normalizeAppImageHostLaunchPaths(appDir) {
  const root = path.resolve(appDir);
  requirePath(root, 'AppImage root', 'directory');

  const desktopBinary = path.join(root, linuxAppImagePeerExecutableRelativePath);
  const productBinary = path.join(root, 'usr/bin/OpenBurnBar');
  if (!fs.existsSync(desktopBinary)) {
    if (!fs.existsSync(productBinary)) {
      throw new Error(`AppImage GUI executable missing: ${desktopBinary}`);
    }
    fs.copyFileSync(productBinary, desktopBinary);
    fs.chmodSync(desktopBinary, 0o755);
  }

  const rewritten = [];
  const visit = (directory) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const full = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        visit(full);
        continue;
      }
      if (!entry.isFile()) continue;
      if (!(entry.name.endsWith('.desktop') || entry.name === 'AppRun')) continue;
      const fd = fs.openSync(full, 'r+');
      try {
        if (!fs.fstatSync(fd).isFile()) continue;
        const original = fs.readFileSync(fd, 'utf8');
        const pattern = entry.name === 'AppRun' ? absolutePackagedAppRunExec : absolutePackagedDesktopExec;
        const updated = original.replace(pattern, 'openburnbar-linux-desktop');
        if (updated !== original) {
          fs.ftruncateSync(fd, 0);
          fs.writeSync(fd, updated, 0, 'utf8');
          rewritten.push(path.relative(root, full).split(path.sep).join('/'));
        }
      } finally {
        fs.closeSync(fd);
      }
    }
  };
  visit(root);
  return { desktopBinary, rewritten };
}

export function validatePayload(payloadRoot) {
  const root = path.resolve(payloadRoot);
  for (const entry of requiredPayloadPaths) {
    requirePath(
      path.join(root, entry),
      `AppImage payload ${entry}`,
      entry === 'swift' || entry === linuxResourceBundlesRelativePath ? 'directory' : 'file'
    );
  }
  const resourceBundles = fs.readdirSync(path.join(root, linuxResourceBundlesRelativePath))
    .filter((entry) => /^OpenBurnBarCore_.+\.resources$/u.test(entry));
  if (resourceBundles.length === 0) throw new Error('AppImage payload has no OpenBurnBarCore resource bundles');
  requireRegularResource(
    path.join(root, 'openburnbar-cli'),
    'AppImage OpenBurnBar CLI',
    0o755
  );
  requireRegularResource(
    path.join(root, 'native/libopenburnbar_iroh.so'),
    'AppImage iroh native runtime',
    0o644
  );
  requireRegularResource(
    path.join(root, 'playwright/openburnbar-playwright-bridge.js'),
    'AppImage Playwright bridge',
    0o644
  );
  requireRegularResource(
    path.join(root, 'playwright/openburnbar-browser-runtime-probe'),
    'AppImage browser runtime probe',
    0o755
  );
  requireRegularResource(
    path.join(root, 'playwright/browser-runtime-requirements.json'),
    'AppImage browser runtime requirements',
    0o644
  );
  requireRegularResource(path.join(root, 'cloud-auth.json'), 'AppImage cloud auth config', 0o644);
  return root;
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env: options.env ?? process.env,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024
  });
  if ((result.status ?? 1) !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed:\n${result.stdout ?? ''}\n${result.stderr ?? ''}`);
  }
  return result.stdout ?? '';
}

function copyFileRange(source, destination, bytes = null) {
  const sourceFd = fs.openSync(source, 'r');
  const destinationFd = fs.openSync(destination, 'a');
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  let position = 0;
  try {
    while (bytes === null || position < bytes) {
      const length = bytes === null ? buffer.length : Math.min(buffer.length, bytes - position);
      const read = fs.readSync(sourceFd, buffer, 0, length, position);
      if (read === 0) break;
      fs.writeSync(destinationFd, buffer, 0, read);
      position += read;
    }
  } finally {
    fs.closeSync(sourceFd);
    fs.closeSync(destinationFd);
  }
  if (bytes !== null && position !== bytes) {
    throw new Error(`AppImage runtime stub truncated: expected ${bytes} bytes, copied ${position}`);
  }
}

function assertEmbeddedPayload(appDir, { requirePeerManifest }) {
  const required = [
    'usr/bin/openburnbar-linux-desktop',
    'usr/bin/openburnbar-cli',
    'usr/bin/openburnbar-daemon',
    'usr/libexec/openburnbar-daemon-launch',
    'usr/lib/openburnbar/swift',
    'usr/lib/openburnbar/native/libsqlcipher.so.0',
    'usr/lib/openburnbar/native/libopenburnbar_iroh.so',
    'usr/lib/openburnbar/playwright/openburnbar-playwright-bridge.js',
    'usr/lib/openburnbar/playwright/openburnbar-browser-runtime-probe',
    'usr/lib/openburnbar/playwright/browser-runtime-requirements.json',
    'usr/share/openburnbar/cloud-auth.json'
  ];
  if (requirePeerManifest) {
    required.push(
      `usr/share/openburnbar/${linuxAppImagePeerManifestName}`,
      `usr/share/openburnbar/${linuxAppImagePeerSignatureName}`
    );
  }
  for (const entry of required) {
    requirePath(
      path.join(appDir, entry),
      `embedded AppImage path ${entry}`,
      entry.endsWith('/swift')
        ? 'directory'
        : 'file'
    );
  }
  const embeddedResourceBundles = fs.readdirSync(path.join(appDir, 'usr/bin'))
    .filter((entry) => /^OpenBurnBarCore_.+\.resources$/u.test(entry));
  if (embeddedResourceBundles.length === 0) {
    throw new Error('embedded AppImage has no OpenBurnBarCore resource bundles');
  }
  requireRegularResource(
    path.join(appDir, 'usr/lib/openburnbar/native/libopenburnbar_iroh.so'),
    'embedded AppImage iroh native runtime',
    0o644
  );
  requireRegularResource(
    path.join(appDir, 'usr/lib/openburnbar/playwright/openburnbar-playwright-bridge.js'),
    'embedded AppImage Playwright bridge',
    0o644
  );
  requireRegularResource(
    path.join(appDir, 'usr/lib/openburnbar/playwright/openburnbar-browser-runtime-probe'),
    'embedded AppImage browser runtime probe',
    0o755
  );
  requireRegularResource(
    path.join(appDir, 'usr/share/openburnbar/cloud-auth.json'),
    'embedded AppImage cloud auth config',
    0o644
  );
  if (requirePeerManifest) {
    requireRegularResource(
      path.join(appDir, `usr/share/openburnbar/${linuxAppImagePeerManifestName}`),
      'embedded AppImage peer manifest',
      0o644
    );
    requireRegularResource(
      path.join(appDir, `usr/share/openburnbar/${linuxAppImagePeerSignatureName}`),
      'embedded AppImage peer manifest signature',
      0o644
    );
    verifyLinuxAppImagePeerManifest({
      manifestBytes: fs.readFileSync(path.join(appDir, `usr/share/openburnbar/${linuxAppImagePeerManifestName}`)),
      signature: fs.readFileSync(path.join(appDir, `usr/share/openburnbar/${linuxAppImagePeerSignatureName}`)),
      executable: path.join(appDir, linuxAppImagePeerExecutableRelativePath),
      publicKeyPem: fs.readFileSync(path.join(repoRoot, 'packaging/linux/openburnbar-linux-ed25519.pub.pem'))
    });
  }
}

export function resolveLinuxAppImagePeerAttestation({ manifestBytes, signature, environment }) {
  if (environment.OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM) {
    throw new Error('AppImage packaging must not receive OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM');
  }
  if ((manifestBytes === null) !== (signature === null)) {
    throw new Error('AppImage peer manifest and signature must be supplied together');
  }
  if (environment.OPENBURNBAR_LINUX_RELEASE_BUILD === '1' && manifestBytes === null) {
    throw new Error('pre-signed AppImage peer manifest and signature are required for release packaging');
  }
  return manifestBytes === null ? null : { manifestBytes, signature };
}

export function prepareLinuxAppImagePeerManifest({ appImage, env = process.env }) {
  if (env.OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM) {
    throw new Error('AppImage signing preparation must not receive the Linux release private key');
  }
  const image = path.resolve(appImage);
  requirePath(image, 'base AppImage', 'file');
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-appimage-signing-request-'));
  const appImageEnv = { ...withoutLinuxReleasePrivateKey(env), APPIMAGE_EXTRACT_AND_RUN: '1' };
  try {
    const appDir = path.join(work, 'squashfs-root');
    run('unsquashfs', [
      '-quiet',
      '-no-progress',
      '-dest',
      appDir,
      '-offset',
      String(findAppImageFilesystemOffset(image)),
      image
    ], { cwd: work, env: appImageEnv });
    normalizeAppImageHostLaunchPaths(appDir);
    const executable = path.join(appDir, linuxAppImagePeerExecutableRelativePath);
    const manifest = createLinuxAppImagePeerManifest({ executable });
    return { manifest, manifestBytes: serializeLinuxAppImagePeerManifest(manifest) };
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

export function embedLinuxAppImagePayload({
  appImage,
  payloadRoot,
  peerManifestBytes = null,
  peerSignature = null,
  env = process.env
}) {
  const image = path.resolve(appImage);
  const payload = validatePayload(payloadRoot);
  requirePath(image, 'base AppImage', 'file');
  fs.chmodSync(image, 0o755);

  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-appimage-'));
  const verify = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-appimage-verify-'));
  const squash = path.join(work, 'openburnbar.squashfs');
  const candidate = `${image}.payload.tmp`;
  const appImageEnv = {
    ...withoutLinuxReleasePrivateKey(env),
    APPIMAGE_EXTRACT_AND_RUN: '1'
  };
  const runtimeProbe = env.OPENBURNBAR_APPIMAGE_RUNTIME_PROBE?.trim() || 'appimage';
  const peerAttestation = resolveLinuxAppImagePeerAttestation({
    manifestBytes: peerManifestBytes,
    signature: peerSignature,
    environment: env
  });
  if (!['appimage', 'extracted'].includes(runtimeProbe)) {
    throw new Error(`invalid OPENBURNBAR_APPIMAGE_RUNTIME_PROBE: ${runtimeProbe}`);
  }
  try {
    const offset = findAppImageFilesystemOffset(image);
    const appDir = path.join(work, 'squashfs-root');
    run('unsquashfs', [
      '-quiet',
      '-no-progress',
      '-dest',
      appDir,
      '-offset',
      String(offset),
      image
    ], { cwd: work, env: appImageEnv });
    requirePath(appDir, 'extracted AppImage root', 'directory');
    normalizeAppImageHostLaunchPaths(appDir);

    fs.mkdirSync(path.join(appDir, 'usr/bin'), { recursive: true });
    fs.copyFileSync(path.join(payload, 'openburnbar-cli'), path.join(appDir, 'usr/bin/openburnbar-cli'));
    fs.chmodSync(path.join(appDir, 'usr/bin/openburnbar-cli'), 0o755);
    fs.copyFileSync(path.join(payload, 'openburnbar-daemon'), path.join(appDir, 'usr/bin/openburnbar-daemon'));
    fs.chmodSync(path.join(appDir, 'usr/bin/openburnbar-daemon'), 0o755);
    for (const entry of fs.readdirSync(path.join(payload, linuxResourceBundlesRelativePath))) {
      if (!/^OpenBurnBarCore_.+\.resources$/u.test(entry)) continue;
      fs.rmSync(path.join(appDir, 'usr/bin', entry), { recursive: true, force: true });
      fs.cpSync(
        path.join(payload, linuxResourceBundlesRelativePath, entry),
        path.join(appDir, 'usr/bin', entry),
        { recursive: true, dereference: false, preserveTimestamps: true }
      );
    }
    fs.rmSync(path.join(appDir, 'usr/lib/openburnbar/swift'), { recursive: true, force: true });
    fs.rmSync(path.join(appDir, 'usr/lib/openburnbar/native'), { recursive: true, force: true });
    fs.rmSync(path.join(appDir, 'usr/lib/openburnbar/playwright'), { recursive: true, force: true });
    fs.mkdirSync(path.join(appDir, 'usr/lib/openburnbar'), { recursive: true });
    fs.cpSync(path.join(payload, 'swift'), path.join(appDir, 'usr/lib/openburnbar/swift'), {
      recursive: true,
      dereference: false,
      preserveTimestamps: true
    });
    fs.cpSync(path.join(payload, 'native'), path.join(appDir, 'usr/lib/openburnbar/native'), {
      recursive: true,
      dereference: false,
      preserveTimestamps: true
    });
    fs.cpSync(path.join(payload, 'playwright'), path.join(appDir, 'usr/lib/openburnbar/playwright'), {
      recursive: true,
      dereference: false,
      preserveTimestamps: true
    });
    // Optional native Fcitx5 addon: carried as payload so the Arch recipe can
    // repackage it from the extracted AppImage. The AppImage itself performs
    // no system input-method registration - a transient mount path cannot
    // satisfy the signed manifest path identity.
    const fcitx5Payload = path.join(payload, 'fcitx5-addon');
    if (fs.existsSync(fcitx5Payload)) {
      const fcitx5Lib = path.join(appDir, 'usr/lib/openburnbar/fcitx5');
      const fcitx5Share = path.join(appDir, 'usr/share/openburnbar/text-expansion/fcitx5');
      fs.rmSync(fcitx5Lib, { recursive: true, force: true });
      fs.rmSync(fcitx5Share, { recursive: true, force: true });
      fs.mkdirSync(fcitx5Lib, { recursive: true });
      fs.mkdirSync(path.join(fcitx5Share, 'addon'), { recursive: true });
      fs.mkdirSync(path.join(fcitx5Share, 'inputmethod'), { recursive: true });
      fs.copyFileSync(
        path.join(fcitx5Payload, 'openburnbar-fcitx5.so'),
        path.join(fcitx5Lib, 'openburnbar-fcitx5.so')
      );
      fs.chmodSync(path.join(fcitx5Lib, 'openburnbar-fcitx5.so'), 0o755);
      fs.copyFileSync(
        path.join(fcitx5Payload, 'addon/openburnbar-fcitx5.conf'),
        path.join(fcitx5Share, 'addon/openburnbar-fcitx5.conf')
      );
      fs.copyFileSync(
        path.join(fcitx5Payload, 'inputmethod/openburnbar.conf'),
        path.join(fcitx5Share, 'inputmethod/openburnbar.conf')
      );
      fs.copyFileSync(
        path.join(payload, 'text-expansion-engine-fcitx5.json'),
        path.join(appDir, 'usr/share/openburnbar/text-expansion/text-expansion-engine-fcitx5.json')
      );
    }
    fs.mkdirSync(path.join(appDir, 'usr/share/openburnbar'), { recursive: true });
    fs.copyFileSync(
      path.join(payload, 'cloud-auth.json'),
      path.join(appDir, 'usr/share/openburnbar/cloud-auth.json')
    );
    fs.chmodSync(path.join(appDir, 'usr/share/openburnbar/cloud-auth.json'), 0o644);
    if (peerAttestation) {
      const peerManifestFile = path.join(appDir, `usr/share/openburnbar/${linuxAppImagePeerManifestName}`);
      const peerSignatureFile = path.join(appDir, `usr/share/openburnbar/${linuxAppImagePeerSignatureName}`);
      fs.writeFileSync(peerManifestFile, peerAttestation.manifestBytes, { mode: 0o644, flag: 'wx' });
      fs.writeFileSync(peerSignatureFile, peerAttestation.signature, { mode: 0o644, flag: 'wx' });
      verifyLinuxAppImagePeerManifest({
        manifestBytes: peerAttestation.manifestBytes,
        signature: peerAttestation.signature,
        executable: path.join(appDir, linuxAppImagePeerExecutableRelativePath),
        publicKeyPem: fs.readFileSync(path.join(repoRoot, 'packaging/linux/openburnbar-linux-ed25519.pub.pem'))
      });
    }
    assertEmbeddedPayload(appDir, { requirePeerManifest: peerAttestation !== null });

    run('mksquashfs', [appDir, squash, '-noappend', '-root-owned', '-comp', 'zstd', '-no-xattrs'], {
      cwd: work,
      env: appImageEnv
    });

    fs.rmSync(candidate, { force: true });
    fs.closeSync(fs.openSync(candidate, 'w'));
    copyFileRange(image, candidate, offset);
    copyFileRange(squash, candidate);
    fs.chmodSync(candidate, 0o755);

    const candidateOffset = findAppImageFilesystemOffset(candidate);
    if (candidateOffset !== offset) {
      throw new Error(`AppImage runtime offset changed from ${offset} to ${candidateOffset}`);
    }
    const verifiedRoot = path.join(verify, 'squashfs-root');
    run('unsquashfs', [
      '-quiet',
      '-no-progress',
      '-dest',
      verifiedRoot,
      '-offset',
      String(candidateOffset),
      candidate
    ], { cwd: verify, env: appImageEnv });
    assertEmbeddedPayload(verifiedRoot, { requirePeerManifest: peerAttestation !== null });
    run(path.join(verifiedRoot, 'usr/libexec/openburnbar-daemon-launch'), ['--help'], {
      cwd: verify,
      env: { ...appImageEnv, APPDIR: verifiedRoot }
    });
    if (runtimeProbe === 'appimage') {
      run(candidate, ['--appimage-extract-and-run', '--version'], { cwd: verify, env: appImageEnv });
    } else {
      run(path.join(verifiedRoot, 'AppRun'), ['--version'], {
        cwd: verify,
        env: { ...appImageEnv, APPDIR: verifiedRoot }
      });
    }

    fs.renameSync(candidate, image);
    return {
      appImage: image,
      size: fs.statSync(image).size,
      filesystemOffset: offset,
      peerManifestSigned: peerAttestation !== null
    };
  } finally {
    fs.rmSync(candidate, { force: true });
    fs.rmSync(work, { recursive: true, force: true });
    fs.rmSync(verify, { recursive: true, force: true });
  }
}

function parseOption(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : null;
}

function main() {
  const discovered = discoverBundleArtifacts().filter((artifact) => artifact.type === 'appimage');
  const appImage = parseOption('--appimage') ?? (discovered.length === 1 ? discovered[0].file : null);
  if (!appImage) throw new Error(`expected exactly one base AppImage, found ${discovered.length}`);
  const payloadRoot = parseOption('--payload')
    ?? path.join(repoRoot, 'apps/linux-desktop/src-tauri/target/openburnbar-package-payload');
  const manifestFile = parseOption('--peer-manifest');
  const signatureFile = parseOption('--peer-signature');
  const result = embedLinuxAppImagePayload({
    appImage,
    payloadRoot,
    peerManifestBytes: manifestFile ? fs.readFileSync(path.resolve(manifestFile)) : null,
    peerSignature: signatureFile ? fs.readFileSync(path.resolve(signatureFile)) : null
  });
  console.log(JSON.stringify({ ...result, appImage: relative(result.appImage) }, null, 2));
}

const invokedAs = process.argv[1] ? path.resolve(process.argv[1]) : '';
if (invokedAs === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    console.error(`embed-linux-appimage-payload: ${error.message}`);
    process.exit(1);
  }
}
