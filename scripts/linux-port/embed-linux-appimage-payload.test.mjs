import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  requiredPayloadPaths,
  resolveLinuxAppImagePeerAttestation,
  validatePayload
} from './embed-linux-appimage-payload.mjs';
import {
  findAppImageFilesystemOffset,
  squashfsCandidateOffsets
} from './lib/appimage-filesystem.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

function writeCliFixture(root) {
  const cli = path.join(root, 'openburnbar-cli');
  fs.writeFileSync(cli, 'cli');
  fs.chmodSync(cli, 0o755);
  fs.mkdirSync(path.join(root, 'resource-bundles'));
  fs.mkdirSync(path.join(root, 'resource-bundles', 'OpenBurnBarCore_OpenBurnBarCore.resources'));
  fs.writeFileSync(
    path.join(root, 'resource-bundles', 'OpenBurnBarCore_OpenBurnBarCore.resources', 'catalog.json'),
    '{}\n'
  );
}

test('AppImage payload validator requires daemon, runtimes, and Browser CU resources', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-appimage-payload-'));
  fs.writeFileSync(path.join(root, 'openburnbar-daemon'), 'daemon');
  writeCliFixture(root);
  fs.mkdirSync(path.join(root, 'swift'));
  fs.mkdirSync(path.join(root, 'native'));
  fs.writeFileSync(path.join(root, 'native/libsqlcipher.so.0'), 'sqlcipher');
  fs.writeFileSync(path.join(root, 'native/libopenburnbar_iroh.so'), 'iroh');
  fs.mkdirSync(path.join(root, 'playwright'));
  fs.writeFileSync(path.join(root, 'playwright/openburnbar-playwright-bridge.js'), 'bridge');
  fs.writeFileSync(path.join(root, 'playwright/openburnbar-browser-runtime-probe'), 'probe', { mode: 0o755 });
  fs.writeFileSync(path.join(root, 'playwright/browser-runtime-requirements.json'), '{}');
  fs.writeFileSync(path.join(root, 'cloud-auth.json'), '{"schemaVersion":1,"configured":true}');

  assert.deepEqual(requiredPayloadPaths, [
    'openburnbar-cli',
    'openburnbar-daemon',
    'resource-bundles',
    'swift',
    'native/libsqlcipher.so.0',
    'native/libopenburnbar_iroh.so',
    'playwright/openburnbar-playwright-bridge.js',
    'playwright/openburnbar-browser-runtime-probe',
    'playwright/browser-runtime-requirements.json',
    'cloud-auth.json'
  ]);
  assert.equal(validatePayload(root), root);
  fs.rmSync(root, { recursive: true, force: true });
});

test('release AppImage embedding requires pre-signed bytes and rejects private-key exposure', () => {
  assert.throws(
    () => resolveLinuxAppImagePeerAttestation({
      manifestBytes: null,
      signature: null,
      environment: { OPENBURNBAR_LINUX_RELEASE_BUILD: '1' }
    }),
    /pre-signed AppImage peer manifest/u
  );
  assert.equal(resolveLinuxAppImagePeerAttestation({
    manifestBytes: null,
    signature: null,
    environment: {}
  }), null);
  assert.throws(
    () => resolveLinuxAppImagePeerAttestation({
      manifestBytes: Buffer.from('{}\n'),
      signature: Buffer.alloc(64),
      environment: { OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM: 'private-key' }
    }),
    /must not receive/u
  );
});

test('AppImage launcher routes cloud auth to the mounted package payload', () => {
  const launcher = fs.readFileSync(
    path.join(repoRoot, 'packaging/linux/openburnbar-daemon-launch.sh'),
    'utf8'
  );
  assert.match(
    launcher,
    /OPENBURNBAR_PACKAGED_CLOUD_AUTH_CONFIG_FILE="\$\{APPIMAGE_ROOT\}\/usr\/share\/openburnbar\/cloud-auth\.json"/
  );
  assert.match(
    launcher,
    /OPENBURNBAR_PACKAGED_CLOUD_AUTH_CONFIG_FILE="\/usr\/share\/openburnbar\/cloud-auth\.json"/
  );
  assert.match(launcher, /unset OPENBURNBAR_DAEMON_LINUX_PEER_ROOTS BURNBAR_DAEMON_LINUX_PEER_ROOTS/);
  assert.match(launcher, /unset OPENBURNBAR_DAEMON_LINUX_PEER_SHA256_PINS BURNBAR_DAEMON_LINUX_PEER_SHA256_PINS/);
  assert.doesNotMatch(launcher, /export OPENBURNBAR_DAEMON_LINUX_PEER_ROOTS/);
  assert.equal(
    launcher,
    fs.readFileSync(path.join(repoRoot, 'packaging/linux/aur/openburnbar-daemon-launch'), 'utf8'),
    'AUR launcher must exactly mirror the canonical launcher'
  );
});

test('AppImage payload validator fails closed when a runtime is absent', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-appimage-payload-missing-'));
  fs.writeFileSync(path.join(root, 'openburnbar-daemon'), 'daemon');
  writeCliFixture(root);
  fs.writeFileSync(path.join(root, 'openburnbar-cli'), 'cli');
  fs.mkdirSync(path.join(root, 'swift'));

  assert.throws(() => validatePayload(root), /native\/libsqlcipher\.so\.0/);
  fs.rmSync(root, { recursive: true, force: true });
});

