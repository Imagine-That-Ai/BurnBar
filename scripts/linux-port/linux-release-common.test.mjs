import assert from 'node:assert/strict';
import test from 'node:test';
import { runStep } from './lib/linux-release-common.mjs';

test('runStep bounds captured output without changing a successful exit code', () => {
  const step = runStep('node', ['-e', "process.stdout.write('x'.repeat(2 * 1024 * 1024))"], {
    maxBuffer: 4 * 1024 * 1024,
    outputLimitBytes: 1024
  });
  assert.equal(step.exitCode, 0);
  assert.equal(step.stdout.length, 1024);
  assert.equal(step.stdoutTruncated, true);
  assert.equal(step.stdoutBytes, 2 * 1024 * 1024);
  assert.equal(step.stdoutLimitBytes, 1024);
});

test('runStep preserves nonzero exit status and reports bounded stderr', () => {
  const step = runStep('node', ['-e', "process.stderr.write('failure'.repeat(1024 * 1024)); process.exit(7)"], {
    maxBuffer: 4 * 1024 * 1024,
    outputLimitBytes: 2048
  });
  assert.equal(step.exitCode, 7);
  assert.equal(step.stderr.length, 2048);
  assert.equal(step.stderrTruncated, true);
  assert.ok(step.stderrBytes >= 2048);
  assert.equal(step.stderrLimitBytes, 2048);
});

test('runStep surfaces spawn errors instead of silently returning empty stderr', () => {
  const step = runStep('node', ['-e', "process.stdout.write('x'.repeat(2 * 1024 * 1024))"], {
    maxBuffer: 1024,
    outputLimitBytes: 128
  });
  assert.equal(step.exitCode, 1);
  assert.match(step.stderr, /ENOBUFS|maxBuffer/u);
});
