import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { validateFcitx5AddonContract } from './validate-fcitx5-addon-source.mjs';

const ROOT = path.resolve(new URL('../..', import.meta.url).pathname);
const FIXTURE_FILES = [
  'packaging/linux/release-manifest.json',
  'packaging/linux/fcitx5-openburnbar-addon.json',
  'packaging/linux/FCITX5_ADDON_CONTRACT.md',
  'packaging/linux/aur/PKGBUILD.in',
  'packaging/linux/fcitx5-addon/CMakeLists.txt',
  'packaging/linux/fcitx5-addon/openburnbar-fcitx5-addon.conf',
  'packaging/linux/fcitx5-addon/openburnbar-fcitx5-im.conf',
  'packaging/linux/fcitx5-addon/src/openburnbar-fcitx5.cpp',
  'packaging/linux/openburnbar-fcitx5-register.sh',
  'packaging/linux/openburnbar-fcitx5-unregister.sh',
  'scripts/linux-port/build-fcitx5-addon.sh',
  'apps/linux-desktop/src-tauri/tauri.conf.json'
];

function fixtureRoot(prefix) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  for (const relativePath of FIXTURE_FILES) {
    const destination = path.join(root, relativePath);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(path.join(ROOT, relativePath), destination);
  }
  return root;
}

test('the packaged native Fcitx5 addon is wired into every package payload', () => {
  assert.deepEqual(validateFcitx5AddonContract({ root: ROOT }), []);
});

test('Fcitx5 contract rejects losing the native addon from a package recipe', () => {
  const root = fixtureRoot('openburnbar-fcitx5-package-');
  try {
    const tauriPath = path.join(root, 'apps/linux-desktop/src-tauri/tauri.conf.json');
    const tauri = JSON.parse(fs.readFileSync(tauriPath, 'utf8'));
    delete tauri.bundle.linux.deb.files['/usr/lib/openburnbar/fcitx5/openburnbar-fcitx5.so'];
    fs.writeFileSync(tauriPath, `${JSON.stringify(tauri, null, 2)}\n`);
    assert.match(
      validateFcitx5AddonContract({ root }).join('\n'),
      /deb must package the native Fcitx5 addon/u
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('Fcitx5 contract rejects shipping the addon without its signed manifest', () => {
  const root = fixtureRoot('openburnbar-fcitx5-manifest-');
  try {
    const tauriPath = path.join(root, 'apps/linux-desktop/src-tauri/tauri.conf.json');
    const tauri = JSON.parse(fs.readFileSync(tauriPath, 'utf8'));
    delete tauri.bundle.linux.rpm.files['/usr/share/openburnbar/text-expansion/text-expansion-engine-fcitx5.json'];
    fs.writeFileSync(tauriPath, `${JSON.stringify(tauri, null, 2)}\n`);
    assert.match(
      validateFcitx5AddonContract({ root }).join('\n'),
      /rpm must package the signed Fcitx5 engine manifest/u
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('Fcitx5 contract rejects an AppImage that claims system registration', () => {
  const root = fixtureRoot('openburnbar-fcitx5-appimage-');
  try {
    const tauriPath = path.join(root, 'apps/linux-desktop/src-tauri/tauri.conf.json');
    const tauri = JSON.parse(fs.readFileSync(tauriPath, 'utf8'));
    tauri.bundle.linux.appimage.files['/usr/lib/openburnbar/fcitx5/openburnbar-fcitx5.so'] =
      'target/openburnbar-package-payload/fcitx5-addon/openburnbar-fcitx5.so';
    fs.writeFileSync(tauriPath, `${JSON.stringify(tauri, null, 2)}\n`);
    assert.match(
      validateFcitx5AddonContract({ root }).join('\n'),
      /appimage must not claim system Fcitx5 addon registration/u
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('Fcitx5 contract rejects source that loses the secure-field denial', () => {
  const root = fixtureRoot('openburnbar-fcitx5-source-');
  try {
    const sourcePath = path.join(root, 'packaging/linux/fcitx5-addon/src/openburnbar-fcitx5.cpp');
    const source = fs.readFileSync(sourcePath, 'utf8')
      .replaceAll('CapabilityFlag::Password', 'CapabilityFlag::Disable');
    fs.writeFileSync(sourcePath, source);
    assert.match(
      validateFcitx5AddonContract({ root }).join('\n'),
      /secure-field denial/u
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('Fcitx5 contract rejects a manifest that demotes runtime support silently', () => {
  const root = fixtureRoot('openburnbar-fcitx5-demote-');
  try {
    const manifestPath = path.join(root, 'packaging/linux/release-manifest.json');
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    manifest.textExpansionRuntime.fcitx5.runtimeSupport = false;
    fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
    assert.match(
      validateFcitx5AddonContract({ root }).join('\n'),
      /declare the packaged native Fcitx5 addon exactly/u
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('Fcitx5 contract keeps IBus supported alongside the addon', () => {
  const root = fixtureRoot('openburnbar-fcitx5-ibus-');
  try {
    const manifestPath = path.join(root, 'packaging/linux/release-manifest.json');
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    manifest.textExpansionRuntime.supportedBackends = ['fcitx5'];
    fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
    assert.match(
      validateFcitx5AddonContract({ root }).join('\n'),
      /keep IBus supported/u
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