test('AppImage payload validator fails closed when the packaged bridge is absent', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-appimage-bridge-missing-'));
  fs.writeFileSync(path.join(root, 'openburnbar-daemon'), 'daemon');
  writeCliFixture(root);
  fs.writeFileSync(path.join(root, 'openburnbar-cli'), 'cli');
  fs.mkdirSync(path.join(root, 'swift'));
  fs.mkdirSync(path.join(root, 'native'));
  fs.writeFileSync(path.join(root, 'native/libsqlcipher.so.0'), 'sqlcipher');
  fs.writeFileSync(path.join(root, 'native/libopenburnbar_iroh.so'), 'iroh');
  fs.mkdirSync(path.join(root, 'playwright'));
  fs.writeFileSync(path.join(root, 'playwright/openburnbar-browser-runtime-probe'), 'probe', { mode: 0o755 });
  fs.writeFileSync(path.join(root, 'playwright/browser-runtime-requirements.json'), '{}');
  fs.writeFileSync(path.join(root, 'cloud-auth.json'), '{"schemaVersion":1,"configured":true}');

  assert.throws(() => validatePayload(root), /openburnbar-playwright-bridge\.js/);
  fs.rmSync(root, { recursive: true, force: true });
});

test('AppImage payload validator rejects a symlinked bridge', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-appimage-bridge-symlink-'));
  fs.writeFileSync(path.join(root, 'openburnbar-daemon'), 'daemon');
  writeCliFixture(root);
  fs.writeFileSync(path.join(root, 'openburnbar-cli'), 'cli');
  fs.mkdirSync(path.join(root, 'swift'));
  fs.mkdirSync(path.join(root, 'native'));
  fs.writeFileSync(path.join(root, 'native/libsqlcipher.so.0'), 'sqlcipher');
  fs.writeFileSync(path.join(root, 'native/libopenburnbar_iroh.so'), 'iroh');
  fs.mkdirSync(path.join(root, 'playwright'));
  fs.writeFileSync(path.join(root, 'bridge-target'), 'bridge');
  fs.symlinkSync('../bridge-target', path.join(root, 'playwright/openburnbar-playwright-bridge.js'));
  fs.writeFileSync(path.join(root, 'playwright/openburnbar-browser-runtime-probe'), 'probe', { mode: 0o755 });
  fs.writeFileSync(path.join(root, 'playwright/browser-runtime-requirements.json'), '{}');
  fs.writeFileSync(path.join(root, 'cloud-auth.json'), '{"schemaVersion":1,"configured":true}');

  assert.throws(() => validatePayload(root), /not a regular file/);
  fs.rmSync(root, { recursive: true, force: true });
});

test('AppImage payload validator rejects a symlinked iroh runtime', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-appimage-iroh-symlink-'));
  fs.writeFileSync(path.join(root, 'openburnbar-daemon'), 'daemon');
  writeCliFixture(root);
  fs.writeFileSync(path.join(root, 'openburnbar-cli'), 'cli');
  fs.mkdirSync(path.join(root, 'swift'));
  fs.mkdirSync(path.join(root, 'native'));
  fs.writeFileSync(path.join(root, 'native/libsqlcipher.so.0'), 'sqlcipher');
  fs.writeFileSync(path.join(root, 'iroh-target'), 'iroh');
  fs.symlinkSync('../iroh-target', path.join(root, 'native/libopenburnbar_iroh.so'));
  fs.mkdirSync(path.join(root, 'playwright'));
  fs.writeFileSync(path.join(root, 'playwright/openburnbar-playwright-bridge.js'), 'bridge');
  fs.writeFileSync(path.join(root, 'playwright/openburnbar-browser-runtime-probe'), 'probe', { mode: 0o755 });
  fs.writeFileSync(path.join(root, 'playwright/browser-runtime-requirements.json'), '{}');
  fs.writeFileSync(path.join(root, 'cloud-auth.json'), '{"schemaVersion":1,"configured":true}');

  assert.throws(() => validatePayload(root), /iroh native runtime.*not a regular file/);
  fs.rmSync(root, { recursive: true, force: true });
});

test('AppImage filesystem scanner handles chunk boundaries and validates candidates', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-appimage-offset-'));
  const image = path.join(root, 'fixture.AppImage');
  const fixture = Buffer.alloc(32, 0);
  fixture.write('hsqs', 4, 'ascii');
  fixture.write('hsqs', 14, 'ascii');
  fs.writeFileSync(image, fixture);

  assert.deepEqual(squashfsCandidateOffsets(image, { chunkSize: 8 }), [4, 14]);
  assert.equal(
    findAppImageFilesystemOffset(image, (_file, offset) => offset === 14, { chunkSize: 8 }),
    14
  );
  assert.throws(
    () => findAppImageFilesystemOffset(image, () => false, { chunkSize: 8 }),
    /no valid SquashFS filesystem offset/
  );
  fs.rmSync(root, { recursive: true, force: true });
});
