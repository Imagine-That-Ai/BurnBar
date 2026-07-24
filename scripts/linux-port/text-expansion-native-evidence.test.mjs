import assert from 'node:assert/strict';
import test from 'node:test';
import {
  TEXT_EXPANSION_NATIVE_CLASS,
  TEXT_EXPANSION_NATIVE_SOURCE,
  TEXT_EXPANSION_NATIVE_TEST,
  deriveTextExpansionNativeEvidence
} from './text-expansion-native-evidence.mjs';

const passingCase = (body = '') => `<?xml version="1.0" encoding="UTF-8"?>
<testsuite>
  <testcase classname="${TEXT_EXPANSION_NATIVE_CLASS}" name="${TEXT_EXPANSION_NATIVE_TEST}" time="0.025">${body}</testcase>
</testsuite>
`;

test('derives a passing native restart receipt from the exact daemon test case', () => {
  const evidence = deriveTextExpansionNativeEvidence(passingCase());

  assert.equal(evidence.schemaVersion, 1);
  assert.equal(evidence.type, 'openburnbar.linux.text-expansion-native-persistence');
  assert.equal(evidence.source, TEXT_EXPANSION_NATIVE_SOURCE);
  assert.equal(evidence.passed, true);
  assert.equal(evidence.matchedTestCases, 1);
  assert.deepEqual(evidence.test, {
    className: TEXT_EXPANSION_NATIVE_CLASS,
    name: TEXT_EXPANSION_NATIVE_TEST,
    status: 'passed',
    failureMarkers: []
  });
});

test('rejects missing, failed, skipped, and ambiguous native restart receipts', () => {
  const missing = deriveTextExpansionNativeEvidence('<testsuite />');
  assert.equal(missing.passed, false);
  assert.equal(missing.test.status, 'missing');

  const failed = deriveTextExpansionNativeEvidence(passingCase('<failure message="assertion failed" />'));
  assert.equal(failed.passed, false);
  assert.deepEqual(failed.test.failureMarkers, ['failure']);
  assert.equal(failed.test.status, 'failed');

  const skipped = deriveTextExpansionNativeEvidence(passingCase('<skipped />'));
  assert.equal(skipped.passed, false);
  assert.deepEqual(skipped.test.failureMarkers, ['skipped']);
  assert.equal(skipped.test.status, 'failed');

  const ambiguous = deriveTextExpansionNativeEvidence(`${passingCase()}${passingCase()}`);
  assert.equal(ambiguous.passed, false);
  assert.equal(ambiguous.matchedTestCases, 2);
  assert.equal(ambiguous.test.status, 'ambiguous');
});
