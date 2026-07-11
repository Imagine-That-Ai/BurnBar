import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const pkgbuildPath = path.join(repoRoot, 'packaging/linux/aur/PKGBUILD');
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
    'printf "SOURCE=%s\\n" "${source[@]}"',
    'printf "SUM=%s\\n" "${sha256sums[@]}"'
  ].join('\n'), 'bash', pkgbuildPath], { encoding: 'utf8' });
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
      `${alias}::https://raw.githubusercontent.com/Imagine-That-Ai/BurnBar/v0.1.0/${sourcePath}`
    ));
  }
  assert.ok(sums.includes('REPLACE_WITH_PLAYWRIGHT_BRIDGE_SHA256'));
  assert.ok(sums.includes('REPLACE_WITH_BROWSER_RUNTIME_PROBE_SHA256'));
  assert.ok(sums.includes('REPLACE_WITH_BROWSER_RUNTIME_REQUIREMENTS_SHA256'));
});

test('AUR package staging installs canonical Browser Computer Use resources with fixed modes', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-aur-package-'));
  const srcdir = path.join(root, 'src');
  const pkgdir = path.join(root, 'pkg');
  fs.mkdirSync(srcdir, { recursive: true });

  const localAssets = [
    'openburnbar.desktop',
    'openburnbar-autostart.desktop',
    'openburnbar-safe-mode.desktop',
    'openburnbar-daemon.service',
    'openburnbar-daemon-launch'
  ];
  for (const asset of localAssets) {
    fs.copyFileSync(path.join(repoRoot, 'packaging/linux/aur', asset), path.join(srcdir, asset));
  }
  fs.writeFileSync(path.join(srcdir, 'OpenBurnBar-0.1.0.AppImage'), 'appimage\n');
  fs.writeFileSync(path.join(srcdir, 'openburnbar-daemon-0.1.0-x86_64'), 'daemon\n');
  fs.copyFileSync(
    path.join(repoRoot, 'packaging/linux/com.openburnbar.computer-use.policy'),
    path.join(srcdir, 'com.openburnbar.computer-use.policy')
  );
  for (const [alias, sourcePath] of canonicalInputs) {
    fs.copyFileSync(path.join(repoRoot, sourcePath), path.join(srcdir, alias));
  }

  try {
    const result = spawnSync('bash', ['-c', [
      'set -euo pipefail',
      'CARCH=x86_64',
      'source "$1"',
      'srcdir="$2"',
      'pkgdir="$3"',
      'install() {',
      '  local mode="${1#-Dm}" input="$2" output="$3"',
      '  mkdir -p "$(dirname "${output}")"',
      '  cp "${input}" "${output}"',
      '  chmod "${mode}" "${output}"',
      '}',
      'package'
    ].join('\n'), 'bash', pkgbuildPath, srcdir, pkgdir], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);

    const installed = new Map([
      ['openburnbar-playwright-bridge.js', ['usr/lib/openburnbar/playwright/openburnbar-playwright-bridge.js', 0o644]],
      ['openburnbar-browser-runtime-probe', ['usr/lib/openburnbar/playwright/openburnbar-browser-runtime-probe', 0o755]],
      ['browser-runtime-requirements.json', ['usr/lib/openburnbar/playwright/browser-runtime-requirements.json', 0o644]]
    ]);
    for (const [alias, [relativePath, mode]] of installed) {
      const output = path.join(pkgdir, relativePath);
      assert.deepEqual(fs.readFileSync(output), fs.readFileSync(path.join(srcdir, alias)));
      assert.equal(fs.statSync(output).mode & 0o777, mode);
    }
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
});
