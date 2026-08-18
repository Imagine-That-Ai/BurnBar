import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { validateMobileSchemaBoundary } from './check-mobile-schema-boundary.mjs';
import { decodeGeneratedDocument, fieldsFromGeneratedTs, validateCrossLanguageFixtures } from './check-cross-language-fixtures.mjs';
import { validateMobileGeneratedConsumers } from './check-mobile-generated-consumers.mjs';
import { classifyError, quotaStatus, validateRelayChunks } from './lib/mobile-policy-vectors.mjs';
import { validateMobilePolicyVectors } from './check-mobile-policy-vectors.mjs';

test('repo schema boundary covers live mobile consumers', () => {
  const result = validateMobileSchemaBoundary();
  assert.equal(result.passed, true, result.failures.join('\n'));
});

test('unmapped collection fails', () => {
  const result = validateMobileSchemaBoundary({
    scan: { collections: ['not_a_real_collection'], callables: [] },
    boundary: {
      schemaVersion: 1,
      id: 'openburnbar-mobile-schema-boundary-v1',
      documents: [{
        id: 'doc.usage',
        collection: 'usage',
        kind: 'typespec',
        domainId: 'usage-quota',
        owner: 'mobile-apps'
      }],
      callables: [{ id: 'call.x', name: 'noop', kind: 'typespec', domainId: 'usage-quota', owner: 'x' }]
    },
    manifest: { domains: [{ id: 'usage-quota' }] }
  });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /unmapped: not_a_real_collection/);
});

test('legacy document without removal condition fails', () => {
  const result = validateMobileSchemaBoundary({
    scan: { collections: ['usage'], callables: [] },
    boundary: {
      schemaVersion: 1,
      id: 'openburnbar-mobile-schema-boundary-v1',
      documents: [{
        id: 'doc.usage',
        collection: 'usage',
        kind: 'legacy-boundary',
        legacyId: 'legacy.x',
        owner: 'mobile-apps'
      }],
      callables: [{ id: 'call.x', name: 'noop', kind: 'typespec', domainId: 'usage-quota', owner: 'x' }]
    },
    manifest: { domains: [{ id: 'usage-quota' }] }
  });
  assert.match(result.failures.join('\n'), /removalCondition/);
});

test('repo cross-language fixtures pass and field rename fails closed', () => {
  const result = validateCrossLanguageFixtures();
  assert.equal(result.passed, true, result.failures.join('\n'));
});

test('malformed usage fixture fails closed', () => {
  const source = fs.readFileSync(
    new URL('../../functions/src/types/generated/usage-quota.ts', import.meta.url),
    'utf8'
  );
  const fields = fieldsFromGeneratedTs(source, 'UsageEventDoc');
  const missing = decodeGeneratedDocument(fields, { recordedAt: '2026-08-17T12:00:00.000Z' });
  assert.equal(missing.ok, false);
  const wrongType = decodeGeneratedDocument(fields, {
    provider: 'openai',
    recordedAt: '2026-08-17T12:00:00.000Z',
    costUSD: 'nope'
  });
  assert.equal(wrongType.ok, false);
});

test('generated consumer check fails on unknown Firestore type', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-gen-consumer-'));
  const file = path.join(root, 'OpenBurnBarMobile/Fake.swift');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, 'import OpenBurnBarFirestoreModels\nlet x: FirestoreNotARealDoc\n');
  const result = validateMobileGeneratedConsumers({
    repoRoot: root,
    files: [file],
    mappedCollections: [],
    contracts: { swiftTypes: new Map(), kotlinTypes: new Map(), tsTypes: new Map() }
  });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /FirestoreNotARealDoc/);
});

test('hand decoder of a mapped collection fails closed', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-gen-hand-'));
  const file = path.join(root, 'OpenBurnBarMobile/HandUsageDecoder.swift');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(
    file,
    'let col = collection("usage")\nlet decoded = try decoder.decode(UsageEventDoc.self, from: data)\n'
  );
  const result = validateMobileGeneratedConsumers({
    repoRoot: root,
    files: [file],
    mappedCollections: [{ collection: 'usage', generatedType: 'UsageEventDoc' }],
    contracts: { swiftTypes: new Map(), kotlinTypes: new Map(), tsTypes: new Map() }
  });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /hand type UsageEventDoc/);
});

test('policy vectors pin fail-closed quota, chunks, and errors', () => {
  assert.equal(quotaStatus(null, null).failClosed, true);
  assert.equal(validateRelayChunks([0, 2], 3), false);
  assert.equal(validateRelayChunks([-1], 1), false);
  assert.equal(classifyError('permission-denied'), 'denied');
  const result = validateMobilePolicyVectors();
  assert.equal(result.passed, true, result.failures.join('\n'));
});
