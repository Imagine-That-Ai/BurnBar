#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { discoverBundleArtifacts, relative, repoRoot } from './lib/linux-release-common.mjs';
import { findAppImageFilesystemOffset } from './lib/appimage-filesystem.mjs';

export const requiredPayloadPaths = [
  'openburnbar-daemon',
  'swift',
  'native/libsqlcipher.so.0',
  'native/libopenburnbar_iroh.so',
  'playwright/openburnbar-playwright-bridge.js',
  'playwright/openburnbar-browser-runtime-probe',
  'playwright/browser-runtime-requirements.json'
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

export function validatePayload(payloadRoot) {
  const root = path.resolve(payloadRoot);
  for (const entry of requiredPayloadPaths) {
    requirePath(path.join(root, entry), `AppImage payload ${entry}`, entry === 'swift' ? 'directory' : 'file');
  }
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

function assertEmbeddedPayload(appDir) {
  const required = [
    'usr/bin/openburnbar-daemon',
    'usr/libexec/openburnbar-daemon-launch',
    'usr/lib/openburnbar/swift',
    'usr/lib/openburnbar/native/libsqlcipher.so.0',
    'usr/lib/openburnbar/native/libopenburnbar_iroh.so',
    'usr/lib/openburnbar/playwright/openburnbar-playwright-bridge.js',
    'usr/lib/openburnbar/playwright/openburnbar-browser-runtime-probe',
    'usr/lib/openburnbar/playwright/browser-runtime-requirements.json'
  ];
  for (const entry of required) requirePath(path.join(appDir, entry), `embedded AppImage path ${entry}`, entry.endsWith('/swift') ? 'directory' : 'file');
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
}

export function embedLinuxAppImagePayload({ appImage, payloadRoot, env = process.env }) {
  const image = path.resolve(appImage);
  const payload = validatePayload(payloadRoot);
  requirePath(image, 'base AppImage', 'file');
  fs.chmodSync(image, 0o755);

  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-appimage-'));
  const verify = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-appimage-verify-'));
  const squash = path.join(work, 'openburnbar.squashfs');
  const candidate = `${image}.payload.tmp`;
  const appImageEnv = { ...env, APPIMAGE_EXTRACT_AND_RUN: '1' };
  const runtimeProbe = env.OPENBURNBAR_APPIMAGE_RUNTIME_PROBE?.trim() || 'appimage';
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

    fs.mkdirSync(path.join(appDir, 'usr/bin'), { recursive: true });
    fs.copyFileSync(path.join(payload, 'openburnbar-daemon'), path.join(appDir, 'usr/bin/openburnbar-daemon'));
    fs.chmodSync(path.join(appDir, 'usr/bin/openburnbar-daemon'), 0o755);
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
    assertEmbeddedPayload(appDir);

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
    assertEmbeddedPayload(verifiedRoot);
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
    return { appImage: image, size: fs.statSync(image).size, filesystemOffset: offset };
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
  const result = embedLinuxAppImagePayload({ appImage, payloadRoot });
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
