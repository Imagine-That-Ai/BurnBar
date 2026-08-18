import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  OS_MATRIX_PATH,
  OS_VECTORS_PATH,
  validateMobileOsIntegration
} from './check-mobile-os-integration.mjs';

test('repo os integration matrix and vectors pass', () => {
  const result = validateMobileOsIntegration();
  assert.equal(result.passed, true, result.failures.join('\n'));
  assert.ok(result.ids.includes('os.notification.denied-not-delivered'));
  assert.ok(result.ids.includes('os.push.stale-expired-no-navigate'));
});

test('denied permission marked delivered is rejected', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-os-int-'));
  fs.mkdirSync(path.join(root, 'docs/mobile-parity/fixtures/product'), { recursive: true });
  fs.writeFileSync(path.join(root, OS_MATRIX_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-os-integration-matrix-v1',
    productParityClaim: false,
    rows: []
  }));
  fs.writeFileSync(path.join(root, OS_VECTORS_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-os-integration-vectors-v1',
    vectors: [{
      id: 'os.notification.denied-not-delivered',
      kind: 'notificationDelivery',
      permissionGranted: false,
      expected: { delivery: 'delivered', mayDeliver: true }
    }]
  }));
  const result = validateMobileOsIntegration({
    repoRoot: root,
    swiftFiles: [],
    kotlinFiles: []
  });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /must not be delivered/);
});

test('productParityClaim true is rejected', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-os-int-'));
  fs.mkdirSync(path.join(root, 'docs/mobile-parity/fixtures/product'), { recursive: true });
  fs.writeFileSync(path.join(root, OS_VECTORS_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-os-integration-vectors-v1',
    vectors: []
  }));
  fs.writeFileSync(path.join(root, OS_MATRIX_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-os-integration-matrix-v1',
    productParityClaim: true,
    rows: []
  }));
  const result = validateMobileOsIntegration({ repoRoot: root, swiftFiles: [], kotlinFiles: [] });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /productParityClaim must stay false/);
});

test('forbidden widget field cannot be privacy-safe', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-os-int-'));
  fs.mkdirSync(path.join(root, 'docs/mobile-parity/fixtures/product'), { recursive: true });
  fs.writeFileSync(path.join(root, OS_VECTORS_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-os-integration-vectors-v1',
    vectors: [{
      id: 'os.widget.no-raw-uid',
      kind: 'widgetPrivacy',
      expected: { hasRawUid: true, isPrivacySafe: true }
    }]
  }));
  fs.writeFileSync(path.join(root, OS_MATRIX_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-os-integration-matrix-v1',
    productParityClaim: false,
    rows: []
  }));
  const result = validateMobileOsIntegration({ repoRoot: root, swiftFiles: [], kotlinFiles: [] });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /cannot be privacy-safe/);
});

test('missing Kotlin test reference fails', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-os-int-'));
  fs.mkdirSync(path.join(root, 'docs/mobile-parity/fixtures/product'), { recursive: true });
  const vectorId = 'os.notification.granted-may-deliver';
  fs.writeFileSync(path.join(root, OS_VECTORS_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-os-integration-vectors-v1',
    vectors: [{
      id: vectorId,
      kind: 'notificationDelivery',
      permissionGranted: true,
      expected: { delivery: 'delivered', mayDeliver: true }
    }]
  }));
  fs.writeFileSync(path.join(root, OS_MATRIX_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-os-integration-matrix-v1',
    productParityClaim: false,
    rows: [{
      id: 'os.notification.permission-granted',
      family: 'notification',
      automatable: true,
      status: 'implemented',
      vectorIds: [vectorId]
    }]
  }));
  const result = validateMobileOsIntegration({
    repoRoot: root,
    swiftFiles: [path.join(root, 'swift.txt')],
    kotlinFiles: []
  });
  fs.writeFileSync(path.join(root, 'swift.txt'), vectorId);
  const result2 = validateMobileOsIntegration({
    repoRoot: root,
    swiftFiles: ['swift.txt'],
    kotlinFiles: []
  });
  assert.equal(result2.passed, false);
  assert.match(result2.failures.join('\n'), /no Kotlin test file references/);
});

test('missing platform test reference fails', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-os-int-'));
  fs.mkdirSync(path.join(root, 'docs/mobile-parity/fixtures/product'), { recursive: true });
  const vectorId = 'os.notification.granted-may-deliver';
  fs.writeFileSync(path.join(root, OS_VECTORS_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-os-integration-vectors-v1',
    vectors: [{
      id: vectorId,
      kind: 'notificationDelivery',
      permissionGranted: true,
      expected: { delivery: 'delivered', mayDeliver: true }
    }]
  }));
  fs.writeFileSync(path.join(root, OS_MATRIX_PATH), JSON.stringify({
    schemaVersion: 1,
    id: 'openburnbar-mobile-os-integration-matrix-v1',
    productParityClaim: false,
    rows: [{
      id: 'os.notification.permission-granted',
      family: 'notification',
      automatable: true,
      status: 'implemented',
      vectorIds: [vectorId]
    }]
  }));
  const result = validateMobileOsIntegration({
    repoRoot: root,
    swiftFiles: [],
    kotlinFiles: []
  });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /no Swift test file references/);
});
