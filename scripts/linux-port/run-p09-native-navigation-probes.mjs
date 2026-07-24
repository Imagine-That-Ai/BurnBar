#!/usr/bin/env node
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { INSTALLED_UI_ENVIRONMENTS } from './lib/installed-ui-proof.mjs';
import { P09_REQUIRED_ROUTES } from './lib/p09-navigation-shell-proof.mjs';
import { verifyInstalledCandidate } from './run-p08-mercury-media-session.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const DESKTOP = '/usr/bin/openburnbar-linux-desktop';
const AT_SPI = path.join(ROOT, 'scripts/linux-port/capture-atspi-tree.py');
const SHA256 = /^[a-f0-9]{64}$/u;
const HEAD = /^[a-f0-9]{40,64}$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const VERSION = /^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$/u;
const LABELS = Object.freeze([
  'Overview', 'Insights', 'Database', 'Providers & models', 'Projects', 'Missions',
  'Activity & logs', 'Chat / Hermes', 'Memory', 'Settings', 'Account & sync', 'Updates',
  'Support & diagnostics', 'First-run setup', 'Pet companion', 'Text expansion',
  'Computer Use', 'Mercury', 'SmartHub / IoT'
]);

function fail(message) { throw new Error(message); }
function assert(value, message) { if (!value) fail(message); }
function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
function timestamp(previous = 0) {
  const now = Math.max(Date.now(), previous + 1);
  return { at: new Date(now).toISOString(), milliseconds: now };
}

export function defaultCommandRunner() {
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

function parseGeometry(text) {
  const values = Object.fromEntries(text.split(/\n/u).map((line) => line.match(/^([A-Z]+)=(-?[0-9]+)$/u)).filter(Boolean).map((row) => [row[1], Number(row[2])]));
  assert(Number.isSafeInteger(values.X) && Number.isSafeInteger(values.Y)
    && Number.isSafeInteger(values.WIDTH) && values.WIDTH >= 320
    && Number.isSafeInteger(values.HEIGHT) && values.HEIGHT >= 200, 'live window has unusable geometry');
  return { x: values.X, y: values.Y, width: values.WIDTH, height: values.HEIGHT };
}

function parseXwininfo(text) {
  const number = (label) => Number(text.match(new RegExp(`^\\s*${label}:\\s*(-?[0-9]+)\\s*$`, 'mu'))?.[1]);
  const geometry = { x: number('Absolute upper-left X'), y: number('Absolute upper-left Y'), width: number('Width'), height: number('Height') };
  assert(Number.isSafeInteger(geometry.x) && Number.isSafeInteger(geometry.y)
    && Number.isSafeInteger(geometry.width) && geometry.width >= 320
    && Number.isSafeInteger(geometry.height) && geometry.height >= 200, 'xwininfo exposed unusable geometry');
  assert(/^\s*Map State:\s*IsViewable\s*$/mu.test(text), 'xwininfo window is not viewable');
  return geometry;
}

function monitorGeometries(text) {
  const rows = text.split(/\n/u).slice(1).map((line) => line.match(/\s([0-9]+)\/[^x]+x([0-9]+)\/[^+\s]+([+-][0-9]+)([+-][0-9]+)(?:\s|$)/u)).filter(Boolean)
    .map((match) => ({ width: Number(match[1]), height: Number(match[2]), x: Number(match[3]), y: Number(match[4]) }));
  assert(rows.length > 0 && rows.every((row) => row.width > 0 && row.height > 0), 'xrandr exposed no live monitor geometry');
  return rows;
}

function withinMonitor(geometry, monitors) {
  return monitors.some((monitor) => geometry.x >= monitor.x && geometry.y >= monitor.y
    && geometry.x + geometry.width <= monitor.x + monitor.width
    && geometry.y + geometry.height <= monitor.y + monitor.height);
}

function writeJson(file, value) { fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 }); }

function routeAtspi(file, identity, route, expectedName) {
  const tree = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert(tree.pass === true && tree.expectedNamePresent === true && tree.nodeCount >= 10
    && tree.namedNodeCount >= 3 && tree.actionableNodeCount >= 1, `${path.basename(file)} lacks live AT-SPI semantics`);
  writeJson(file, {
    producer: 'openburnbar-p09-native-route-probe-v1', ...identity, route, expectedName,
    expectedNamePresent: tree.expectedNamePresent, nodeCount: tree.nodeCount,
    namedNodeCount: tree.namedNodeCount, actionableNodeCount: tree.actionableNodeCount,
    namedSamples: tree.namedSamples
  });
}

