import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
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
  const outputDir = fs.mkdtempSync(path.join(os.tmpdir(), 'p09-native-runner-'));
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
  const outputDir = fs.mkdtempSync(path.join(os.tmpdir(), 'p10-native-runner-'));
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
