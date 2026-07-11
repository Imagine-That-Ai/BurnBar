import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { repoRoot } from './lib/linux-release-common.mjs';

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
      'source "$1"; run_xctest_case "$2" OpenBurnBarTests/FakeRetryTest',
      '_',
      path.join(repoRoot, 'scripts/linux-port/run-linux-native-tests.sh'),
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

function writeExecutable(filePath, contents) {
  fs.writeFileSync(filePath, contents);
  fs.chmodSync(filePath, 0o755);
}

test('attestd harness resolver uses the exact current Cargo library test artifact', () => {
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-attestd-harness-'));
  const binDirectory = path.join(temporaryDirectory, 'bin');
  const staleHarness = path.join(temporaryDirectory, 'openburnbar_attestd-000-stale');
  const currentHarness = path.join(temporaryDirectory, 'openburnbar_attestd-999-current');
  const cargoMessages = path.join(temporaryDirectory, 'cargo-messages.jsonl');
  const cargoArguments = path.join(temporaryDirectory, 'cargo-arguments');
  fs.mkdirSync(binDirectory);

  writeExecutable(staleHarness, `#!/usr/bin/env bash
printf 'backend::tests::attest_collects_tpm_quote_and_sealed_bundle: test\n'
`);
  writeExecutable(currentHarness, `#!/usr/bin/env bash
printf 'backend::tests::attest_collects_tpm_quote_and_sealed_bundle: test\n'
`);
  fs.writeFileSync(cargoMessages, `${JSON.stringify({
    reason: 'compiler-artifact',
    target: { kind: ['lib'], name: 'openburnbar_attestd' },
    profile: { test: true },
    executable: currentHarness
  })}\n`);
  writeExecutable(path.join(binDirectory, 'cargo'), `#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "\${OPENBURNBAR_FAKE_CARGO_ARGUMENTS:?}"
cat "\${OPENBURNBAR_FAKE_CARGO_MESSAGES:?}"
`);
  writeExecutable(path.join(binDirectory, 'node'), `#!/usr/bin/env bash
printf 'attestd resolver must not require Node.js\n' >&2
exit 99
`);

  try {
    const result = spawnSync('bash', [
      '-c',
      'source "$1"; build_attestd_test_harness crates/openburnbar-attestd/Cargo.toml',
      '_',
      path.join(repoRoot, 'scripts/linux-port/run-linux-native-tests.sh')
    ], {
      cwd: repoRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${binDirectory}:${process.env.PATH}`,
        OPENBURNBAR_FAKE_CARGO_ARGUMENTS: cargoArguments,
        OPENBURNBAR_FAKE_CARGO_MESSAGES: cargoMessages
      }
    });

    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.equal(result.stdout.trim(), currentHarness);
    assert.notEqual(result.stdout.trim(), staleHarness);
    assert.match(fs.readFileSync(cargoArguments, 'utf8'), /--lib --no-run --message-format=json/);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test('attestd harness resolver fails closed when Cargo reports no library test executable', () => {
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-attestd-missing-harness-'));
  const binDirectory = path.join(temporaryDirectory, 'bin');
  const cargoMessages = path.join(temporaryDirectory, 'cargo-messages.jsonl');
  fs.mkdirSync(binDirectory);
  fs.writeFileSync(cargoMessages, `${JSON.stringify({
    reason: 'compiler-artifact',
    target: { kind: ['bin'], name: 'openburnbar-attestd' },
    profile: { test: true },
    executable: path.join(temporaryDirectory, 'wrong-binary')
  })}\n`);
  writeExecutable(path.join(binDirectory, 'cargo'), `#!/usr/bin/env bash
set -euo pipefail
cat "\${OPENBURNBAR_FAKE_CARGO_MESSAGES:?}"
`);

  try {
    const result = spawnSync('bash', [
      '-c',
      'source "$1"; build_attestd_test_harness crates/openburnbar-attestd/Cargo.toml',
      '_',
      path.join(repoRoot, 'scripts/linux-port/run-linux-native-tests.sh')
    ], {
      cwd: repoRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${binDirectory}:${process.env.PATH}`,
        OPENBURNBAR_FAKE_CARGO_MESSAGES: cargoMessages
      }
    });

    assert.notEqual(result.status, 0, result.stdout);
    assert.match(result.stderr, /identified 0 .* library test harnesses; expected exactly one/);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});