function deepLinkAtspi(file, identity, expectedName) {
  const tree = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert(tree.pass === true && tree.expectedNamePresent === true && tree.nodeCount >= 10
    && tree.namedNodeCount >= 3 && tree.actionableNodeCount >= 1, `${path.basename(file)} lacks live AT-SPI semantics`);
  writeJson(file, {
    producer: 'openburnbar-p09-native-deep-link-probe-v1', ...identity, expectedName,
    expectedNamePresent: tree.expectedNamePresent, nodeCount: tree.nodeCount,
    namedNodeCount: tree.namedNodeCount, actionableNodeCount: tree.actionableNodeCount,
    namedSamples: tree.namedSamples
  });
}

function exactPidWindow(runner, expectedPid) {
  const ids = requiredRun(runner, 'xdotool', ['search', '--onlyvisible', '--name', '^OpenBurnBar'], {}, 'find OpenBurnBar window').split(/\s+/u).filter(Boolean);
  const matches = ids.filter((id) => requiredRun(runner, 'xdotool', ['getwindowpid', id], {}, `read PID for window ${id}`) === String(expectedPid));
  assert(matches.length === 1, `expected exactly one visible OpenBurnBar window owned by PID ${expectedPid}`);
  return matches[0];
}

async function waitForWindow(runner, pid, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try { return exactPidWindow(runner, pid); } catch (error) { lastError = error; await sleep(250); }
  }
  throw new Error(`installed app window did not appear for PID ${pid}: ${lastError?.message ?? 'timeout'}`);
}

async function waitForExit(runner, pid, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const result = runner.run('kill', ['-0', String(pid)]);
    if (result.status !== 0) return;
    await sleep(200);
  }
  fail(`installed app PID ${pid} did not exit`);
}

function activate(runner, outputDir, expectedName, suffix, withinRole = null) {
  const args = [AT_SPI, '--application', 'OpenBurnBar', '--mode', 'activate', '--expected-name', expectedName, '--output', path.join(outputDir, `activation-${suffix}.json`)];
  if (withinRole) args.push('--within-role', withinRole);
  requiredRun(runner, 'python3', args, {}, `AT-SPI activate ${expectedName}`);
}

function captureTree(runner, output, route, expectedName) {
  requiredRun(runner, 'python3', [AT_SPI, '--application', 'OpenBurnBar', '--mode', 'summary', '--route', route, '--expected-name', expectedName, '--output', output], {}, `AT-SPI capture ${expectedName}`);
}

function captureScreenshot(runner, output, windowId) {
  requiredRun(runner, 'xdotool', ['windowactivate', '--sync', windowId], {}, `focus screenshot window ${windowId}`);
  requiredRun(runner, 'scrot', ['--overwrite', '--focused', output], {}, `screenshot ${path.basename(output)}`);
  assert(fs.statSync(output).size > 1024, 'live screenshot is empty');
}

function launch(runner, outputDir, uri = null) {
  const env = { ...process.env, OPENBURNBAR_EVIDENCE_OUT: outputDir };
  return runner.start(DESKTOP, uri ? [uri] : [], { env });
}

function identityFor(expected, manifestSha256, pid, windowId, at) {
  return { capturedAt: at, appPid: pid, windowId: String(windowId), desktop: expected.desktop, displayServer: expected.session, manifestSha256 };
}

