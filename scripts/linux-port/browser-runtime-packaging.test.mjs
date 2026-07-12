import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const bridge = path.join(
  repoRoot,
  'OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js'
);

function fakePlaywright(root, { version = '1.49.1', executable = true } = {}) {
  const moduleRoot = path.join(root, 'node_modules/playwright');
  const chromium = path.join(root, 'chromium');
  fs.mkdirSync(moduleRoot, { recursive: true });
  fs.writeFileSync(path.join(moduleRoot, 'package.json'), `${JSON.stringify({
    name: 'playwright',
    version,
    main: 'index.js'
  })}\n`);
  if (executable) fs.writeFileSync(chromium, '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  fs.writeFileSync(path.join(moduleRoot, 'chromium-path.json'), `${JSON.stringify({ executablePath: chromium })}\n`);
  fs.writeFileSync(path.join(moduleRoot, 'index.js'), [
    "const fs = require('fs');",
    "const path = require('path');",
    "const { executablePath } = JSON.parse(fs.readFileSync(path.join(__dirname, 'chromium-path.json'), 'utf8'));",
    'exports.chromium = {',
    '  executablePath: () => executablePath,',
    '  launch: async () => ({ close: async () => {} })',
    '};',
    ''
  ].join('\n'));
  return path.join(root, 'node_modules');
}

function runProbe(nodePath) {
  return spawnSync(process.execPath, [bridge, '--probe-runtime'], {
    encoding: 'utf8',
    env: { ...process.env, NODE_PATH: nodePath }
  });
}

function runLiveBridge(nodePath) {
  return spawnSync(process.execPath, [bridge, '--headless'], {
    encoding: 'utf8',
    env: { ...process.env, NODE_PATH: nodePath },
    timeout: 2_000
  });
}

function runTrustCheck(root, expectedUid) {
  const source = [
    `const bridge = require(${JSON.stringify(bridge)});`,
    `bridge.assertTrustedPackagedTree(${JSON.stringify(root)}, ${expectedUid});`
  ].join('\n');
  return spawnSync(process.execPath, ['-e', source], { encoding: 'utf8' });
}

test('bridge readiness probe verifies the exact Playwright pin and Chromium launch', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-browser-probe-'));
  try {
    const result = runProbe(fakePlaywright(root));
    assert.equal(result.status, 0, result.stderr);
    const report = JSON.parse(result.stdout);
    assert.equal(report.ready, true);
    assert.equal(report.playwrightVersion, '1.49.1');
    assert.equal(report.chromiumLaunch, true);
    assert.equal(report.dynamicInstallPerformed, false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('bridge readiness probe fails closed on version drift or a missing browser', () => {
  for (const fixture of [
    { version: '1.49.2', executable: true, reason: /playwright_version_mismatch/ },
    { version: '1.49.1', executable: false, reason: /ENOENT/ }
  ]) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-browser-probe-invalid-'));
    try {
      const result = runProbe(fakePlaywright(root, fixture));
      assert.notEqual(result.status, 0);
      const report = JSON.parse(result.stdout);
      assert.equal(report.ready, false);
      assert.match(report.reason, fixture.reason);
      assert.equal(report.dynamicInstallPerformed, false);
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  }
});

test('live bridge independently rejects Playwright version drift', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-browser-live-version-'));
  try {
    const result = runLiveBridge(fakePlaywright(root, { version: '1.49.2' }));
    assert.equal(result.status, 2, result.stderr);
    assert.match(result.stderr, /playwright_version_mismatch:1\.49\.2/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('packaged runtime trust rejects writable entries and escaping symlinks', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-browser-trust-'));
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-browser-outside-'));
  const uid = process.getuid?.() ?? 0;
  try {
    const safeFile = path.join(root, 'safe.js');
    fs.writeFileSync(safeFile, 'safe\n', { mode: 0o644 });
    assert.equal(runTrustCheck(root, uid).status, 0);

    fs.chmodSync(safeFile, 0o666);
    const writable = runTrustCheck(root, uid);
    assert.notEqual(writable.status, 0);
    assert.match(writable.stderr, /packaged_runtime_writable/);

    fs.chmodSync(safeFile, 0o644);
    fs.writeFileSync(path.join(outside, 'outside.js'), 'outside\n', { mode: 0o644 });
    fs.symlinkSync(path.join(outside, 'outside.js'), path.join(root, 'escape.js'));
    const escaped = runTrustCheck(root, uid);
    assert.notEqual(escaped.status, 0);
    assert.match(escaped.stderr, /packaged_runtime_path_escape/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
    fs.rmSync(outside, { recursive: true, force: true });
  }
});

test('release metadata and launcher bind the immutable bridge without claiming bundled browsers', () => {
  const manifest = JSON.parse(fs.readFileSync(
    path.join(repoRoot, 'packaging/linux/release-manifest.json'),
    'utf8'
  ));
  const requirements = JSON.parse(fs.readFileSync(
    path.join(repoRoot, 'packaging/linux/browser-runtime-requirements.json'),
    'utf8'
  ));
  const launcher = fs.readFileSync(
    path.join(repoRoot, 'packaging/linux/openburnbar-daemon-launch.sh'),
    'utf8'
  );
  const daemonService = fs.readFileSync(
    path.join(repoRoot, 'packaging/linux/openburnbar-daemon.service'),
    'utf8'
  );
  const lifecycle = fs.readFileSync(
    path.join(
      repoRoot,
      'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/OpenBurnBarPlaywrightLifecycle.swift'
    ),
    'utf8'
  );
  const service = fs.readFileSync(
    path.join(
      repoRoot,
      'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/ComputerUseService.swift'
    ),
    'utf8'
  );
  const probeScript = path.join(repoRoot, 'packaging/linux/openburnbar-browser-runtime-probe');

  assert.equal(manifest.installPaths.playwrightBridge, requirements.bridge.installedPath);
  assert.equal(manifest.browserComputerUseRuntime.playwrightBundled, false);
  assert.equal(manifest.browserComputerUseRuntime.chromiumBundled, false);
  assert.equal(manifest.browserComputerUseRuntime.dynamicInstallAtActionTime, false);
  assert.equal(requirements.playwright.requiredVersion, '1.49.1');
  assert.equal(requirements.playwright.trustedModuleRoot, '/usr/lib/node_modules/playwright');
  assert.equal(requirements.playwright.trustedCoreModuleRoot, '/usr/lib/node_modules/playwright-core');
  assert.equal(requirements.chromium.trustedBrowserRoot, '/usr/lib/openburnbar/playwright-browsers');
  assert.equal(requirements.dynamicInstallAtActionTime, false);
  assert.match(launcher, /export OPENBURNBAR_PACKAGED_PLAYWRIGHT_BRIDGE=/);
  assert.match(launcher, /APPIMAGE_ROOT.*usr\/lib\/openburnbar\/playwright/s);
  assert.match(launcher, /export OPENBURNBAR_PACKAGED_CLOUD_AUTH_CONFIG_FILE=/);
  assert.match(launcher, /APPIMAGE_ROOT.*usr\/share\/openburnbar\/cloud-auth\.json/s);
  assert.match(launcher, /unset NODE_OPTIONS/);
  assert.match(launcher, /^#!\/bin\/bash/);
  assert.match(launcher, /export PATH=\/usr\/sbin:\/usr\/bin:\/sbin:\/bin/);
  assert.doesNotMatch(launcher, /library_paths\+=\("\$\{LD_LIBRARY_PATH/);
  assert.doesNotMatch(launcher, /command -v openburnbar-daemon/);
  assert.match(launcher, /export NODE_PATH="\/usr\/lib\/node_modules"/);
  assert.match(launcher, /export PLAYWRIGHT_BROWSERS_PATH="\/usr\/lib\/openburnbar\/playwright-browsers"/);
  assert.match(lifecycle, /OPENBURNBAR_PACKAGED_PLAYWRIGHT_RUNTIME/);
  assert.match(lifecycle, /"--probe-runtime"/);
  assert.doesNotMatch(daemonService, /EnvironmentFile=/);
  assert.match(daemonService, /UnsetEnvironment=.*BASH_ENV.*LD_PRELOAD.*NODE_OPTIONS/);
  assert.match(lifecycle, /installed != Self\.pinnedPlaywrightVersion/);
  assert.doesNotMatch(lifecycle, /hasPrefix\(Self\.pinnedPlaywrightVersion/);
  assert.match(service, /ensureReady\(performInstallIfMissing: false\)/);
  const syntax = spawnSync('bash', ['-n', probeScript], { encoding: 'utf8' });
  assert.equal(syntax.status, 0, syntax.stderr);
});
