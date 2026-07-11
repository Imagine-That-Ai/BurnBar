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
const toolchainDockerfile = read('tools/linux-toolchain/Dockerfile');
const toolchainSmoke = read('tools/linux-toolchain/smoke.sh');
const workflow = read('.github/workflows/linux-pr-gate.yml');

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
  for (const dependency of ['at-spi2-core', 'python3-dbus', 'python3-gi', 'python3-pyatspi', 'orca']) {
    assert.match(session, new RegExp(`\\n  ${dependency.replace('-', '\\-')}\\n`), dependency);
  }
  for (const route of REQUIRED_ROUTES) {
    assert.match(session, new RegExp(`\\n    ${route.replace('-', '\\-')}\\n`), route);
    assert.match(verifier, new RegExp(`'${route}'`), route);
  }
  for (const marker of [
    'capture-atspi-tree.py',
    'design-tokens entitlements gl-engine',
    'orca --list-apps',
    '--mode activate',
    'atspi-command-route-',
    'tray-action-route-results.json',
    'tray-chat-menu-event.txt',
    'tray-providers-menu-event.txt',
    'tray-updates-menu-event.txt',
    'tray-login-start-menu-event.txt',
    'tray-action-route-results.json',
    'tray-host-loss-recovery.json',
    'tray-host-loss-recovery-menu-event.txt',
    'tray-recovered-menu-actions.json',
    'freedesktop-notification-test-server.py',
    'OPENBURNBAR_NATIVE_NOTIFICATION_EVIDENCE',
    'native-notification-capabilities.json',
    'native-notification-action-result.json',
    'native-notification-response-result.json',
    'native-notification-relaunch-route.json',
    'native-status-window-report.json',
    'native-status-window-a11y.json',
    'native-deep-link-relaunch.json',
    'native-global-panic-shortcut-response.json',
    'native-global-panic-shortcut.json',
    'Ctrl+Alt+Shift+Period',
    'OpenBurnBar Panic Shortcut Probe',
    'native-login-start-roundtrip.json',
    'native-login-start-relogin.json',
    'native-login-start-autostart-exec.txt',
    'login-start-inner',
    'fresh-dbus-x11-autostart-session',
    'package-owned-autostart-reference',
    'capture_tray_host_loss_recovery',
    'refresh_tray_item_handles',
    'xfce4-panel-restart.log',
    'CHAT_ID',
    'PROVIDERS_ID',
    'UPDATES_ID',
    'LOGIN_START_ID',
    'atspi-keyboard-focus-sequence.json',
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

test('packaged session captures native shell evidence inputs from real D-Bus actions', () => {
  for (const marker of [
    'QUICK_STATUS_ID',
    'CHAT_ID',
    'PROVIDERS_ID',
    'UPDATES_ID',
    'LOGIN_START_ID',
    'wait_for_new_route_sample',
    'tray-chat-menu-event.txt',
    'tray-providers-menu-event.txt',
    'tray-updates-menu-event.txt',
    'tray-login-start-menu-event.txt',
    'native-status-window-report.json',
    'screenshot-native-status-window.png',
    'native-status-window-a11y.json',
    'native-deep-link-relaunch.json',
    'native-global-panic-shortcut-response.json',
    'native-global-panic-shortcut.json',
    'foregroundProbeFocused',
    'appWindowFocused',
    'native-login-start-roundtrip.json',
    'native-login-start-relogin.json',
    'userAutostartPreserved',
    'tray-host-loss-recovery.json',
    'tray-host-loss-recovery-menu-event.txt',
    'recoveredAction',
    'xfce4-panel-restart.log',
    'packaged-ui-route-after-paint:${route}',
    'openburnbar://chat',
    'secondaryProcessExited'
  ]) assert.ok(session.includes(marker), marker);
  assert.ok(session.includes('terminate_process_tree "$panel_pid"'));
  assert.doesNotMatch(session, /pkill .*xfce4-panel/);
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
