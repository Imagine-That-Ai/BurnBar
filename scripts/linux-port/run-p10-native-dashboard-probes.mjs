#!/usr/bin/env node
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { INSTALLED_UI_ENVIRONMENTS } from './lib/installed-ui-proof.mjs';
import { P10_LAYOUTS, P10_VIEWPORTS } from './lib/p10-dashboard-layout-proof.mjs';
import { verifyInstalledCandidate } from './run-p08-mercury-media-session.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const DESKTOP = '/usr/bin/openburnbar-linux-desktop';
const CLI = '/usr/bin/openburnbar-cli';
const AT_SPI = path.join(ROOT, 'scripts/linux-port/capture-atspi-tree.py');
const GEOMETRY = path.join(ROOT, 'scripts/linux-port/capture-p10-live-geometry.py');
const SHA256 = /^[a-f0-9]{64}$/u;
const HEAD = /^[a-f0-9]{40,64}$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const VERSION = /^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$/u;
const LAYOUT_NAMES = Object.freeze({ classic: 'Classic', aurora: 'Aurora', nebula: 'Nebula', constellation: 'Constellation', cockpit: 'Cockpit', atelier: 'Atelier' });
const VIEWPORT_SIZE = Object.freeze({ desktop: [1280, 800], compact: [640, 720] });

function fail(message) { throw new Error(message); }
function assert(value, message) { if (!value) fail(message); }
function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
function writeJson(file, value) { fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 }); }
function stamp(previous = 0) {
  const milliseconds = Math.max(Date.now(), previous + 1);
  return { capturedAt: new Date(milliseconds).toISOString(), milliseconds };
}

export function defaultP10CommandRunner() {
  return {
    run(command, args = [], options = {}) {
      const result = spawnSync(command, args, { encoding: 'utf8', ...options });
      if (result.error) throw result.error;
      return { status: result.status, stdout: result.stdout ?? '', stderr: result.stderr ?? '' };
    },
    start(command, args = [], options = {}) {
      const child = spawn(command, args, { stdio: ['ignore', 'ignore', 'ignore'], ...options });
      child.unref();
      return { pid: child.pid, kill: (signal = 'SIGTERM') => child.kill(signal) };
    }
  };
}

function requiredRun(runner, command, args = [], options = {}, label = command) {
  const result = runner.run(command, args, options);
  if (result.status !== 0) fail(`${label} failed (${result.status}): ${result.stderr || result.stdout}`.trim());
  return result.stdout.trim();
}

function launch(runner, outputDir) {
  return runner.start(DESKTOP, [], { env: { ...process.env, OPENBURNBAR_EVIDENCE_OUT: outputDir } });
}

function exactPidWindow(runner, expectedPid) {
  const ids = requiredRun(runner, 'xdotool', ['search', '--onlyvisible', '--name', '^OpenBurnBar'], {}, 'find OpenBurnBar window').split(/\s+/u).filter(Boolean);
  const matches = ids.filter((id) => requiredRun(runner, 'xdotool', ['getwindowpid', id], {}, `read PID for ${id}`) === String(expectedPid));
  assert(matches.length === 1, `expected one primary OpenBurnBar window for PID ${expectedPid}`);
  return matches[0];
}

async function waitForWindow(runner, pid, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    try { return exactPidWindow(runner, pid); } catch (error) { last = error; await sleep(250); }
  }
  throw new Error(`window did not appear for PID ${pid}: ${last?.message ?? 'timeout'}`);
}

async function waitForExit(runner, pid, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (runner.run('kill', ['-0', String(pid)]).status !== 0) return;
    await sleep(200);
  }
  fail(`installed app PID ${pid} did not exit`);
}

function activate(runner, outputDir, expectedName, suffix, withinRole = null) {
  const args = [AT_SPI, '--application', 'OpenBurnBar', '--mode', 'activate', '--expected-name', expectedName, '--output', path.join(outputDir, `activation-${suffix}.json`)];
  if (withinRole) args.push('--within-role', withinRole);
  requiredRun(runner, 'python3', args, {}, `AT-SPI activate ${expectedName}`);
}

function captureSummary(runner, output, expectedName) {
  requiredRun(runner, 'python3', [AT_SPI, '--application', 'OpenBurnBar', '--mode', 'summary', '--route', 'overview', '--expected-name', expectedName, '--output', output], {}, `AT-SPI capture ${expectedName}`);
  const tree = JSON.parse(fs.readFileSync(output, 'utf8'));
  assert(tree.pass === true && tree.expectedNamePresent === true && tree.nodeCount >= 10
    && tree.namedNodeCount >= 3 && tree.actionableNodeCount >= 1, `${path.basename(output)} lacks live AT-SPI semantics`);
  return tree;
}

