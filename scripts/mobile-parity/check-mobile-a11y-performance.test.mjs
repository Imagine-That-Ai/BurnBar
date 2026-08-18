import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  A11Y_POLICY_PATH,
  A11Y_VECTORS_PATH,
  validateMobileA11yPerformance
} from './check-mobile-a11y-performance.mjs';

test('repo a11y and performance policy pass', () => {
  const result = validateMobileA11yPerformance();
  assert.equal(result.passed, true, result.failures.join('\n'));
  assert.ok(result.ids.includes('a11y.hero-burn.currency'));
  assert.ok(result.ids.includes('a11y.stop-streaming'));
  assert.ok(result.ids.includes('a11y.inbox-row-unread'));
});

test('missing a11y label fails the vector check', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-a11y-'));
  fs.mkdirSync(path.join(root, 'docs/mobile-parity/fixtures/product'), { recursive: true });
  fs.writeFileSync(path.join(root, A11Y_POLICY_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-a11y-performance-policy-v1',
    productParityClaim: false,
    contrast: { minimumNormalText: 4.5, minimumLargeText: 3.0 },
    touchTarget: { minimumPt: 44, minimumDp: 48 },
    performance: {
      pulseWindowMetrics: { complexity: 'O(n)' },
      backgroundRetry: { unbounded: false }
    },
    manualEvidence: { voiceOver: 'blocked', talkBack: 'blocked' }
  }));
  fs.writeFileSync(path.join(root, A11Y_VECTORS_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-a11y-contract-vectors-v1',
    vectors: [{
      id: 'a11y.hero-burn.currency',
      kind: 'heroBurn',
      expected: {}
    }]
  }));
  const result = validateMobileA11yPerformance({
    repoRoot: root,
    swiftFiles: [],
    kotlinFiles: []
  });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /must pin expected.label/);
});

test('TalkBack PASS is rejected', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-a11y-'));
  fs.mkdirSync(path.join(root, 'docs/mobile-parity/fixtures/product'), { recursive: true });
  fs.writeFileSync(path.join(root, A11Y_POLICY_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-a11y-performance-policy-v1',
    productParityClaim: false,
    contrast: { minimumNormalText: 4.5 },
    touchTarget: { minimumPt: 44, minimumDp: 48 },
    performance: {
      pulseWindowMetrics: { complexity: 'O(n)' },
      backgroundRetry: { unbounded: false }
    },
    manualEvidence: { voiceOver: 'blocked', talkBack: 'PASS' }
  }));
  fs.writeFileSync(path.join(root, A11Y_VECTORS_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-a11y-contract-vectors-v1',
    vectors: []
  }));
  const result = validateMobileA11yPerformance({ repoRoot: root, swiftFiles: [], kotlinFiles: [] });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /VoiceOver\/TalkBack cannot be claimed PASS/);
});

test('contrast floor below 4.5 is rejected', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-a11y-'));
  fs.mkdirSync(path.join(root, 'docs/mobile-parity/fixtures/product'), { recursive: true });
  fs.writeFileSync(path.join(root, A11Y_POLICY_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-a11y-performance-policy-v1',
    productParityClaim: false,
    contrast: { minimumNormalText: 3.0 },
    touchTarget: { minimumPt: 44, minimumDp: 48 },
    performance: { pulseWindowMetrics: { complexity: 'O(n)' }, backgroundRetry: { unbounded: false } },
    manualEvidence: { voiceOver: 'blocked', talkBack: 'blocked' }
  }));
  fs.writeFileSync(path.join(root, A11Y_VECTORS_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-a11y-contract-vectors-v1',
    vectors: []
  }));
  const result = validateMobileA11yPerformance({ repoRoot: root, swiftFiles: [], kotlinFiles: [] });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /contrast floor/);
});

test('fixed-dp fontSize on a primary surface is rejected', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-a11y-'));
  fs.mkdirSync(path.join(root, 'docs/mobile-parity/fixtures/product'), { recursive: true });
  fs.mkdirSync(path.join(root, 'android/app/src/main/java/com/openburnbar/ui/pulse'), { recursive: true });
  fs.writeFileSync(path.join(root, A11Y_POLICY_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-a11y-performance-policy-v1',
    productParityClaim: false,
    contrast: { minimumNormalText: 4.5 },
    touchTarget: { minimumPt: 44, minimumDp: 48 },
    performance: { pulseWindowMetrics: { complexity: 'O(n)' }, backgroundRetry: { unbounded: false } },
    manualEvidence: { voiceOver: 'blocked', talkBack: 'blocked' }
  }));
  fs.writeFileSync(path.join(root, A11Y_VECTORS_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-a11y-contract-vectors-v1',
    vectors: [{ id: 'a11y.hero-burn.currency', kind: 'heroBurn', expected: { label: 'x' } }]
  }));
  fs.writeFileSync(
    path.join(root, 'android/app/src/main/java/com/openburnbar/ui/pulse/Bad.kt'),
    'Text(fontSize = 12.dp)\n'
  );
  const result = validateMobileA11yPerformance({
    repoRoot: root,
    swiftFiles: [path.join(root, 's.swift')],
    kotlinFiles: [path.join(root, 'k.kt')],
    androidSurfaces: ['android/app/src/main/java/com/openburnbar/ui/pulse']
  });
  fs.writeFileSync(path.join(root, 's.swift'), 'a11y.hero-burn.currency');
  fs.writeFileSync(path.join(root, 'k.kt'), 'a11y.hero-burn.currency');
  const result2 = validateMobileA11yPerformance({
    repoRoot: root,
    swiftFiles: ['s.swift'],
    kotlinFiles: ['k.kt'],
    androidSurfaces: ['android/app/src/main/java/com/openburnbar/ui/pulse']
  });
  assert.equal(result2.passed, false);
  assert.match(result2.failures.join('\n'), /fixed-dp fontSize/);
});

test('manual VoiceOver PASS is rejected', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-a11y-'));
  fs.mkdirSync(path.join(root, 'docs/mobile-parity/fixtures/product'), { recursive: true });
  fs.writeFileSync(path.join(root, A11Y_POLICY_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-a11y-performance-policy-v1',
    productParityClaim: false,
    contrast: { minimumNormalText: 4.5 },
    touchTarget: { minimumPt: 44, minimumDp: 48 },
    performance: {
      pulseWindowMetrics: { complexity: 'O(n)' },
      backgroundRetry: { unbounded: false }
    },
    manualEvidence: { voiceOver: 'PASS', talkBack: 'blocked' }
  }));
  fs.writeFileSync(path.join(root, A11Y_VECTORS_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-a11y-contract-vectors-v1',
    vectors: []
  }));
  const result = validateMobileA11yPerformance({
    repoRoot: root,
    swiftFiles: [],
    kotlinFiles: []
  });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /VoiceOver\/TalkBack cannot be claimed PASS/);
});
