import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8');

test('the package build wrapper injects media-gst once and preserves release args', () => {
  const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-tauri-build-'));
  const fakeTauri = path.join(fixture, 'tauri');
  const capturedArgs = path.join(fixture, 'args.json');
  try {
    fs.writeFileSync(
      fakeTauri,
      '#!/usr/bin/env node\n' +
        "require('node:fs').writeFileSync(process.env.OPENBURNBAR_TEST_TAURI_ARGS, JSON.stringify(process.argv.slice(2)));\n"
    );
    fs.chmodSync(fakeTauri, 0o755);
    const wrapper = path.join(root, 'scripts/linux-port/tauri-build-linux.mjs');
    const env = {
      ...process.env,
      PATH: `${fixture}${path.delimiter}${process.env.PATH ?? ''}`,
      OPENBURNBAR_TEST_TAURI_ARGS: capturedArgs
    };

    const defaultRun = spawnSync(process.execPath, [wrapper, '--bundles', 'deb'], {
      cwd: root,
      env,
      encoding: 'utf8'
    });
    assert.equal(defaultRun.status, 0, defaultRun.stderr);
    assert.deepEqual(JSON.parse(fs.readFileSync(capturedArgs, 'utf8')), [
      'build',
      '--bundles',
      'deb',
      '--features',
      'media-gst'
    ]);

    const explicitRun = spawnSync(
      process.execPath,
      [wrapper, '--no-bundle', '--features', 'media-gst'],
      { cwd: root, env, encoding: 'utf8' }
    );
    assert.equal(explicitRun.status, 0, explicitRun.stderr);
    assert.deepEqual(JSON.parse(fs.readFileSync(capturedArgs, 'utf8')), [
      'build',
      '--no-bundle',
      '--features',
      'media-gst'
    ]);
  } finally {
    fs.rmSync(fixture, { recursive: true, force: true });
  }
});

test('release builds ship the GStreamer Mercury viewer contract', () => {
  const desktopPackage = JSON.parse(read('apps/linux-desktop/package.json'));
  assert.equal(
    desktopPackage.scripts['tauri:build'],
    'node ../../scripts/linux-port/tauri-build-linux.mjs'
  );

  const tauriBuildWrapper = read('scripts/linux-port/tauri-build-linux.mjs');
  assert.match(tauriBuildWrapper, /forwardedArgs\.includes\('--features'\)/u);
  assert.match(tauriBuildWrapper, /forwardedArgs\.push\('--features', 'media-gst'\)/u);
  assert.match(tauriBuildWrapper, /spawnSync\('tauri', \['build', \.\.\.forwardedArgs\]/u);

  const releaseBuilder = read('scripts/linux-port/build-linux-release.mjs');
  assert.match(releaseBuilder, /tauri:build.*--no-bundle.*--features.*media-gst/s);
  assert.match(releaseBuilder, /crates\/openburnbar-media\/Cargo\.toml/);
  assert.match(releaseBuilder, /OPENBURNBAR_MEDIA_CAPTURE_LIBRARY_DIR/);
  assert.match(releaseBuilder, /OPENBURNBAR_MEDIA_CAPTURE_RELEASE/);
  assert.match(releaseBuilder, /libopenburnbar_media\.so/);
  assert.match(releaseBuilder, /OPENBURNBAR_SQLCIPHER_LIB_DIR/);
  assert.match(releaseBuilder, /OPENBURNBAR_SQLCIPHER_PREFIX/);

  const daemonManifest = read('OpenBurnBarDaemon/Package.swift');
  assert.match(daemonManifest, /OPENBURNBAR_SQLCIPHER_LIB_DIR/);
  assert.match(daemonManifest, /libsqlcipher\.so\.0/);

  const dockerfile = read('tools/linux-toolchain/Dockerfile');
  for (const packageName of [
    'gstreamer1.0-plugins-base',
    'gstreamer1.0-plugins-good',
    'gstreamer1.0-pipewire',
    'libgstreamer1.0-dev'
  ]) {
    assert.match(dockerfile, new RegExp(`\\b${packageName.replaceAll('.', '\\.')}(?:\\s|\\\\$)`));
  }

  const smoke = read('tools/linux-toolchain/smoke.sh');
  for (const factory of ['vp9dec', 'autovideosink', 'pipewiresrc', 'pipewiresink']) {
    assert.match(smoke, new RegExp(`gst-inspect-1\\.0\\s+${factory}`));
  }

  const tauri = JSON.parse(read('apps/linux-desktop/src-tauri/tauri.conf.json'));
  assert.ok(tauri.bundle.linux.deb.depends.includes('gstreamer1.0-pipewire'));
  assert.ok(tauri.bundle.linux.rpm.depends.includes('gstreamer1-plugin-pipewire'));

  const pkgbuild = read('packaging/linux/aur/PKGBUILD.in');
  for (const dependency of ['gstreamer', 'gst-plugins-base', 'gst-plugins-good', 'gst-plugin-pipewire']) {
    assert.match(pkgbuild, new RegExp(`"${dependency}"`));
  }

  const manifest = JSON.parse(read('packaging/linux/release-manifest.json'));
  assert.equal(manifest.mediaRuntime.viewerFeature, 'media-gst');
  for (const dependency of manifest.mediaRuntime.debianDepends) {
    assert.ok(tauri.bundle.linux.deb.depends.includes(dependency));
  }
  for (const dependency of manifest.mediaRuntime.rpmDepends) {
    assert.ok(tauri.bundle.linux.rpm.depends.includes(dependency));
  }
  assert.deepEqual(manifest.mediaRuntime.requiredFactories, [
    'vp9dec',
    'autovideosink',
    'pipewiresrc',
    'pipewiresink'
  ]);
  assert.equal(
    manifest.mediaRuntime.promotionStatus,
    'blocked-until-two-device-screen-share-and-installed-factory-receipts-pass'
  );
});