function atspiIdentity(expected, manifestSha256, appPid, windowId, capturedAt) {
  return { appPid, capturedAt, desktop: expected.desktop, displayServer: expected.session, manifestSha256, windowId: String(windowId) };
}

function exactLayoutTree(tree, identity, layout, viewport) {
  return {
    producer: 'openburnbar-p10-native-dashboard-probe-v1', ...identity,
    layout, viewport, expectedName: `${LAYOUT_NAMES[layout]} dashboard layout`,
    expectedNamePresent: tree.expectedNamePresent, nodeCount: tree.nodeCount,
    namedNodeCount: tree.namedNodeCount, actionableNodeCount: tree.actionableNodeCount,
    namedSamples: tree.namedSamples
  };
}

function namedRows(tree) { return Array.isArray(tree.namedSamples) ? tree.namedSamples : []; }
function hasName(tree, pattern) { return namedRows(tree).some((row) => pattern.test(String(row.name ?? ''))); }
function hasRole(tree, role, pattern = /.*/u) { return namedRows(tree).some((row) => row.role === role && pattern.test(String(row.name ?? ''))); }
function hasState(tree, state) { return namedRows(tree).some((row) => Array.isArray(row.states) && row.states.includes(state)); }

function stateSemantics(tree, state) {
  const semantics = {
    ariaBusy: hasState(tree, 'busy') || hasName(tree, /loading overview/iu),
    layoutNamePresent: hasName(tree, /dashboard layout/iu) && hasName(tree, /data source:\s*live daemon/iu),
    statusRolePresent: hasRole(tree, 'status', /offline|daemon|reconnect/iu),
    alertRolePresent: hasRole(tree, 'alert', /failed|error|unavailable/iu)
  };
  const passed = state === 'loading' ? semantics.ariaBusy
    : state === 'populated' ? semantics.layoutNamePresent
      : state === 'offline' ? semantics.statusRolePresent : semantics.alertRolePresent;
  return { ...semantics, passed };
}

async function captureState(runner, outputDir, state, layout, identityFactory, timeoutMs = 15_000) {
  const output = path.join(outputDir, `dashboard-state-${state}-atspi.json`);
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    try {
      const tree = captureSummary(runner, output, `${LAYOUT_NAMES[layout]} dashboard layout`);
      const semantics = stateSemantics(tree, state);
      if (semantics.passed) {
        const identity = identityFactory();
        writeJson(output, {
          producer: 'openburnbar-p10-native-state-probe-v1', ...identity, state,
          expectedNamePresent: tree.expectedNamePresent, ariaBusy: semantics.ariaBusy,
          layoutNamePresent: semantics.layoutNamePresent, statusRolePresent: semantics.statusRolePresent,
          alertRolePresent: semantics.alertRolePresent
        });
        return identity;
      }
      last = new Error(`${state} semantics not present`);
    } catch (error) { last = error; }
    await sleep(200);
  }
  throw new Error(`live dashboard never exposed ${state}: ${last?.message ?? 'timeout'}`);
}

function captureScreenshot(runner, output, windowId) {
  requiredRun(runner, 'xdotool', ['windowactivate', '--sync', windowId], {}, `focus screenshot window ${windowId}`);
  requiredRun(runner, 'scrot', ['--overwrite', '--focused', output], {}, `screenshot ${path.basename(output)}`);
  assert(fs.statSync(output).size > 1024, 'dashboard screenshot is empty');
}

function daemonSnapshot(runner, tree) {
  const health = requiredRun(runner, CLI, ['health'], {}, 'installed CLI health');
  assert(/ok=true/iu.test(health), 'installed CLI did not report connected daemon health');
  const providerCount = namedRows(tree).filter((row) => /provider/iu.test(String(row.name ?? ''))).length;
  const usagePointCount = namedRows(tree).filter((row) => /usage|burn|cost|\$/iu.test(String(row.name ?? ''))).length;
  assert(providerCount > 0 && usagePointCount > 0, 'live dashboard exposed no provider or usage content');
  return { producer: 'openburnbar-cli-live-dashboard-probe-v1', connected: true, fixtureMode: false, providerCount, usagePointCount };
}

