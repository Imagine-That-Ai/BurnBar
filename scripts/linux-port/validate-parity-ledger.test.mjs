import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { validateParityLedger } from './lib/parity-ledger-validate.mjs';

function tmpEvidence(repoRoot) {
  const rel = 'docs/linux-port/evidence/mission-002-reanchor/README.md';
  const full = path.join(repoRoot, rel);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, 'evidence\n');
  return rel;
}

function baseRow(evidencePath, overrides = {}) {
  return {
    id: 'VAL-TEST-001',
    tier: 'A',
    status: 'ready',
    scope: 'historical-infrastructure',
    staleWhenHeadDiffers: false,
    evidencePath,
    command: 'echo',
    platform: 'test',
    sourceOracle: 'test',
    acceptedDivergence: 'none',
    owner: 'test',
    promotionCriterion: 'test',
    commit: 'abc123',
    environment: 'test',
    ...overrides
  };
}

test('missing evidence fails ready rows', () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-ledger-'));
  const ledger = {
    semantics: { productParityClaim: false },
    git: { commit: 'abc123' },
    rows: [baseRow('missing/path.json')]
  };
  const r = validateParityLedger(ledger, { currentHead: 'abc123', repoRoot, allowBlocked: false });
  assert.equal(r.passed, false);
  assert.ok(r.failures.some((f) => /evidence path does not exist/.test(f.message)));
});

test('bad scope fails', () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-ledger-'));
  const evidencePath = tmpEvidence(repoRoot);
  const ledger = {
    semantics: { productParityClaim: false },
    git: { commit: 'abc123' },
    rows: [baseRow(evidencePath, { scope: 'weird' })]
  };
  const r = validateParityLedger(ledger, { currentHead: 'abc123', repoRoot });
  assert.equal(r.passed, false);
  assert.ok(r.failures.some((f) => /scope must be/.test(f.message)));
});

test('product ready stale head fails strict, warns allow-blocked', () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-ledger-'));
  const evidencePath = tmpEvidence(repoRoot);
  const ledger = {
    semantics: { productParityClaim: false },
    git: { commit: 'abc123' },
    rows: [
      baseRow(evidencePath, {
        id: 'VAL-PROD-1',
        scope: 'product-parity',
        staleWhenHeadDiffers: true,
        evidenceHead: 'oldhead',
        status: 'ready'
      })
    ]
  };
  const strict = validateParityLedger(ledger, {
    currentHead: 'newhead',
    repoRoot,
    allowBlocked: false
  });
  assert.equal(strict.passed, false);
  assert.ok(strict.failures.some((f) => /differs from current HEAD/.test(f.message)));

  const soft = validateParityLedger(ledger, {
    currentHead: 'newhead',
    repoRoot,
    allowBlocked: true
  });
  assert.equal(soft.passed, true);
  assert.ok(soft.warnings.some((w) => /differs from current HEAD/.test(w.message)));
});

test('productParityClaim true with no product rows fails', () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-ledger-'));
  const evidencePath = tmpEvidence(repoRoot);
  const ledger = {
    semantics: { productParityClaim: true },
    git: { commit: 'abc123' },
    rows: [baseRow(evidencePath, { scope: 'historical-infrastructure' })]
  };
  const r = validateParityLedger(ledger, { currentHead: 'abc123', repoRoot });
  assert.equal(r.passed, false);
  assert.ok(r.failures.some((f) => /no product-parity/.test(f.message)));
});

test('ready historical row commit must match ledger git commit', () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-ledger-'));
  const evidencePath = tmpEvidence(repoRoot);
  const ledger = {
    semantics: { productParityClaim: false },
    git: { commit: 'ledger-head' },
    rows: [baseRow(evidencePath, { commit: 'other' })]
  };
  const r = validateParityLedger(ledger, { currentHead: 'ledger-head', repoRoot });
  assert.equal(r.passed, false);
  assert.ok(r.failures.some((f) => /does not match ledger git commit/.test(f.message)));
});

