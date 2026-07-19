import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8');

test('release builds ship the GStreamer Mercury viewer contract', () => {
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
