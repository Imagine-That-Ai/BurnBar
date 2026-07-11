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
    const scriptDirectory = path.join(repoRoot, 'scripts/linux-port');
    const fakeXCTestArgument = path.relative(scriptDirectory, fakeXCTest);
    const result = spawnSync('/bin/bash', [
      '-c',
      'source ./run-linux-native-tests.sh; run_xctest_case "$1" OpenBurnBarTests/FakeRetryTest',
      'openburnbar-linux-native-test',
      fakeXCTestArgument
    ], {
      cwd: scriptDirectory,
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
