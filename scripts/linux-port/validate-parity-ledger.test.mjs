import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

test('parity ledger rows require evidence paths', () => {
  const row = {
    id: 'VAL-EXAMPLE-001',
    tier: 'A',
    status: 'ready',
    command: 'example',
    platform: 'linux',
    sourceOracle: 'macOS',
    acceptedDivergence: 'none',
    owner: 'release',
    promotionCriterion: 'must pass',
    commit: 'abc',
    environment: 'unit'
  };
  assert.equal(Object.hasOwn(row, 'evidencePath'), false);
});

test('ledger file is machine-readable JSON', () => {
  const root = path.resolve(import.meta.dirname, '../..');
  const ledger = JSON.parse(fs.readFileSync(path.join(root, 'docs/linux-port/parity-ledger.json'), 'utf8'));
  assert.ok(Array.isArray(ledger.rows));
  assert.ok(ledger.rows.length >= 8);
  assert.ok(ledger.rows.some((row) => row.tier === 'A'));
});

test('test harness can create a missing-evidence probe', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-ledger-'));
  fs.writeFileSync(path.join(dir, 'probe.json'), JSON.stringify({ ok: true }));
  assert.equal(fs.existsSync(path.join(dir, 'missing.json')), false);
});
