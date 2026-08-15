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
    const bundle = config.bundle?.linux?.[format];
    const files = bundle?.files;
    assert.ok(files, `${format} bundle file map is required`);
    assert.equal(
      bundle.desktopTemplate,
      '../../../packaging/linux/tauri-installed.desktop',
      `${format} bundle must pin Tauri's generated launcher to the packaged executable`
    );
    assert.equal(
      files['/etc/xdg/autostart/openburnbar.desktop'],
      '../../../packaging/linux/autostart/openburnbar.desktop',
      `${format} bundle must install the canonical autostart source`
    );
  }
  const appimage = config.bundle?.linux?.appimage;
  assert.ok(appimage, 'AppImage bundle config is required');
  assert.ok(
    !('desktopTemplate' in appimage),
    "Tauri's AppImageConfig rejects desktopTemplate; extract-and-run portability is enforced by embed-linux-appimage-payload.mjs"
  );
});

test('installed desktop launchers cannot be shadowed through PATH', () => {
  const generated = read('packaging/linux/tauri-installed.desktop');
  const standard = read('packaging/linux/openburnbar.desktop');
  const safeMode = read('packaging/linux/openburnbar-safe-mode.desktop');
  const arch = read('packaging/linux/aur/openburnbar.desktop');
  const archSafeMode = read('packaging/linux/aur/openburnbar-safe-mode.desktop');

  assert.match(generated, /^Exec=\/usr\/bin\/\{\{exec\}\}$/mu);
  for (const desktop of [standard, arch]) {
    assert.match(desktop, /^Exec=\/usr\/bin\/openburnbar-linux-desktop %U$/mu);
  }
  for (const desktop of [safeMode, archSafeMode]) {
    assert.match(
      desktop,
      /^Exec=env .* \/usr\/bin\/openburnbar-linux-desktop %U$/mu
    );
  }
});

test('Tauri release packaging enables the embedded frontend protocol', () => {
  const cargo = read('apps/linux-desktop/src-tauri/Cargo.toml');
  assert.match(cargo, /^default = \["custom-protocol"\]$/mu);
  assert.match(cargo, /^custom-protocol = \["tauri\/custom-protocol"\]$/mu);

  const config = JSON.parse(read('apps/linux-desktop/src-tauri/tauri.conf.json'));
  assert.equal(config.build?.frontendDist, '../dist');
  assert.equal(config.build?.beforeBuildCommand, 'npm run build');
});

test('Tauri codegen watches every frontend asset for in-place edits', () => {
  const build = read('apps/linux-desktop/src-tauri/build.rs');
  assert.match(build, /emit_frontend_asset_dependencies\(\)/u);
  assert.match(build, /manifest_dir\.join\("\.\.\/dist"\)/u);
  assert.match(build, /println!\("cargo:rerun-if-changed=\{\}"/u);
  assert.match(build, /fs::read_dir\(path\)/u);
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
  assert.match(desktop, /^Exec=\/usr\/bin\/openburnbar-linux-desktop --background$/mu);
  assert.match(desktop, /^X-GNOME-Autostart-enabled=true$/mu);
  assert.match(desktop, /^X-KDE-autostart-after=panel$/mu);
});

test('legacy package rebuild keeps XDG autostart alongside desktop files', () => {
  const rebuild = read('scripts/linux-port/rebuild-linux-packages-with-daemon.mjs');
  assert.match(rebuild, /packaging\/linux\/autostart\/openburnbar\.desktop/u);
  assert.match(rebuild, /etc\/xdg\/autostart/u);
});
