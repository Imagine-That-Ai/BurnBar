import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8');

test('release manifest declares native credential dependencies and Flatpak blocker', () => {
  const manifest = JSON.parse(read('packaging/linux/release-manifest.json'));
  assert.equal(manifest.credentialStorage.requiredCommand, 'secret-tool');
  assert.equal(manifest.credentialStorage.primaryBackend, 'org.freedesktop.secrets');
  assert.ok(manifest.credentialStorage.debian.depends.includes('libsecret-tools'));
  assert.ok(manifest.credentialStorage.rpm.depends.includes('libsecret'));
  assert.ok(manifest.credentialStorage.arch.depends.includes('libsecret'));
  assert.equal(manifest.credentialStorage.flatpak.status, 'unpromoted');
  assert.match(manifest.credentialStorage.flatpak.blocker, /not yet proven/i);
});

test('all package recipes carry the primary credential backend contract', () => {
  const nativePackager = read('scripts/linux-port/lib/native-linux-packager.mjs');
  assert.match(nativePackager, /Depends:[^\n]*libsecret-tools/);
  assert.match(nativePackager, /Requires:[^\n]*libsecret/);
  assert.match(nativePackager, /Requires:[^\n]*webkit2gtk4\.1/);
  assert.match(nativePackager, /Requires:[^\n]*libayatana-appindicator-gtk3/);

  const pkgbuild = read('packaging/linux/aur/PKGBUILD');
  assert.match(pkgbuild, /depends=\([^\n]*"libsecret"/);
  assert.match(pkgbuild, /optdepends=\([^\n]*"kwallet:/);

  const flatpak = read('packaging/linux/flatpak/dev.openburnbar.OpenBurnBar.yml');
  assert.match(flatpak, /--talk-name=org\.freedesktop\.secrets/);
  assert.match(flatpak, /intentionally not[\s\S]*sandboxed Secret Service/);
});

test('runbook documents fail-closed locked keyring and exact secret handling', () => {
  const runbook = read('docs/linux-port/cloud-security-runbook.md');
  assert.match(runbook, /Ambient `PATH` entries and user-writable executables are not trusted/);
  assert.match(runbook, /Leading and trailing spaces are\s+preserved/);
  assert.match(runbook, /locked or failed primary keyring fails closed/i);
  assert.match(runbook, /Flatpak[\s\S]*remains unpromoted/);
});
