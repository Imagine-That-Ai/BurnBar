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

test('Fcitx5 package capability is explicit, source-only, and wired into every package payload', () => {
  assert.deepEqual(validateFcitx5AddonContract({ root: ROOT }), []);
});

test('Fcitx5 contract rejects accidental runtime promotion', () => {
  const root = fixtureRoot('openburnbar-fcitx5-contract-');
  try {
    const manifestPath = path.join(root, 'packaging/linux/release-manifest.json');
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    manifest.textExpansionRuntime.fcitx5.runtimeSupport = true;
    fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
    assert.match(
      validateFcitx5AddonContract({ root }).join('\n'),
      /keep Fcitx5 source-only and unavailable/u
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('Fcitx5 contract rejects a package recipe that omits the diagnostic artifact', () => {
  const root = fixtureRoot('openburnbar-fcitx5-package-');
  try {
    const pkgbuildPath = path.join(root, 'packaging/linux/aur/PKGBUILD.in');
    const pkgbuild = fs.readFileSync(pkgbuildPath, 'utf8')
      .replaceAll('usr/share/openburnbar/text-expansion/fcitx5-openburnbar-addon.json', '');
    fs.writeFileSync(pkgbuildPath, pkgbuild);
    assert.match(
      validateFcitx5AddonContract({ root }).join('\n'),
      /Arch recipe must preserve Fcitx5 source-only marker/u
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
