#!/usr/bin/env node
import { fileMentions, isObject, readJson, runCheckCli } from './lib/check-support.mjs';
import { repoRoot } from './lib/repo-root.mjs';

export const OS_MATRIX_PATH = 'docs/mobile-parity/mobile-os-integration-matrix.json';
export const OS_VECTORS_PATH = 'docs/mobile-parity/fixtures/product/os-integration-vectors.json';

export const OS_TEST_FILES = {
  swift: [
    'OpenBurnBarCore/Tests/OpenBurnBarCoreTests/MobileOsIntegrationParityTests.swift'
  ],
  kotlin: [
    'android/app/src/test/java/com/openburnbar/data/policy/MobileOsIntegrationParityTest.kt'
  ]
};

const REQUIRED_FAMILIES = [
  'notification',
  'lifecycle',
  'deep-link',
  'payload',
  'widget',
  'live-activity',
  'durable-ui',
  'background'
];

const DELIVERIES = new Set(['delivered', 'suppressed']);
const DECISIONS = new Set([
  'navigate',
  'ignoreStale',
  'ignoreAccountMismatch',
  'ignoreExpired',
  'ignoreDuplicate',
  'ignoreDenied',
  'ignoreUnknown'
]);

export function validateMobileOsIntegration(options = {}) {
  const failures = [];
  const root = options.repoRoot ?? repoRoot;
  const matrixDoc = readJson(root, options.matrixPath ?? OS_MATRIX_PATH);
  if (matrixDoc.error) return { passed: false, failures: [matrixDoc.error], ids: [] };
  const vectorsDoc = readJson(root, options.vectorsPath ?? OS_VECTORS_PATH);
  if (vectorsDoc.error) return { passed: false, failures: [vectorsDoc.error], ids: [] };

  const matrix = matrixDoc.value;
  const vectors = vectorsDoc.value;
  if (matrix.schemaVersion !== 1) failures.push('os matrix schemaVersion must be 1');
  if (matrix.id !== 'openburnbar-mobile-os-integration-matrix-v1') {
    failures.push('os matrix id must be openburnbar-mobile-os-integration-matrix-v1');
  }
  if (matrix.productParityClaim === true) {
    failures.push('os matrix productParityClaim must stay false');
  }
  if (vectors.id !== 'openburnbar-mobile-os-integration-vectors-v1') {
    failures.push('os vectors id must be openburnbar-mobile-os-integration-vectors-v1');
  }

  const families = new Set();
  const vectorIds = [];
  for (const vector of vectors.vectors ?? []) {
    if (!vector?.id) {
      failures.push('os vector is missing id');
      continue;
    }
    vectorIds.push(vector.id);
    const expected = vector.expected;
    if (!isObject(expected)) {
      failures.push(`${vector.id} must pin expected`);
      continue;
    }
    if (vector.kind === 'notificationDelivery') {
      if (!DELIVERIES.has(expected.delivery)) failures.push(`${vector.id} unknown delivery`);
      if (vector.permissionGranted === false && expected.delivery === 'delivered') {
        failures.push(`${vector.id} denied permission must not be delivered`);
      }
    }
    if (vector.kind === 'navigation') {
      if (!DECISIONS.has(expected.decision)) failures.push(`${vector.id} unknown decision`);
      if (expected.navigates === true && expected.decision !== 'navigate') {
        failures.push(`${vector.id} non-navigate decision cannot navigate`);
      }
    }
    if (vector.kind === 'widgetPrivacy' && expected.isPrivacySafe === true) {
      if (expected.hasRawUid || expected.hasSecret || expected.hasConversationText) {
        failures.push(`${vector.id} forbidden field cannot be privacy-safe`);
      }
    }
  }

  const uniqueVectors = new Set(vectorIds);
  if (uniqueVectors.size !== vectorIds.length) failures.push('os vector ids must be unique');

  const rows = Array.isArray(matrix.rows) ? matrix.rows : [];
  if (rows.length === 0) failures.push('os matrix has no rows');
  const rowIds = new Set();
  for (const row of rows) {
    if (!row?.id) {
      failures.push('os matrix row is missing id');
      continue;
    }
    if (rowIds.has(row.id)) failures.push(`duplicate os matrix row ${row.id}`);
    rowIds.add(row.id);
    families.add(row.family);
    if (row.automatable === true) {
      if (row.status !== 'implemented') {
        failures.push(`${row.id} automatable row must be implemented`);
      }
      const refs = [...(row.vectorIds ?? [])];
      if (refs.length === 0) failures.push(`${row.id} automatable row needs vectorIds`);
      for (const id of refs) {
        if (!uniqueVectors.has(id)) failures.push(`${row.id} unknown vector ${id}`);
      }
    } else if (row.status === 'blocked' && !row.missingPrerequisite) {
      failures.push(`${row.id} blocked row must name the missing prerequisite`);
    }
  }

  for (const family of REQUIRED_FAMILIES) {
    if (!families.has(family)) failures.push(`os matrix missing required family ${family}`);
  }

  const swiftFiles = options.swiftFiles ?? OS_TEST_FILES.swift;
  const kotlinFiles = options.kotlinFiles ?? OS_TEST_FILES.kotlin;
  for (const id of uniqueVectors) {
    const inSwift = swiftFiles.some((file) => fileMentions(root, file, id));
    const inKotlin = kotlinFiles.some((file) => fileMentions(root, file, id));
    if (!inSwift) failures.push(`no Swift test file references vector ${id}`);
    if (!inKotlin) failures.push(`no Kotlin test file references vector ${id}`);
  }

  return { passed: failures.length === 0, failures, ids: [...uniqueVectors] };
}

runCheckCli(
  import.meta.url,
  validateMobileOsIntegration,
  (result) => `mobile os integration ok (${result.ids.length} ids)`
);