export async function runP10NativeDashboardProbes(options, dependencies = {}) {
  const runner = dependencies.runner ?? defaultP10CommandRunner();
  const platform = dependencies.platform ?? process.platform;
  assert(platform === 'linux', 'P-10 native probe must execute on Linux');
  const expected = INSTALLED_UI_ENVIRONMENTS[options.environmentId];
  assert(expected, 'P-10 native probe requires a supported Linux environment');
  assert(HEAD.test(options.targetHead ?? '') && RUN_ID.test(String(options.candidateRunId ?? ''))
    && DIGEST.test(options.candidateArtifactDigest ?? '') && VERSION.test(options.packageVersion ?? '')
    && SHA256.test(options.manifestSha256 ?? '') && SHA256.test(options.manifestSignatureSha256 ?? ''), 'P-10 candidate binding is invalid');
  assert(typeof options.compositor === 'string' && options.compositor.length > 0 && !/(?:xvfb|xfce|synthetic|mock)/iu.test(options.compositor), 'P-10 requires a real compositor');
  assert(typeof options.renderBackend === 'string' && options.renderBackend.length > 0 && !/(?:fixture|mock|storybook|placeholder)/iu.test(options.renderBackend), 'P-10 requires a real render backend');
  assert(process.env.DBUS_SESSION_BUS_ADDRESS && (process.env.DISPLAY || process.env.WAYLAND_DISPLAY), 'P-10 requires a live desktop session and D-Bus');
  (dependencies.installedVerifier ?? verifyInstalledCandidate)(options);
  const outputDir = path.resolve(options.outputDir);
  fs.mkdirSync(outputDir, { recursive: true, mode: 0o700 });
  assert(fs.lstatSync(outputDir).isDirectory() && !fs.lstatSync(outputDir).isSymbolicLink(), 'P-10 output must be a real directory');
  for (const tool of ['python3', 'xdotool', 'scrot']) requiredRun(runner, 'sh', ['-c', `command -v "$1" >/dev/null`, 'p10-tool', tool], {}, `required tool ${tool}`);

  let app = launch(runner, outputDir);
  let pid = app.pid;
  assert(Number.isSafeInteger(pid) && pid > 1, 'installed app launch returned no PID');
  let windowId = await waitForWindow(runner, pid);
  let clock = 0;
  let daemonStopped = false;
  try {
    activate(runner, outputDir, 'Open command palette', 'palette-overview');
    activate(runner, outputDir, 'Overview', 'route-overview', 'dialog');
    for (const layout of P10_LAYOUTS) for (const viewport of P10_VIEWPORTS) {
      const key = `${layout}-${viewport}`;
      const [width, height] = VIEWPORT_SIZE[viewport];
      requiredRun(runner, 'xdotool', ['windowsize', '--sync', windowId, String(width), String(height)], {}, `resize ${key}`);
      activate(runner, outputDir, LAYOUT_NAMES[layout], `layout-${key}`, 'group');
      let time = stamp(clock); clock = time.milliseconds;
      let eventIdentity = atspiIdentity(expected, options.manifestSha256, pid, windowId, time.capturedAt);
      const selected = { kind: 'layout-selected-atspi', layout, viewport, passed: true,
        appPid: eventIdentity.appPid, windowId: eventIdentity.windowId, desktop: eventIdentity.desktop,
        displayServer: eventIdentity.displayServer, manifestSha256: eventIdentity.manifestSha256, at: eventIdentity.capturedAt };
      const initialPid = pid;
      app.kill(); await waitForExit(runner, pid);
      app = launch(runner, outputDir); pid = app.pid;
      assert(pid !== initialPid, `${key} relaunch retained PID ${pid}`);
      windowId = await waitForWindow(runner, pid);
      requiredRun(runner, 'xdotool', ['windowsize', '--sync', windowId, String(width), String(height)], {}, `restore ${key} viewport`);
      time = stamp(clock); clock = time.milliseconds;
      eventIdentity = atspiIdentity(expected, options.manifestSha256, pid, windowId, time.capturedAt);
      const relaunched = { kind: 'app-relaunched', layout, viewport, passed: true,
        appPid: eventIdentity.appPid, windowId: eventIdentity.windowId, desktop: eventIdentity.desktop,
        displayServer: eventIdentity.displayServer, manifestSha256: eventIdentity.manifestSha256, at: eventIdentity.capturedAt };
      const atspiFile = path.join(outputDir, `layout-${key}-atspi.json`);
      const tree = captureSummary(runner, atspiFile, `${LAYOUT_NAMES[layout]} dashboard layout`);
      time = stamp(clock); clock = time.milliseconds;
      const readbackIdentity = atspiIdentity(expected, options.manifestSha256, pid, windowId, time.capturedAt);
      const readback = { kind: 'persisted-layout-readback', layout, viewport, passed: true,
        appPid: readbackIdentity.appPid, windowId: readbackIdentity.windowId, desktop: readbackIdentity.desktop,
        displayServer: readbackIdentity.displayServer, manifestSha256: readbackIdentity.manifestSha256, at: readbackIdentity.capturedAt };
      writeJson(atspiFile, exactLayoutTree(tree, readbackIdentity, layout, viewport));
      writeJson(path.join(outputDir, `layout-${key}-events.json`), { producer: 'openburnbar-p10-native-layout-probe-v1', events: [selected, relaunched, readback] });
      writeJson(path.join(outputDir, `layout-${key}-daemon.json`), daemonSnapshot(runner, tree));
      captureScreenshot(runner, path.join(outputDir, `layout-${key}.png`), windowId);
      requiredRun(runner, 'python3', [GEOMETRY, '--application', 'OpenBurnBar', '--source-atspi', atspiFile, '--output', path.join(outputDir, `layout-${key}-geometry.json`)], {}, `live geometry ${key}`);
    }

    const layout = P10_LAYOUTS.at(-1);
    const stateEvents = [];
    app.kill(); await waitForExit(runner, pid);
    app = launch(runner, outputDir); pid = app.pid; windowId = await waitForWindow(runner, pid);
    let identity = await captureState(runner, outputDir, 'loading', layout, () => {
      const time = stamp(clock); clock = time.milliseconds;
      return atspiIdentity(expected, options.manifestSha256, pid, windowId, time.capturedAt);
    }, 5_000);
    stateEvents.push({ state: 'loading', passed: true, appPid: identity.appPid, windowId: identity.windowId,
      desktop: identity.desktop, displayServer: identity.displayServer, manifestSha256: identity.manifestSha256, at: identity.capturedAt });
    identity = await captureState(runner, outputDir, 'populated', layout, () => {
      const time = stamp(clock); clock = time.milliseconds;
      return atspiIdentity(expected, options.manifestSha256, pid, windowId, time.capturedAt);
    });
    stateEvents.push({ state: 'populated', passed: true, appPid: identity.appPid, windowId: identity.windowId,
      desktop: identity.desktop, displayServer: identity.displayServer, manifestSha256: identity.manifestSha256, at: identity.capturedAt });

    requiredRun(runner, 'systemctl', ['--user', 'stop', 'openburnbar-daemon.service'], {}, 'stop daemon for offline/error states');
    daemonStopped = true;
    identity = await captureState(runner, outputDir, 'offline', layout, () => {
      const time = stamp(clock); clock = time.milliseconds;
      return atspiIdentity(expected, options.manifestSha256, pid, windowId, time.capturedAt);
    });
    stateEvents.push({ state: 'offline', passed: true, appPid: identity.appPid, windowId: identity.windowId,
      desktop: identity.desktop, displayServer: identity.displayServer, manifestSha256: identity.manifestSha256, at: identity.capturedAt });
    activate(runner, outputDir, 'Reconnect', 'state-error-reconnect');
    identity = await captureState(runner, outputDir, 'error', layout, () => {
      const time = stamp(clock); clock = time.milliseconds;
      return atspiIdentity(expected, options.manifestSha256, pid, windowId, time.capturedAt);
    });
    stateEvents.push({ state: 'error', passed: true, appPid: identity.appPid, windowId: identity.windowId,
      desktop: identity.desktop, displayServer: identity.displayServer, manifestSha256: identity.manifestSha256, at: identity.capturedAt });
    writeJson(path.join(outputDir, 'dashboard-state-events.json'), { producer: 'openburnbar-p10-native-state-probe-v1', events: stateEvents });
    return { outputDir, captureCount: P10_LAYOUTS.length * P10_VIEWPORTS.length, states: stateEvents.map((event) => event.state) };
  } finally {
    try { app.kill(); } catch { /* already exited */ }
    if (daemonStopped) runner.run('systemctl', ['--user', 'start', 'openburnbar-daemon.service']);
  }
}

