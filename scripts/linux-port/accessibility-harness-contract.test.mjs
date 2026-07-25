import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { repoRoot } from './lib/linux-release-common.mjs';

const read = (relativePath) => fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
const packageJson = JSON.parse(read('apps/linux-desktop/package.json'));
const axeAudit = read('apps/linux-desktop/src/accessibility/axeRouteAudit.test.tsx');
const session = read('scripts/linux-port/linux-desktop-session.sh');
const verifier = read('scripts/linux-port/verify-shell-evidence.mjs');
const evidenceRunner = read('scripts/linux-port/run-shell-evidence.mjs');
const smokeRunner = read('scripts/linux-port/run-shell-smoke.mjs');
const desktopWrapper = read('scripts/linux-port/run-shell-desktop-session.mjs');
const toolchainDockerfile = read('tools/linux-toolchain/Dockerfile');
const toolchainSmoke = read('tools/linux-toolchain/smoke.sh');
const workflow = read('.github/workflows/linux-pr-gate.yml');
const productParityWorkflow = read('.github/workflows/linux-product-parity.yml');
const p31Producer = read('scripts/linux-port/run-p31-live-accessibility-session.mjs');
const canonicalEnvironments = JSON.parse(read(
  'docs/linux-port/product-parity-requirements.json'
)).minimumSupportMatrix.map((environment) => environment.id);

const REQUIRED_ROUTES = [
  'overview', 'insights', 'database', 'providers', 'projects', 'missions',
  'activity', 'chat', 'memory', 'settings', 'account', 'updates', 'support',
  'onboarding', 'pet', 'text-expansion', 'computer-use', 'mercury', 'smarthub'
];

test('axe runs every route and both fail-closed capability states', () => {
  assert.equal(packageJson.devDependencies['axe-core'], '4.12.1');
  assert.match(axeAudit, /for \(const route of ROUTES\)/);
  assert.match(axeAudit, /capability-unavailable/);
  assert.match(axeAudit, /capability-degraded/);
  assert.match(axeAudit, /'color-contrast': \{ enabled: false \}/);
  assert.equal((axeAudit.match(/enabled: false/g) ?? []).length, 1, 'only color contrast may be disabled');
  assert.match(evidenceRunner, /axe-route-accessibility-scan\.json/);
});

test('packaged session provisions and exercises the Linux accessibility stack', () => {
  for (const dependency of ['at-spi2-core', 'python3-pyatspi', 'orca']) {
    assert.match(session, new RegExp(`\\n  ${dependency.replace('-', '\\-')}\\n`), dependency);
  }
  for (const route of REQUIRED_ROUTES) {
    assert.match(session, new RegExp(`\\n    ${route.replace('-', '\\-')}\\n`), route);
    assert.match(verifier, new RegExp(`'${route}'`), route);
  }
  for (const marker of [
    'capture-atspi-tree.py',
    '--wait-for-meaningful-seconds',
    'Initial AT-SPI tree did not become meaningful',
    'design-tokens entitlements gl-engine',
    'WEBKIT_DISABLE_DMABUF_RENDERER=1',
    'OB_XVFB_PRESTARTED=1',
    'dbus-run-session -- bash',
    'orca --list-apps',
    '--mode activate',
    '--mode grab-focus',
    'atspi-keyboard-focus-anchor.json',
    'atspi-keyboard-focus-reverse-anchor.json',
    'Skip to content',
    'atspi-command-route-',
    'atspi-keyboard-focus-sequence.json',
    'physical_tab_presses=28',
    'physical_shift_tab_presses=12',
    'focus_window_and_key',
    'count_orca_focus_events',
    'orca-anchor-exclusions.tsv',
    'anchor_document_focus',
    'focus_retry_rounds < 3',
    'events.length >= 10',
    'screenshot-linux-desktop-zoom-200-requested.png',
    'zoom-accessibility-evidence.json'
  ]) assert.ok(session.includes(marker), marker);
  for (const marker of [
    'VAL-A11Y-001',
    'checkAxeRouteMatrix',
    'checkPackagedAccessibility',
    'validateAtspiSummary',
    'validateAtspiAction',
    'Orca did not list OpenBurnBar'
  ]) assert.ok(verifier.includes(marker), marker);
});

