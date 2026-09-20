import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const runner = path.join(root, 'scripts/linux-port/run-shell-smoke.mjs');

function writeExecutable(directory, name, source) {
  const filePath = path.join(directory, name);
  fs.writeFileSync(filePath, source, { mode: 0o755 });
  fs.chmodSync(filePath, 0o755);
  return filePath;
}

test('failed shell smoke steps leave a redacted machine-readable summary', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-shell-smoke-'));
  const binDirectory = path.join(directory, 'bin');
  const evidenceDirectory = path.join(directory, 'evidence');
  fs.mkdirSync(binDirectory);
  fs.mkdirSync(evidenceDirectory);
  writeExecutable(binDirectory, 'npm', '#!/bin/sh\nprintf "stub npm failure\\n" >&2\nexit 7\n');
  writeExecutable(binDirectory, 'node', '#!/bin/sh\nprintf "stub node success\\n"\nexit 0\n');

  try {
    const result = spawnSync(process.execPath, [runner], {
      cwd: root,
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${binDirectory}:${process.env.PATH ?? ''}`,
        OB_EVIDENCE_OUT: evidenceDirectory,
        OPENBURNBAR_TEST_SECRET: 'must-never-appear-in-evidence',
        CI: 'true',
        RUNNER_OS: 'Linux',
        RUNNER_ARCH: 'ARM64',
        XDG_SESSION_TYPE: 'Wayland',
        XDG_CURRENT_DESKTOP: 'GNOME'
      }
    });
    assert.equal(result.status, 7, `${result.stdout}\n${result.stderr}`);

    const summaryPath = path.join(evidenceDirectory, 'shell-smoke-failure-summary.json');
    assert.ok(fs.existsSync(summaryPath), 'failure summary should be written before exit');
    const summary = JSON.parse(fs.readFileSync(summaryPath, 'utf8'));
    assert.equal(summary.schemaVersion, 1);
    assert.equal(summary.type, 'openburnbar.shell-smoke-failure');
    assert.equal(summary.status, 'infra-failed');
    assert.equal(summary.failureClass, 'infra');
    assert.equal(summary.reasonCode, 'linux-dependency-install-failed');
    assert.equal(summary.failedSteps.length, 3);
    assert.deepEqual(summary.failedSteps.map((step) => step.index), [1, 2, 3]);
    assert.ok(summary.failedSteps.every((step) => (
      step.status === 'failed' &&
      step.exitCode === 7 &&
      step.timed_out === false &&
      typeof step.failureClass === 'string' &&
      typeof step.reasonCode === 'string' &&
      typeof step.command === 'string'
    )));
    assert.deepEqual(
      summary.failedSteps.map((step) => step.reasonCode),
      [
        'linux-dependency-install-failed',
        'linux-shell-tests-failed',
        'linux-shell-build-failed'
      ]
    );
    assert.equal(summary.steps.length, 8);
    const transcript = summary.artifacts.find((artifact) => artifact.name === 'smoke-transcript.txt');
    assert.ok(transcript && transcript.sizeBytes > 0, 'summary should inventory the transcript');
    assert.equal(summary.runtime.platform, process.platform);
    assert.equal(summary.runtime.arch, process.arch);
    assert.equal(summary.runtime.environment.ci, true);
    assert.equal(summary.runtime.environment.runnerOs, 'linux');
    assert.equal(summary.runtime.environment.runnerArch, 'arm64');
    assert.equal(summary.runtime.environment.sessionType, 'wayland');
    assert.equal(summary.runtime.environment.desktop, 'gnome');
    assert.equal(summary.runtime.environment.displayAvailable, false);
    assert.ok(!JSON.stringify(summary).includes('must-never-appear-in-evidence'));
    assert.ok(!summary.artifacts.some((artifact) => artifact.name === 'shell-smoke-failure-summary.json'));
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
