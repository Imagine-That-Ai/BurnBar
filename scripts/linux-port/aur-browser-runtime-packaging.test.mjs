import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const pkgbuildPath = path.join(repoRoot, 'packaging/linux/aur/PKGBUILD.in');
const pkgbuildRelativePath = 'packaging/linux/aur/PKGBUILD.in';
const canonicalInputs = new Map([
  [
    'openburnbar-playwright-bridge.js',
    'OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js'
  ],
  [
    'openburnbar-browser-runtime-probe',
    'packaging/linux/openburnbar-browser-runtime-probe'
  ],
  [
    'browser-runtime-requirements.json',
    'packaging/linux/browser-runtime-requirements.json'
  ]
]);

function evaluatePkgbuild() {
  const result = spawnSync('bash', ['-c', [
    'set -euo pipefail',
    'CARCH=x86_64',
    'source "$1"',
    'printf "DEPEND=%s\\n" "${depends[@]}"',
    'printf "SOURCE=%s\\n" "${source[@]}" "${source_x86_64[@]}"',
    'printf "SUM=%s\\n" "${sha256sums[@]}" "${sha256sums_x86_64[@]}"'
  ].join('\n'), 'bash', pkgbuildRelativePath], { cwd: repoRoot, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  const values = { DEPEND: [], SOURCE: [], SUM: [] };
  for (const line of result.stdout.trim().split('\n')) {
    const separator = line.indexOf('=');
    values[line.slice(0, separator)].push(line.slice(separator + 1));
  }
  return values;
}

test('AUR recipe pins every Browser Computer Use package input to the release tag', () => {
  const { DEPEND: dependencies, SOURCE: sources, SUM: sums } = evaluatePkgbuild();

  assert.ok(dependencies.includes('nodejs'));
  assert.ok(dependencies.includes('npm'));
  assert.equal(sources.length, sums.length, 'every AUR source must have a checksum slot');

  for (const [alias, sourcePath] of canonicalInputs) {
    assert.ok(sources.includes(
      `${alias}::https://raw.githubusercontent.com/Imagine-That-Ai/BurnBar/linux-vREPLACE_WITH_RELEASE_VERSION/${sourcePath}`
    ));
  }
  assert.ok(sums.includes('REPLACE_WITH_PLAYWRIGHT_BRIDGE_SHA256'));
  assert.ok(sums.includes('REPLACE_WITH_BROWSER_RUNTIME_PROBE_SHA256'));
  assert.ok(sums.includes('REPLACE_WITH_BROWSER_RUNTIME_REQUIREMENTS_SHA256'));
});

test('AUR package staging installs canonical Browser Computer Use resources with fixed modes', () => {
  const root = fs.mkdtempSync(path.join(repoRoot, '.tmp-openburnbar-aur-package-'));
  const srcdir = path.join(root, 'src');
  const pkgdir = path.join(root, 'pkg');
  fs.mkdirSync(srcdir, { recursive: true });

  const localAssets = [
    'openburnbar.desktop',
    'openburnbar-safe-mode.desktop',
    'openburnbar-daemon.service',
    'openburnbar-daemon-launch',
    'openburnbar-linux-desktop'
  ];
  for (const asset of localAssets) {
    fs.copyFileSync(path.join(repoRoot, 'packaging/linux/aur', asset), path.join(srcdir, asset));
  }
  const appImage = path.join(srcdir, 'OpenBurnBar_REPLACE_WITH_RELEASE_VERSION_amd64.AppImage');
  fs.writeFileSync(appImage, [
    '#!/bin/bash',
    'set -euo pipefail',
    'test "$1" = --appimage-extract',
    'test "$#" = 1',
    'mkdir -p squashfs-root/usr/bin',
    'printf "#!/bin/bash\\nexec \\\"\\${APPDIR}/AppRun\\\" \\\"\\$@\\\"\\n" >squashfs-root/usr/bin/openburnbar-linux-desktop',
    'chmod 755 squashfs-root/usr/bin/openburnbar-linux-desktop',
    'printf "#!/bin/bash\\nexit 0\\n" >squashfs-root/usr/bin/openburnbar-cli',
    'chmod 755 squashfs-root/usr/bin/openburnbar-cli',
    'printf "#!/bin/bash\\nprintf OpenBurnBar\\ 0.1.0\\n" >squashfs-root/AppRun.wrapped',
    'chmod 777 squashfs-root/AppRun.wrapped',
    'ln -s AppRun.wrapped squashfs-root/AppRun',
    'mkdir -p squashfs-root/usr/lib/openburnbar/native',
    'mkdir -p squashfs-root/usr/lib/openburnbar/swift/linux',
    'mkdir -p squashfs-root/usr/share/openburnbar',
    'printf iroh >squashfs-root/usr/lib/openburnbar/native/libopenburnbar_iroh.so',
    'printf sqlcipher >squashfs-root/usr/lib/openburnbar/native/libsqlcipher.so.0',
    'printf swift >squashfs-root/usr/lib/openburnbar/swift/linux/libswiftCore.so',
    'printf peer >squashfs-root/usr/share/openburnbar/appimage-peer-manifest.json',
    'printf sig >squashfs-root/usr/share/openburnbar/appimage-peer-manifest.ed25519.sig'
  ].join('\n'));
  fs.chmodSync(appImage, 0o755);
  fs.writeFileSync(path.join(srcdir, 'openburnbar-daemon-REPLACE_WITH_RELEASE_VERSION-x86_64'), 'daemon\n');
  fs.copyFileSync(
    path.join(repoRoot, 'packaging/linux/com.openburnbar.computer-use.policy'),
    path.join(srcdir, 'com.openburnbar.computer-use.policy')
  );
  fs.copyFileSync(
    path.join(repoRoot, 'apps/linux-desktop/src-tauri/icons/icon.png'),
    path.join(srcdir, 'openburnbar-icon.png')
  );
  for (const [alias, sourcePath] of canonicalInputs) {
    fs.copyFileSync(path.join(repoRoot, sourcePath), path.join(srcdir, alias));
  }
  fs.writeFileSync(path.join(srcdir, 'installed-manifest.json'), '{}\n');
  fs.writeFileSync(path.join(srcdir, 'installed-manifest.ed25519'), Buffer.alloc(64));
  fs.copyFileSync(
    path.join(repoRoot, 'packaging/linux/openburnbar-linux-ed25519.pub.pem'),
    path.join(srcdir, 'release-ed25519.pub.pem')
  );

  try {
    const result = spawnSync('bash', ['-c', [
      'set -euo pipefail',
      'CARCH=x86_64',
      'source "$1"',
      'srcdir="$2"',
      'pkgdir="$3"',
      'install() {',
      '  if [[ "$1" == -d ]]; then mkdir -p "$2"; return; fi',
      '  local mode="${1#-Dm}" input="$2" output="$3"',
      '  mkdir -p "$(dirname "${output}")"',
      '  cp "${input}" "${output}"',
      '  chmod "${mode}" "${output}"',
      '}',
      'package'
    ].join('\n'), 'bash', pkgbuildRelativePath, srcdir, pkgdir], { cwd: repoRoot, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);

    const installed = new Map([
      ['openburnbar-playwright-bridge.js', ['usr/lib/openburnbar/playwright/openburnbar-playwright-bridge.js', 0o644]],
      ['openburnbar-browser-runtime-probe', ['usr/lib/openburnbar/playwright/openburnbar-browser-runtime-probe', 0o755]],
      ['browser-runtime-requirements.json', ['usr/lib/openburnbar/playwright/browser-runtime-requirements.json', 0o644]]
      ,['installed-manifest.json', ['usr/share/openburnbar/attestation/installed-manifest.json', 0o644]]
      ,['installed-manifest.ed25519', ['usr/share/openburnbar/attestation/installed-manifest.json.sig', 0o644]]
      ,['release-ed25519.pub.pem', ['usr/share/openburnbar/attestation/release-ed25519.pub.pem', 0o644]]
      ,['openburnbar-linux-desktop', ['usr/bin/openburnbar-linux-desktop', 0o755]]
      ,['openburnbar-icon.png', ['usr/share/icons/hicolor/256x256/apps/dev.openburnbar.OpenBurnBar.png', 0o644]]
    ]);
    for (const [alias, [relativePath, mode]] of installed) {
      const output = path.join(pkgdir, relativePath);
      assert.deepEqual(fs.readFileSync(output), fs.readFileSync(path.join(srcdir, alias)));
      assert.equal(fs.statSync(output).mode & 0o777, mode);
    }
    const iroh = path.join(pkgdir, 'usr/lib/openburnbar/native/libopenburnbar_iroh.so');
    assert.equal(fs.readFileSync(iroh, 'utf8'), 'iroh');
    assert.equal(fs.statSync(iroh).mode & 0o777, 0o644);
    const appRun = path.join(pkgdir, 'usr/lib/openburnbar/appdir/AppRun');
    assert.equal(fs.statSync(appRun).mode & 0o777, 0o755);
    assert.equal(fs.lstatSync(appRun).isSymbolicLink(), true);
    const appRunWrapped = path.join(pkgdir, 'usr/lib/openburnbar/appdir/AppRun.wrapped');
    assert.equal(fs.statSync(appRunWrapped).mode & 0o777, 0o755);
    assert.match(fs.readFileSync(path.join(pkgdir, 'usr/bin/openburnbar-linux-desktop'), 'utf8'),
      /exec "\$\{APPDIR\}\/AppRun" "\$@"/u);
    assert.equal(
      fs.statSync(path.join(pkgdir, 'usr/bin/openburnbar-cli')).mode & 0o777,
      0o755
    );
    assert.equal(
      fs.existsSync(path.join(pkgdir, 'usr/lib/openburnbar/appdir/usr/share/openburnbar/appimage-peer-manifest.json')),
      false
    );
    assert.equal(
      fs.existsSync(path.join(pkgdir, 'usr/lib/openburnbar/appdir/usr/share/openburnbar/appimage-peer-manifest.ed25519.sig')),
      false
    );

    // A failing AppImage must expose the runtime's stderr instead of leaving
    // makepkg with only its generic "package()" message. This reproduces the
    // exact failure shape seen in the release candidate.
    fs.writeFileSync(appImage, [
      '#!/bin/bash',
      'printf "simulated AppImage extraction failure\\n" >&2',
      'exit 37'
    ].join('\n'));
    const failed = spawnSync('bash', ['-c', [
      'set -euo pipefail',
      'CARCH=x86_64',
      'source "$1"',
      'srcdir="$2"',
      'pkgdir="$3"',
      'install() {',
      '  if [[ "$1" == -d ]]; then mkdir -p "$2"; return; fi',
      '  local mode="${1#-Dm}" input="$2" output="$3"',
      '  mkdir -p "$(dirname "${output}")"',
      '  cp "${input}" "${output}"',
      '  chmod "${mode}" "${output}"',
      '}',
      'package'
    ].join('\n'), 'bash', pkgbuildRelativePath, srcdir, path.join(root, 'failed-pkg')], {
      cwd: repoRoot,
      encoding: 'utf8'
    });
    assert.notEqual(failed.status, 0);
    assert.match(`${failed.stdout}${failed.stderr}`, /AppImage extraction failed/u);
    assert.match(`${failed.stdout}${failed.stderr}`, /simulated AppImage extraction failure/u);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('AUR PKGBUILD remains valid Bash and does not bypass source verification', () => {
  const syntax = spawnSync('bash', ['-n', pkgbuildPath], { encoding: 'utf8' });
  assert.equal(syntax.status, 0, syntax.stderr);

  const pkgbuild = fs.readFileSync(pkgbuildPath, 'utf8');
  assert.doesNotMatch(pkgbuild, /SKIP/);
  assert.doesNotMatch(pkgbuild, /noextract/);
  assert.match(
    pkgbuild,
    /--appimage-extract >"\$\{extraction_log\}" 2>&1/u
  );
  assert.match(pkgbuild, /Arch package\(\) failed .*BASH_COMMAND/u);
  assert.match(pkgbuild, /AppImage extraction failed/u);
  assert.match(pkgbuild, /extracted AppImage is missing required path/u);
  assert.match(pkgbuild, /appimage-peer-manifest\.json/u);
  assert.match(pkgbuild, /appimage-peer-manifest\.ed25519\.sig/u);
  assert.doesNotMatch(pkgbuild, /install -Dm755 "\$\{appimage\}" "\$\{pkgdir\}\/usr\/bin\/openburnbar-linux-desktop"/u);
  assert.match(pkgbuild, /usr\/lib\/openburnbar\/appdir/u);
  assert.match(pkgbuild, /dev\.openburnbar\.OpenBurnBar\.png/u);
  assert.doesNotMatch(pkgbuild, /libopenburnbar_iroh\.so::https?:/u);
});