export function parseP10Arguments(argv) {
  const flags = ['--output-dir', '--environment', '--target-head', '--candidate-run-id', '--candidate-artifact-digest', '--package-version', '--manifest-sha256', '--manifest-signature-sha256', '--compositor', '--render-backend'];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    if (!flags.includes(flag) || values.has(flag) || argv[index + 1] === undefined) fail(`invalid argument: ${flag ?? '<missing>'}`);
    values.set(flag, argv[index + 1]);
  }
  for (const flag of flags) if (!values.has(flag)) fail(`${flag} is required`);
  return { outputDir: values.get('--output-dir'), environmentId: values.get('--environment'), targetHead: values.get('--target-head'), candidateRunId: values.get('--candidate-run-id'), candidateArtifactDigest: values.get('--candidate-artifact-digest'), packageVersion: values.get('--package-version'), manifestSha256: values.get('--manifest-sha256'), manifestSignatureSha256: values.get('--manifest-signature-sha256'), compositor: values.get('--compositor'), renderBackend: values.get('--render-backend') };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.stdout.write(`${JSON.stringify(await runP10NativeDashboardProbes(parseP10Arguments(process.argv.slice(2))))}\n`); }
  catch (error) { process.stderr.write(`P-10 native dashboard probe failed: ${error.message}\n`); process.exitCode = 1; }
}