test('fresh packaged sessions stage native payload inputs before Tauri packaging', () => {
  assert.match(session, /stage_native_package_inputs\(\)/u);
  assert.match(session, /cargo build[\s\S]*--manifest-path "\$root\/crates\/openburnbar-iroh\/Cargo\.toml"[\s\S]*--target-dir "\$iroh_target_dir"[\s\S]*--locked[\s\S]*--release/u);
  assert.match(session, /libopenburnbar_iroh\.so/u);
  assert.match(session, /libopenburnbar_iroh\.a/u);
  assert.match(session, /--scratch-path "\$daemon_scratch"/u);
  assert.match(session, /--product OpenBurnBarDaemon/u);
  assert.match(session, /--product OpenBurnBarCLI/u);
  assert.match(session, /OPENBURNBAR_LINUX_RESOURCE_BUNDLE/u);
  assert.match(session, /OpenBurnBarDaemon\/Resources\/PlaywrightBridge/u);

  const buildRootIndex = session.indexOf('build_root="$work_dir/build-root"');
  const stageIndex = session.indexOf('\n  stage_native_package_inputs\n', buildRootIndex);
  const packageIndex = session.indexOf('npm run tauri:build');
  assert.ok(stageIndex >= 0 && packageIndex > stageIndex, 'native staging must precede Tauri packaging');
  assert.match(session, /OB_REUSE_EXISTING_DEB:-0/u);

  const mediaCopyIndex = session.indexOf('cp -R "$root/crates/openburnbar-media"', buildRootIndex);
  const mediaDestinationIndex = session.indexOf('"$build_root/crates/openburnbar-media"', mediaCopyIndex);
  assert.ok(buildRootIndex >= 0, 'fresh shell sessions must define a build root');
  assert.ok(mediaCopyIndex > buildRootIndex, 'fresh shell sessions must copy the media crate into the build root');
  assert.ok(mediaDestinationIndex > mediaCopyIndex, 'media crate copy must preserve its repository-relative destination');
  assert.ok(mediaCopyIndex < stageIndex, 'media crate source must be present before native staging');
  assert.match(
    session.slice(buildRootIndex, stageIndex),
    /mkdir -p[\s\S]*"\$build_root\/crates"/u,
    'fresh shell build roots must provision the crates directory'
  );
});

test('toolchain and artifact reuse preserve the complete accessibility proof', () => {
  for (const dependency of ['orca', 'python3-pyatspi']) {
    assert.match(toolchainDockerfile, new RegExp(`\\n        ${dependency} \\\\`), dependency);
    assert.match(toolchainSmoke, new RegExp(`\\n  ${dependency} \\\\`), dependency);
  }
  for (const marker of [
    'routes.routes.length === 19',
    "route?.navMethod !== 'atspi-command-palette-actions'",
    'atspi-command-open-${routeSlug}.json',
    'atspi-command-route-${routeSlug}.json',
    'atspi-route-${routeSlug}.json',
    'report?.accessibility?.keyboardFocus?.pass === true',
    'report?.accessibility?.zoom?.pass === true'
  ]) assert.ok(smokeRunner.includes(marker), marker);
  for (const marker of [
    'best-effort',
    "error.code === 'EACCES' || error.code === 'EPERM'",
    'retaining raw transcript'
  ]) assert.ok(desktopWrapper.includes(marker), marker);
  for (const marker of [
    'function persistTranscript()',
    'function recordStep(step)',
    'persistTranscript();',
    'shell smoke step failed:',
    "OB_SHELL_DESKTOP_TIMEOUT_MS || '3600000'"
  ]) assert.ok(smokeRunner.includes(marker), marker);
});

test('AT-SPI crawler self-test and session shell syntax pass', () => {
  const python = spawnSync('python3', [
    '-B',
    path.join(repoRoot, 'scripts/linux-port/capture-atspi-tree.py'),
    '--self-test'
  ], { encoding: 'utf8' });
  assert.equal(python.status, 0, `${python.stdout}\n${python.stderr}`);
  assert.match(python.stdout, /"selfTest": "pass"/);

  const shell = spawnSync('bash', [
    '-n',
    path.join(repoRoot, 'scripts/linux-port/linux-desktop-session.sh')
  ], { encoding: 'utf8' });
  assert.equal(shell.status, 0, shell.stderr);
});

test('PR workflow cannot omit the accessibility contract', () => {
  assert.match(workflow, /accessibility-harness-contract\.test\.mjs/);
});

test('P-31 live accessibility certification spans the canonical real-session matrix', () => {
  for (const environmentId of canonicalEnvironments) {
    assert.ok(p31Producer.includes(`'${environmentId}'`), environmentId);
  }
  for (const marker of [
    "scaleBackend: 'gnome'",
    "scaleBackend: 'kscreen'",
    "scaleBackend: 'sway'",
    "keyboardBackend: 'xdotool'",
    "keyboardBackend: 'ydotool'",
    'parseKScreenOutputs',
    'parseSwayOutputs',
    'openburnbar-p31-webdriver-atspi-navigation-v1'
  ]) assert.ok(p31Producer.includes(marker), marker);
  assert.doesNotMatch(p31Producer, /P09_REQUIRED_ROUTES|run-p09-native-navigation-probes/u);

  for (const marker of [
    'ubuntu-24.04-gnome-x11-*)',
    'ubuntu-24.04-gnome-wayland-*)',
    'fedora-kde-wayland-*)',
    'arch-sway-wayland-x86_64)',
    'sudo apt-get install -y --no-install-recommends',
    'sudo dnf install -y',
    'sudo pacman -S --needed --noconfirm',
    'test -n "${YDOTOOL_SOCKET:-}"',
    '--compositor "$compositor"'
  ]) assert.ok(productParityWorkflow.includes(marker), marker);
});