export async function runP09NativeNavigationProbes(options, dependencies = {}) {
  const runner = dependencies.runner ?? defaultCommandRunner();
  const platform = dependencies.platform ?? process.platform;
  assert(platform === 'linux', 'P-09 native probe must execute on Linux');
  const expected = INSTALLED_UI_ENVIRONMENTS[options.environmentId];
  assert(expected, 'P-09 native probe requires a supported Linux environment');
  assert(HEAD.test(options.targetHead ?? '') && RUN_ID.test(String(options.candidateRunId ?? ''))
    && DIGEST.test(options.candidateArtifactDigest ?? '') && VERSION.test(options.packageVersion ?? '')
    && SHA256.test(options.manifestSha256 ?? '') && SHA256.test(options.manifestSignatureSha256 ?? ''), 'P-09 candidate binding is invalid');
  assert(typeof options.compositor === 'string' && options.compositor.length > 0
    && !/(?:xvfb|xfce|synthetic|mock)/iu.test(options.compositor), 'P-09 requires a real compositor identity');
  assert(process.env.DBUS_SESSION_BUS_ADDRESS && (process.env.DISPLAY || process.env.WAYLAND_DISPLAY), 'P-09 requires a live desktop session and D-Bus');
  (dependencies.installedVerifier ?? verifyInstalledCandidate)(options);
  const outputDir = path.resolve(options.outputDir);
  fs.mkdirSync(outputDir, { recursive: true, mode: 0o700 });
  assert(fs.lstatSync(outputDir).isDirectory() && !fs.lstatSync(outputDir).isSymbolicLink(), 'P-09 output must be a real directory');
  for (const tool of ['python3', 'xdotool', 'xwininfo', 'xrandr', 'scrot']) requiredRun(runner, 'sh', ['-c', `command -v "$1" >/dev/null`, 'p09-tool', tool], {}, `required tool ${tool}`);

  let app = launch(runner, outputDir);
  assert(Number.isSafeInteger(app.pid) && app.pid > 1, 'installed app launch returned no PID');
  let pid = app.pid;
  let windowId = await waitForWindow(runner, pid);
  let clock = 0;
  const routes = [];
  try {
    for (const [index, route] of P09_REQUIRED_ROUTES.entries()) {
      activate(runner, outputDir, 'Open command palette', `palette-${route}`);
      activate(runner, outputDir, LABELS[index], `route-${route}`, 'dialog');
      await sleep(350);
      windowId = exactPidWindow(runner, pid);
      const stamp = timestamp(clock); clock = stamp.milliseconds;
      const identity = identityFor(expected, options.manifestSha256, pid, windowId, stamp.at);
      const atspi = `route-${route}-atspi.json`;
      const screenshot = `route-${route}.png`;
      const xwininfo = `route-${route}-xwininfo.txt`;
      captureTree(runner, path.join(outputDir, atspi), route, LABELS[index]);
      routeAtspi(path.join(outputDir, atspi), identity, route, LABELS[index]);
      captureScreenshot(runner, path.join(outputDir, screenshot), windowId);
      assert(requiredRun(runner, 'xdotool', ['getwindowfocus'], {}, `focused window ${route}`) === String(windowId), `${route} window is not focused`);
      const geometry = parseXwininfo(requiredRun(runner, 'xwininfo', ['-id', windowId], {}, `xwininfo ${route}`));
      writeJson(path.join(outputDir, xwininfo), {
        producer: 'openburnbar-p09-native-route-window-probe-v1', ...identity,
        route, geometry, visible: true, focused: true
      });
      routes.push({ route, navMethod: 'atspi-command-palette-actions', surface: 'installed-tauri-native-session', ...identity, atspi, screenshot, xwininfo });
    }

    const deepLinks = [
      ['provider', 'openburnbar://providers?provider=codex', 'Codex'],
      ['model', 'openburnbar://providers?provider=codex&model=gpt-5', 'gpt-5']
    ];
    for (const [kind, uri, expectedName] of deepLinks) {
      const kinds = ['native-link-accepted', 'single-instance-forwarded', 'history-reload-restored', 'back-forward-restored', 'focus-restored'];
      const events = [];
      const forwarded = launch(runner, outputDir, uri);
      await waitForExit(runner, forwarded.pid);
      assert(exactPidWindow(runner, pid) === windowId, `${kind} deep link did not retain the installed single instance`);
      for (const eventKind of kinds) {
        if (eventKind === 'history-reload-restored') requiredRun(runner, 'xdotool', ['key', '--window', windowId, '--clearmodifiers', 'ctrl+r'], {}, 'deep-link reload');
        if (eventKind === 'back-forward-restored') {
          requiredRun(runner, 'xdotool', ['key', '--window', windowId, '--clearmodifiers', 'alt+Left'], {}, 'deep-link back');
          requiredRun(runner, 'xdotool', ['key', '--window', windowId, '--clearmodifiers', 'alt+Right'], {}, 'deep-link forward');
        }
        requiredRun(runner, 'xdotool', ['windowactivate', '--sync', windowId], {}, 'deep-link focus');
        const observation = path.join(outputDir, `activation-deep-link-${kind}-${eventKind}.json`);
        captureTree(runner, observation, 'providers', expectedName);
        assert(JSON.parse(fs.readFileSync(observation, 'utf8')).expectedNamePresent === true,
          `${kind} deep-link destination was not restored after ${eventKind}`);
        const stamp = timestamp(clock); clock = stamp.milliseconds;
        const eventIdentity = identityFor(expected, options.manifestSha256, pid, windowId, stamp.at);
        events.push({ kind: eventKind, uri, passed: true, appPid: eventIdentity.appPid, windowId: eventIdentity.windowId,
          desktop: eventIdentity.desktop, displayServer: eventIdentity.displayServer,
          manifestSha256: eventIdentity.manifestSha256, at: eventIdentity.capturedAt });
      }
      const atspi = path.join(outputDir, `p09-deep-link-${kind}-atspi.json`);
      captureTree(runner, atspi, 'providers', expectedName);
      const lastIdentity = identityFor(expected, options.manifestSha256, pid, windowId, events.at(-1).at);
      deepLinkAtspi(atspi, lastIdentity, expectedName);
      captureScreenshot(runner, path.join(outputDir, `p09-deep-link-${kind}.png`), windowId);
      writeJson(path.join(outputDir, `p09-deep-link-${kind}-events.json`), { producer: 'openburnbar-p09-native-deep-link-probe-v1', events });
    }

    activate(runner, outputDir, 'Open command palette', 'palette-chat-window');
    activate(runner, outputDir, 'Chat / Hermes', 'route-chat-window', 'dialog');
    activate(runner, outputDir, 'Chat options', 'chat-options');
    activate(runner, outputDir, 'Pop out chat', 'chat-popout', 'menu');
    await sleep(500);
    const windows = requiredRun(runner, 'xdotool', ['search', '--onlyvisible', '--pid', String(pid), '--name', 'OpenBurnBar'], {}, 'secondary OpenBurnBar window').split(/\s+/u).filter(Boolean);
    assert(windows.length >= 2, 'Hermes secondary window was not opened');
    const secondaryId = windows.find((id) => id !== windowId);
    const firstGeometry = parseGeometry(requiredRun(runner, 'xdotool', ['getwindowgeometry', '--shell', secondaryId]));
    const windowEvents = [];
    let stamp = timestamp(clock); clock = stamp.milliseconds;
    let eventIdentity = identityFor(expected, options.manifestSha256, pid, secondaryId, stamp.at);
    windowEvents.push({ kind: 'secondary-window-opened', passed: true, geometry: firstGeometry,
      appPid: eventIdentity.appPid, windowId: eventIdentity.windowId, desktop: eventIdentity.desktop,
      displayServer: eventIdentity.displayServer, manifestSha256: eventIdentity.manifestSha256, at: eventIdentity.capturedAt });
    requiredRun(runner, 'xdotool', ['windowclose', secondaryId], {}, 'close secondary window');
    requiredRun(runner, 'xdotool', ['windowactivate', '--sync', windowId], {}, 'restore primary focus');
    const remainingSecondary = runner.run('xdotool', ['search', '--onlyvisible', '--pid', String(pid), '--name', 'OpenBurnBar']);
    assert(remainingSecondary.status === 0
      && remainingSecondary.stdout.split(/\s+/u).filter(Boolean).every((id) => id === windowId), 'secondary window remained visible after close');
    assert(requiredRun(runner, 'xdotool', ['getwindowfocus'], {}, 'restored primary focus') === String(windowId), 'primary focus was not restored');
    stamp = timestamp(clock); clock = stamp.milliseconds;
    eventIdentity = identityFor(expected, options.manifestSha256, pid, windowId, stamp.at);
    windowEvents.push({ kind: 'secondary-window-closed-focus-restored', passed: true,
      geometry: parseGeometry(requiredRun(runner, 'xdotool', ['getwindowgeometry', '--shell', windowId])),
      appPid: eventIdentity.appPid, windowId: eventIdentity.windowId, desktop: eventIdentity.desktop,
      displayServer: eventIdentity.displayServer, manifestSha256: eventIdentity.manifestSha256, at: eventIdentity.capturedAt });
    app.kill(); await waitForExit(runner, pid);
    const oldPid = pid;
    app = launch(runner, outputDir); pid = app.pid;
    assert(pid !== oldPid, 'P-09 relaunch retained the old PID');
    windowId = await waitForWindow(runner, pid);
    const restoredGeometry = parseGeometry(requiredRun(runner, 'xdotool', ['getwindowgeometry', '--shell', windowId]));
    const restoredTree = path.join(outputDir, 'activation-relaunch-route-readback.json');
    captureTree(runner, restoredTree, 'chat', 'Chat / Hermes');
    const routeReadback = JSON.parse(fs.readFileSync(restoredTree, 'utf8'));
    assert(routeReadback.expectedNamePresent === true, 'P-09 relaunch did not restore the active route');
    assert(JSON.stringify(restoredGeometry) === JSON.stringify(windowEvents[1].geometry), 'P-09 relaunch did not restore native window geometry');
    const monitors = monitorGeometries(requiredRun(runner, 'xrandr', ['--listmonitors'], {}, 'live monitor geometry'));
    assert(withinMonitor(restoredGeometry, monitors), 'restored window falls outside live monitor bounds');
    for (const kind of ['relaunch-state-restored', 'multi-monitor-geometry-restored', 'geometry-bounds-verified']) {
      stamp = timestamp(clock); clock = stamp.milliseconds;
      eventIdentity = identityFor(expected, options.manifestSha256, pid, windowId, stamp.at);
      windowEvents.push({ kind, passed: true, geometry: restoredGeometry,
        appPid: eventIdentity.appPid, windowId: eventIdentity.windowId, desktop: eventIdentity.desktop,
        displayServer: eventIdentity.displayServer, manifestSha256: eventIdentity.manifestSha256, at: eventIdentity.capturedAt });
    }
    writeJson(path.join(outputDir, 'p09-native-window-events.json'), { producer: 'openburnbar-p09-native-window-probe-v1', events: windowEvents });
    writeJson(path.join(outputDir, 'packaged-route-session-transcript.json'), {
      producer: 'openburnbar-p09-native-route-probe-v1', mode: 'packaged-desktop-route-navigation', surface: 'installed-tauri-native-session',
      environmentId: options.environmentId, desktop: expected.desktop, displayServer: expected.session,
      manifestSha256: options.manifestSha256, appPid: routes[0].appPid, routes
    });
    const perf = path.join(outputDir, 'runtime-perf-samples.jsonl');
    assert(fs.existsSync(perf), 'installed renderer produced no runtime performance samples');
    const sources = new Set(fs.readFileSync(perf, 'utf8').split(/\n/u).filter(Boolean).map((line) => JSON.parse(line)).filter((row) => row.name === 'route.navigation').map((row) => row.source));
    for (const route of P09_REQUIRED_ROUTES) assert(sources.has(`packaged-ui-route-after-paint:${route}`), `missing post-paint performance sample for ${route}`);
    return { outputDir, routeCount: routes.length, initialPid: routes[0].appPid, relaunchedPid: pid };
  } finally {
    try { app.kill(); } catch { /* process already exited */ }
  }
}

export function parseP09Arguments(argv) {
  const flags = ['--output-dir', '--environment', '--target-head', '--candidate-run-id', '--candidate-artifact-digest', '--package-version', '--manifest-sha256', '--manifest-signature-sha256', '--compositor'];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    if (!flags.includes(flag) || values.has(flag) || argv[index + 1] === undefined) fail(`invalid argument: ${flag ?? '<missing>'}`);
    values.set(flag, argv[index + 1]);
  }
  for (const flag of flags) if (!values.has(flag)) fail(`${flag} is required`);
  return { outputDir: values.get('--output-dir'), environmentId: values.get('--environment'), targetHead: values.get('--target-head'), candidateRunId: values.get('--candidate-run-id'), candidateArtifactDigest: values.get('--candidate-artifact-digest'), packageVersion: values.get('--package-version'), manifestSha256: values.get('--manifest-sha256'), manifestSignatureSha256: values.get('--manifest-signature-sha256'), compositor: values.get('--compositor') };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.stdout.write(`${JSON.stringify(await runP09NativeNavigationProbes(parseP09Arguments(process.argv.slice(2))))}\n`); }
  catch (error) { process.stderr.write(`P-09 native navigation probe failed: ${error.message}\n`); process.exitCode = 1; }
}
