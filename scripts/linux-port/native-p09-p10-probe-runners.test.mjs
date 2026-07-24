import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import {
  parseP09Arguments,
  runP09NativeNavigationProbes
} from './run-p09-native-navigation-probes.mjs';
import {
  parseP10Arguments,
  runP10NativeDashboardProbes
} from './run-p10-native-dashboard-probes.mjs';

const binding = Object.freeze({
  environmentId: 'ubuntu-24.04-gnome-x11-x86_64',
  targetHead: 'a'.repeat(40),
  candidateRunId: '42',
  candidateArtifactDigest: `sha256:${'b'.repeat(64)}`,
  packageVersion: '1.2.3',
  manifestSha256: 'c'.repeat(64),
  manifestSignatureSha256: 'd'.repeat(64),
  compositor: 'Mutter 46.2'
});

function withDesktopEnvironment(callback) {
  const before = {
    DBUS_SESSION_BUS_ADDRESS: process.env.DBUS_SESSION_BUS_ADDRESS,
    DISPLAY: process.env.DISPLAY
  };
  process.env.DBUS_SESSION_BUS_ADDRESS = 'unix:path=/run/user/1000/bus';
  process.env.DISPLAY = ':0';
  return Promise.resolve(callback()).finally(() => {
    for (const [key, value] of Object.entries(before)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
  });
}

function failingRunner(message) {
  return {
    run(command, args) {
      return { status: 73, stdout: '', stderr: `${message}: ${command} ${args.join(' ')}` };
    },
    start() { throw new Error('start must not be reached after command failure'); }
  };
}

function testDirectory(prefix) {
  const root = path.join(process.cwd(), '.tmp');
  fs.mkdirSync(root, { recursive: true });
  return fs.mkdtempSync(path.join(root, prefix));
}

function successfulP10Runner(log) {
  let nextPid = 2000;
  let currentPid = null;
  const alive = new Set();
  const windowId = () => String(currentPid + 10_000);
  const write = (file, value) => fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
  const tree = (expectedName, state) => {
    const namedSamples = [
      { role: 'heading', name: expectedName, states: [], actions: [] },
      { role: 'button', name: 'Provider Codex', states: ['focusable'], actions: ['click'] },
      { role: 'text', name: 'Usage $12.34', states: [], actions: [] },
      { role: 'status', name: 'Data source: live daemon', states: [], actions: [] }
    ];
    while (namedSamples.length < 12) namedSamples.push({ role: 'text', name: `Metric ${namedSamples.length}`, states: [], actions: [] });
    if (state === 'loading') namedSamples.push({ role: 'status', name: 'Loading overview', states: ['busy'], actions: [] });
    if (state === 'offline') namedSamples.push({ role: 'status', name: 'Daemon offline reconnect', states: [], actions: [] });
    if (state === 'error') namedSamples.push({ role: 'alert', name: 'Overview failed error', states: [], actions: [] });
    return {
      pass: true, expectedNamePresent: true, expectedName, nodeCount: 30,
      namedNodeCount: namedSamples.length, actionableNodeCount: 6, namedSamples
    };
  };
  return {
    start(command) {
      assert.equal(command, '/usr/bin/openburnbar-linux-desktop');
      currentPid = nextPid += 1;
      alive.add(currentPid);
      log.push(`start:${currentPid}`);
      return { pid: currentPid, kill() { alive.delete(currentPid); log.push(`kill:${currentPid}`); return true; } };
    },
    run(command, args) {
      const entry = `${command}:${args.join(' ')}`;
      if (command === 'sh') return { status: 0, stdout: '', stderr: '' };
      if (command === 'kill' && args[0] === '-0') return { status: alive.has(Number(args[1])) ? 0 : 1, stdout: '', stderr: '' };
      if (command === 'xdotool') {
        if (args[0] === 'search') return { status: 0, stdout: `${windowId()}\n`, stderr: '' };
        if (args[0] === 'getwindowpid') return { status: 0, stdout: `${currentPid}\n`, stderr: '' };
        log.push(entry);
        return { status: 0, stdout: '', stderr: '' };
      }
      if (command === '/usr/bin/openburnbar-cli') return { status: 0, stdout: 'ok=true daemon=ready\n', stderr: '' };
      if (command === 'scrot') {
        fs.writeFileSync(args.at(-1), Buffer.alloc(2048, 7));
        return { status: 0, stdout: '', stderr: '' };
      }
      if (command === 'systemctl') {
        log.push(entry);
        return { status: 0, stdout: '', stderr: '' };
      }
      if (command === 'python3') {
        const output = args[args.indexOf('--output') + 1];
        if (args[0].endsWith('capture-p10-live-geometry.py')) {
          write(output, { producer: 'openburnbar-p10-live-geometry-probe-v1' });
          return { status: 0, stdout: '', stderr: '' };
        }
        const mode = args[args.indexOf('--mode') + 1];
        const expectedName = args[args.indexOf('--expected-name') + 1];
        if (mode === 'activate') {
          write(output, { pass: true, activation: { activated: true } });
          log.push(`activate:${expectedName}`);
        } else {
          const state = path.basename(output).match(/^dashboard-state-(loading|populated|offline|error)-atspi\.json$/u)?.[1] ?? null;
          write(output, tree(expectedName, state));
          log.push(`capture:${state ?? path.basename(output)}`);
        }
        return { status: 0, stdout: '', stderr: '' };
      }
      return { status: 70, stdout: '', stderr: `unexpected command: ${entry}` };
    }
  };
}

test('P09 rejects non-Linux execution before installed verification', async () => {
  let verified = false;
  await assert.rejects(
    runP09NativeNavigationProbes({ ...binding, outputDir: '/tmp/p09-never' }, {
      platform: 'darwin',
      installedVerifier() { verified = true; }
    }),
    /must execute on Linux/u
  );
  assert.equal(verified, false);
});

test('P10 rejects non-Linux execution before installed verification', async () => {
  let verified = false;
  await assert.rejects(
    runP10NativeDashboardProbes({ ...binding, outputDir: '/tmp/p10-never', renderBackend: 'WebKitGTK 2.44' }, {
      platform: 'win32',
      installedVerifier() { verified = true; }
    }),
    /must execute on Linux/u
  );
  assert.equal(verified, false);
});

test('P09 propagates a required native command failure', async () => {
  const outputDir = testDirectory('p09-native-runner-');
  try {
    let verified = 0;
    await withDesktopEnvironment(() => assert.rejects(
      runP09NativeNavigationProbes({ ...binding, outputDir }, {
        platform: 'linux', runner: failingRunner('missing native tool'),
        installedVerifier() { verified += 1; }
      }),
      /required tool python3 failed \(73\): missing native tool/u
    ));
    assert.equal(verified, 1);
  } finally {
    fs.rmSync(outputDir, { recursive: true, force: true });
  }
});

test('P10 propagates a required native command failure', async () => {
  const outputDir = testDirectory('p10-native-runner-');
  try {
    let verified = 0;
    await withDesktopEnvironment(() => assert.rejects(
      runP10NativeDashboardProbes({ ...binding, outputDir, renderBackend: 'WebKitGTK 2.44' }, {
        platform: 'linux', runner: failingRunner('AT-SPI unavailable'),
        installedVerifier() { verified += 1; }
      }),
      /required tool python3 failed \(73\): AT-SPI unavailable/u
    ));
    assert.equal(verified, 1);
  } finally {
    fs.rmSync(outputDir, { recursive: true, force: true });
  }
});

test('P10 full happy path captures offline before reconnect and error', async () => {
  const outputDir = testDirectory('p10-native-happy-');
  const log = [];
  try {
    const result = await withDesktopEnvironment(() => runP10NativeDashboardProbes({
      ...binding, outputDir, renderBackend: 'WebKitGTK 2.44'
    }, {
      platform: 'linux', runner: successfulP10Runner(log), installedVerifier() {}
    }));
    assert.equal(result.captureCount, 12);
    assert.deepEqual(result.states, ['loading', 'populated', 'offline', 'error']);
    const stop = log.indexOf('systemctl:--user stop openburnbar-daemon.service');
    const offline = log.indexOf('capture:offline');
    const reconnect = log.indexOf('activate:Reconnect');
    const error = log.indexOf('capture:error');
    assert(stop >= 0 && stop < offline && offline < reconnect && reconnect < error, log.join('\n'));

    const layoutEvents = JSON.parse(fs.readFileSync(path.join(outputDir, 'layout-classic-desktop-events.json'), 'utf8'));
    assert.deepEqual(layoutEvents.events.map((event) => event.kind), [
      'layout-selected-atspi', 'app-relaunched', 'persisted-layout-readback'
    ]);
    assert.notEqual(layoutEvents.events[0].appPid, layoutEvents.events[1].appPid);
    assert.equal(layoutEvents.events[1].appPid, layoutEvents.events[2].appPid);
    const layoutAtspi = JSON.parse(fs.readFileSync(path.join(outputDir, 'layout-classic-desktop-atspi.json'), 'utf8'));
    assert.deepEqual(Object.keys(layoutAtspi).sort(), [
      'actionableNodeCount', 'appPid', 'capturedAt', 'desktop', 'displayServer',
      'expectedName', 'expectedNamePresent', 'layout', 'manifestSha256',
      'namedNodeCount', 'namedSamples', 'nodeCount', 'producer', 'viewport', 'windowId'
    ].sort());
    assert.equal(layoutAtspi.capturedAt, layoutEvents.events[2].at);

    const stateEvents = JSON.parse(fs.readFileSync(path.join(outputDir, 'dashboard-state-events.json'), 'utf8'));
    assert.deepEqual(stateEvents.events.map((event) => event.state), ['loading', 'populated', 'offline', 'error']);
    for (const event of stateEvents.events) {
      const snapshot = JSON.parse(fs.readFileSync(path.join(outputDir, `dashboard-state-${event.state}-atspi.json`), 'utf8'));
      assert.equal(snapshot.capturedAt, event.at);
      assert.equal(snapshot.appPid, event.appPid);
      assert.equal(snapshot.windowId, event.windowId);
    }
  } finally {
    fs.rmSync(outputDir, { recursive: true, force: true });
  }
});

test('P09 and P10 parsers require exact binding flags', () => {
  const common = [
    '--output-dir', '/tmp/evidence', '--environment', binding.environmentId,
    '--target-head', binding.targetHead, '--candidate-run-id', binding.candidateRunId,
    '--candidate-artifact-digest', binding.candidateArtifactDigest,
    '--package-version', binding.packageVersion, '--manifest-sha256', binding.manifestSha256,
    '--manifest-signature-sha256', binding.manifestSignatureSha256,
    '--compositor', binding.compositor
  ];
  assert.equal(parseP09Arguments(common).environmentId, binding.environmentId);
  assert.equal(parseP10Arguments([...common, '--render-backend', 'WebKitGTK 2.44']).renderBackend, 'WebKitGTK 2.44');
  assert.throws(() => parseP09Arguments([...common, '--compositor', 'duplicate']), /invalid argument/u);
  assert.throws(() => parseP10Arguments(common), /--render-backend is required/u);
});