test('self-referential evidence (ledger cites itself) fails strict, warns allow-blocked', () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-ledger-'));
  const ledgerRel = 'docs/linux-port/parity-ledger.json';
  const ledgerFull = path.join(repoRoot, ledgerRel);
  fs.mkdirSync(path.dirname(ledgerFull), { recursive: true });
  fs.writeFileSync(ledgerFull, '{"rows":[]}\n');
  const ledger = {
    semantics: { productParityClaim: false },
    git: { commit: 'abc123' },
    rows: [baseRow(ledgerRel, { id: 'VAL-SELF-001' })]
  };
  const strict = validateParityLedger(ledger, {
    currentHead: 'abc123',
    repoRoot,
    ledgerPath: ledgerRel,
    allowBlocked: false
  });
  assert.equal(strict.passed, false);
  assert.ok(strict.failures.some((f) => /self-referential proof/.test(f.message)));

  const soft = validateParityLedger(ledger, {
    currentHead: 'abc123',
    repoRoot,
    ledgerPath: ledgerRel,
    allowBlocked: true
  });
  assert.ok(soft.warnings.some((w) => /self-referential proof/.test(w.message)));
});

test('ready row whose evidence never names it fails strict, warns allow-blocked', () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-ledger-'));
  const rel = 'docs/linux-port/evidence/mission-002-reanchor/other.json';
  const full = path.join(repoRoot, rel);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, JSON.stringify({ targetStatus: ['VAL-OTHER-999'] }));
  const ledger = {
    semantics: { productParityClaim: false },
    git: { commit: 'abc123' },
    rows: [baseRow(rel, { id: 'VAL-ABSENT-001', status: 'ready' })]
  };
  const strict = validateParityLedger(ledger, {
    currentHead: 'abc123',
    repoRoot,
    allowBlocked: false
  });
  assert.equal(strict.passed, false);
  assert.ok(strict.failures.some((f) => /does not mention row id VAL-ABSENT-001/.test(f.message)));

  const soft = validateParityLedger(ledger, {
    currentHead: 'abc123',
    repoRoot,
    allowBlocked: true
  });
  assert.ok(soft.warnings.some((w) => /does not mention row id VAL-ABSENT-001/.test(w.message)));
});

test('evidence file naming the row passes the id-presence check', () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-ledger-'));
  const rel = 'docs/linux-port/evidence/mission-002-reanchor/named.json';
  const full = path.join(repoRoot, rel);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, JSON.stringify({ targetStatus: ['VAL-NAMED-001'] }));
  const ledger = {
    semantics: { productParityClaim: false },
    git: { commit: 'abc123' },
    rows: [baseRow(rel, { id: 'VAL-NAMED-001', status: 'ready' })]
  };
  const r = validateParityLedger(ledger, { currentHead: 'abc123', repoRoot, allowBlocked: false });
  assert.ok(!r.failures.some((f) => /does not mention row id/.test(f.message)));
  assert.ok(!r.warnings.some((w) => /does not mention row id/.test(w.message)));
});

test('over-shared evidence file warns', () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-ledger-'));
  const rel = 'docs/linux-port/evidence/mission-002-reanchor/shared.json';
  const full = path.join(repoRoot, rel);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  // Name every row so id-presence passes; the point under test is the sharing count.
  const ids = ['VAL-S-1', 'VAL-S-2', 'VAL-S-3', 'VAL-S-4'];
  fs.writeFileSync(full, JSON.stringify({ rows: ids }));
  const ledger = {
    semantics: { productParityClaim: false },
    git: { commit: 'abc123' },
    rows: ids.map((id) => baseRow(rel, { id, status: 'blocked', tier: 'C' }))
  };
  const r = validateParityLedger(ledger, { currentHead: 'abc123', repoRoot, allowBlocked: true });
  assert.ok(r.warnings.some((w) => /shared by 4 rows/.test(w.message)));
});

test('duplicate row id fails', () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-ledger-'));
  const evidencePath = tmpEvidence(repoRoot);
  const ledger = {
    semantics: { productParityClaim: false },
    git: { commit: 'abc123' },
    rows: [baseRow(evidencePath), baseRow(evidencePath)]
  };
  const r = validateParityLedger(ledger, { currentHead: 'abc123', repoRoot });
  assert.equal(r.passed, false);
  assert.ok(r.failures.some((f) => /duplicate row id/.test(f.message)));
});
