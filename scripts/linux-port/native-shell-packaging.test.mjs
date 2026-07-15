import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8');

test('DEB and RPM bundles install the canonical XDG autostart entry', () => {
  const config = JSON.parse(read('apps/linux-desktop/src-tauri/tauri.conf.json'));
  for (const format of ['deb', 'rpm']) {
    const files = config.bundle?.linux?.[format]?.files;
    assert.ok(files, `${format} bundle file map is required`);
    assert.equal(
      files['/etc/xdg/autostart/openburnbar.desktop'],
      '../../../packaging/linux/autostart/openburnbar.desktop',
      `${format} bundle must install the canonical autostart source`
    );
  }
});

test('Arch package installs the same autostart entry with a pinned source slot', () => {
  const pkgbuild = read('packaging/linux/aur/PKGBUILD.in');
  assert.match(
    pkgbuild,
    /"openburnbar-autostart\.desktop::https:\/\/raw\.githubusercontent\.com\/Imagine-That-Ai\/BurnBar\/linux-v\$\{pkgver\}\/packaging\/linux\/autostart\/openburnbar\.desktop"/u
  );
  assert.match(pkgbuild, /"REPLACE_WITH_AUTOSTART_DESKTOP_SHA256"/u);
  assert.match(
    pkgbuild,
    /install -Dm644 "\$\{srcdir\}\/openburnbar-autostart\.desktop" "\$\{pkgdir\}\/etc\/xdg\/autostart\/openburnbar\.desktop"/u
  );
});

test('autostart entry launches the shell in tray-first background mode', () => {
  const desktop = read('packaging/linux/autostart/openburnbar.desktop');
  assert.match(desktop, /^\[Desktop Entry\]$/mu);
  assert.match(desktop, /^Type=Application$/mu);
  assert.match(desktop, /^Exec=openburnbar-linux-desktop --background$/mu);
  assert.match(desktop, /^X-GNOME-Autostart-enabled=true$/mu);
  assert.match(desktop, /^X-KDE-autostart-after=panel$/mu);
});

test('legacy package rebuild keeps XDG autostart alongside desktop files', () => {
  const rebuild = read('scripts/linux-port/rebuild-linux-packages-with-daemon.mjs');
  assert.match(rebuild, /packaging\/linux\/autostart\/openburnbar\.desktop/u);
  assert.match(rebuild, /etc\/xdg\/autostart/u);
});
