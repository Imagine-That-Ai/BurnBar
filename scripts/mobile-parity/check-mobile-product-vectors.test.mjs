import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  PRODUCT_FIXTURES,
  validateMobileProductVectors
} from './check-mobile-product-vectors.mjs';

test('repo product vectors pass and are referenced by both platforms', () => {
  const result = validateMobileProductVectors();
  assert.equal(result.passed, true, result.failures.join('\n'));
  assert.ok(result.ids.includes('pulse.minute-hour-day-windows'));
  assert.ok(result.ids.includes('streams.pagination-boundary'));
  assert.ok(result.ids.includes('inbox.cold-focus-hold'));
  assert.ok(result.ids.includes('hermes.stop-mid-stream'));
  assert.ok(result.ids.includes('mercury.denial-not-connected'));
  assert.ok(result.ids.includes('computeruse.replay-rejected'));
});

test('failed load looking like live zero is rejected', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-product-vectors-'));
  const pulse = {
    schemaVersion: 1,
    id: 'openburnbar-mobile-pulse-burn-vectors-v1',
    sourceOracle: 'PulseWindowMetricBuilder',
    vectors: [{
      id: 'pulse.failed-load-not-live-zero',
      kind: 'loadPresentation',
      failed: true,
      expected: { presentation: 'failed', looksLikeLiveZero: true }
    }]
  };
  const streams = {
    schemaVersion: 1,
    id: 'openburnbar-mobile-streams-inbox-vectors-v1',
    vectors: []
  };
  const hermes = {
    schemaVersion: 1,
    id: 'openburnbar-mobile-hermes-mercury-computer-use-vectors-v1',
    vectors: []
  };
  fs.mkdirSync(path.join(root, 'docs/mobile-parity/fixtures/product'), { recursive: true });
  fs.writeFileSync(path.join(root, PRODUCT_FIXTURES[0]), JSON.stringify(pulse));
  fs.writeFileSync(path.join(root, PRODUCT_FIXTURES[1]), JSON.stringify(streams));
  fs.writeFileSync(path.join(root, PRODUCT_FIXTURES[2]), JSON.stringify(hermes));
  const result = validateMobileProductVectors({
    repoRoot: root,
    swiftFiles: [],
    kotlinFiles: []
  });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /must not look like live zero/);
});

test('missing platform test reference fails', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-product-vectors-'));
  const pulse = {
    schemaVersion: 1,
    id: 'openburnbar-mobile-pulse-burn-vectors-v1',
    sourceOracle: 'PulseWindowMetricBuilder',
    vectors: [{
      id: 'pulse.empty-window',
      kind: 'window',
      expected: { day: { requests: 0, tokens: 0, costUsd: 0 } }
    }]
  };
  const streams = {
    schemaVersion: 1,
    id: 'openburnbar-mobile-streams-inbox-vectors-v1',
    vectors: []
  };
  const hermes = {
    schemaVersion: 1,
    id: 'openburnbar-mobile-hermes-mercury-computer-use-vectors-v1',
    vectors: []
  };
  fs.mkdirSync(path.join(root, 'docs/mobile-parity/fixtures/product'), { recursive: true });
  fs.mkdirSync(path.join(root, 'swift'), { recursive: true });
  fs.mkdirSync(path.join(root, 'kotlin'), { recursive: true });
  fs.writeFileSync(path.join(root, PRODUCT_FIXTURES[0]), JSON.stringify(pulse));
  fs.writeFileSync(path.join(root, PRODUCT_FIXTURES[1]), JSON.stringify(streams));
  fs.writeFileSync(path.join(root, PRODUCT_FIXTURES[2]), JSON.stringify(hermes));
  fs.writeFileSync(path.join(root, 'swift/Test.swift'), 'pulse.empty-window\n');
  fs.writeFileSync(path.join(root, 'kotlin/Test.kt'), 'unrelated\n');
  const result = validateMobileProductVectors({
    repoRoot: root,
    swiftFiles: ['swift/Test.swift'],
    kotlinFiles: ['kotlin/Test.kt']
  });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /no Kotlin test file references vector pulse.empty-window/);
});

test('denial looking connected is rejected', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-product-vectors-'));
  const pulse = {
    schemaVersion: 1,
    id: 'openburnbar-mobile-pulse-burn-vectors-v1',
    sourceOracle: 'PulseWindowMetricBuilder',
    vectors: []
  };
  const streams = {
    schemaVersion: 1,
    id: 'openburnbar-mobile-streams-inbox-vectors-v1',
    vectors: []
  };
  const hermes = {
    schemaVersion: 1,
    id: 'openburnbar-mobile-hermes-mercury-computer-use-vectors-v1',
    vectors: [{
      id: 'mercury.denial-not-connected',
      kind: 'sessionPresentation',
      phase: 'live',
      denied: true,
      expected: { presentation: 'connected' }
    }]
  };
  fs.mkdirSync(path.join(root, 'docs/mobile-parity/fixtures/product'), { recursive: true });
  fs.writeFileSync(path.join(root, PRODUCT_FIXTURES[0]), JSON.stringify(pulse));
  fs.writeFileSync(path.join(root, PRODUCT_FIXTURES[1]), JSON.stringify(streams));
  fs.writeFileSync(path.join(root, PRODUCT_FIXTURES[2]), JSON.stringify(hermes));
  const result = validateMobileProductVectors({
    repoRoot: root,
    swiftFiles: [],
    kotlinFiles: []
  });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /denial must not look connected/);
});
