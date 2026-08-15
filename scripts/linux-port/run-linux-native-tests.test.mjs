import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { repoRoot } from './lib/linux-release-common.mjs';

test('Linux native runner refuses non-Linux hosts before applying Linux filters', () => {
  const result = spawnSync('bash', [
    '-c',
    'source scripts/linux-port/run-linux-native-tests.sh; assert_linux_native_host Darwin'
  ], {
    cwd: repoRoot,
    encoding: 'utf8'
  });

  assert.equal(result.status, 78, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stderr, /require a Linux userspace/u);
  assert.match(result.stderr, /misleading zero-test filter failure/u);
});

test('Linux XCTest timeout retries in a fresh process under errexit', {
  skip: process.platform !== 'linux'
}, () => {
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-xctest-retry-'));
  const fakeXCTest = path.join(temporaryDirectory, 'fake-xctest');
  const stateFile = path.join(temporaryDirectory, 'attempt-count');

  fs.writeFileSync(fakeXCTest, `#!/usr/bin/env bash
set -euo pipefail
state_file="\${OPENBURNBAR_FAKE_XCTEST_STATE:?}"
attempt=0
if [[ -f "$state_file" ]]; then
  attempt="$(cat "$state_file")"
fi
attempt=$((attempt + 1))
printf '%s\n' "$attempt" > "$state_file"
if [[ "$attempt" -eq 1 ]]; then
  sleep 5
fi
printf 'Executed 1 test\n'
`);
  fs.chmodSync(fakeXCTest, 0o755);

  try {
    const result = spawnSync('bash', [
      '-c',
      'source scripts/linux-port/run-linux-native-tests.sh; run_xctest_case "$1" OpenBurnBarTests/FakeRetryTest',
      '_',
      fakeXCTest
    ], {
      cwd: repoRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        OPENBURNBAR_FAKE_XCTEST_STATE: stateFile,
        OPENBURNBAR_LINUX_XCTEST_TIMEOUT_SECONDS: '0.1',
        OPENBURNBAR_LINUX_XCTEST_KILL_AFTER_SECONDS: '0.1'
      },
      timeout: 10_000
    });

    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.equal(fs.readFileSync(stateFile, 'utf8').trim(), '2');
    assert.match(result.stderr, /retrying in a fresh process \(1\/2\)/);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test('Linux native Swift tests isolate SwiftPM scratch state by default and honor an override', {
  skip: process.platform !== 'linux'
}, () => {
  const result = spawnSync('bash', [
    '-c',
    'source scripts/linux-port/run-linux-native-tests.sh; linux_native_swift_scratch_root'
  ], {
    cwd: repoRoot,
    encoding: 'utf8',
    env: {
      ...process.env,
      TMPDIR: '/tmp/openburnbar-native-tests-contract'
    }
  });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout.trim(), /^\/tmp\/openburnbar-native-tests-contract\/openburnbar-linux-native-tests-\d+$/u);

  const override = '/tmp/openburnbar-native-tests-contract/explicit-scratch';
  const overridden = spawnSync('bash', [
    '-c',
    'source scripts/linux-port/run-linux-native-tests.sh; linux_native_swift_scratch_root'
  ], {
    cwd: repoRoot,
    encoding: 'utf8',
    env: { ...process.env, OPENBURNBAR_LINUX_SWIFT_SCRATCH_ROOT: override }
  });
  assert.equal(overridden.status, 0, `${overridden.stdout}\n${overridden.stderr}`);
  assert.equal(overridden.stdout.trim(), override);
  assert.equal(fs.statSync(override).isDirectory(), true);
  fs.rmSync('/tmp/openburnbar-native-tests-contract', { recursive: true, force: true });
});
