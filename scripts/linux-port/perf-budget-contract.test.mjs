import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const runner = path.join(root, 'scripts/linux-port/run-perf-budget.mjs');

function writeJSON(directory, name, value) {
  fs.writeFileSync(path.join(directory, name), JSON.stringify(value) + '\n');
}

function fixture() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-perf-budget-'));
  writeJSON(directory, 'linux-desktop-session-report.json', {
    performance: {
      appStartSamples: Array.from({ length: 10 }, (_, index) => 700 + index),
      trayClickOpenSamples: Array.from({ length: 10 }, (_, index) => 80 + index),
      ipcHealthRoundTripSamples: Array.from({ length: 10 }, (_, index) => 90 + index)
    }
  });
  writeJSON(directory, 'packaged-route-session-transcript.json', { routeCount: 19 });
  const routes = Array.from({ length: 19 }, (_, index) => JSON.stringify({
    name: 'route.navigation',
    ms: 10 + index,
    source: `packaged-ui-route-after-paint:route-${index}`
  }));
  fs.writeFileSync(path.join(directory, 'runtime-perf-samples.jsonl'), routes.join('\n') + '\n');
  writeJSON(directory, 'matched-performance-comparison.json', {
    protocolVersion: 'openburnbar-matched-workload-v1',
    profile: 'pr',
    pass: true,
    workloads: [],
    resources: {}
  });
  return directory;
}

function run(directory) {
  return spawnSync(process.execPath, [runner], {
    cwd: root,
    encoding: 'utf8',
    env: { ...process.env, OB_EVIDENCE_OUT: directory }
  });
}

test('repeated native p95 plus matched report passes', () => {
  const directory = fixture();
  try {
    const result = run(directory);
    assert.equal(result.status, 0, result.stderr);
    const report = JSON.parse(fs.readFileSync(path.join(directory, 'perf-budget.json'), 'utf8'));
    assert.equal(report.allPass, true);
    assert.deepEqual(report.verdicts.map((row) => row.sampleCount), [10, 19, 10, 10]);
    assert.ok(report.verdicts.every((row) => row.stats.p95 > row.stats.p50));
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('single-sample native evidence and failed matched evidence fail closed', () => {
  const directory = fixture();
  try {
    const desktop = JSON.parse(fs.readFileSync(path.join(directory, 'linux-desktop-session-report.json'), 'utf8'));
    desktop.performance.appStartSamples = [1];
    writeJSON(directory, 'linux-desktop-session-report.json', desktop);
    const matched = JSON.parse(fs.readFileSync(path.join(directory, 'matched-performance-comparison.json'), 'utf8'));
    matched.pass = false;
    writeJSON(directory, 'matched-performance-comparison.json', matched);
    const result = run(directory);
    assert.equal(result.status, 1);
    const report = JSON.parse(fs.readFileSync(path.join(directory, 'perf-budget.json'), 'utf8'));
    assert.equal(report.allPass, false);
    assert.equal(report.status, 'infra-failed');
    assert.equal(report.failureClass, 'infra');
    assert.equal(report.reasonCode, 'linux-performance-evidence-unavailable');
    assert.ok(report.errors.some((error) => error.includes('app.start has 1 samples')));
    assert.ok(report.errors.some((error) => error.includes('matched macOS/Linux')));
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('pre-paint route sources are rejected', () => {
  const directory = fixture();
  try {
    const samplePath = path.join(directory, 'runtime-perf-samples.jsonl');
    const rows = fs.readFileSync(samplePath, 'utf8').replace('packaged-ui-route-after-paint', 'route-render');
    fs.writeFileSync(samplePath, rows);
    const result = run(directory);
    assert.equal(result.status, 1);
    const report = JSON.parse(fs.readFileSync(path.join(directory, 'perf-budget.json'), 'utf8'));
    assert.equal(report.status, 'infra-failed');
    assert.equal(report.failureClass, 'infra');
    assert.ok(report.errors.some((error) => error.includes('pre-paint')));
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
