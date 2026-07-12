import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { validateParityLedger } from './lib/parity-ledger-validate.mjs';

const HEAD = '0123456789abcdef0123456789abcdef01234567';

function requirements(ids = ['P-01'], environments = []) {
  return {
    schemaVersion: 1,
    id: 'test-requirements',
    requirements: ids.map((id) => ({
      id,
      area: 'test',
      priority: 'Critical',
      minimumEvidenceTier: 'A'
    })),
    minimumSupportMatrix: environments.map((id) => ({ id }))
  };
}

function row(id = 'P-01', overrides = {}) {
  return {
    id,
    requirementId: id,
    tier: 'A',
    status: 'blocked',
    scope: 'product-parity',
    evidencePath: `evidence/${id}.json`,
    command: `attest ${id}`,
    platform: 'Linux',
    sourceOracle: `macOS ${id}`,
    acceptedDivergence: 'None.',
    owner: 'test',
    promotionCriterion: `Prove ${id}`,
    environment: 'test',
    ...overrides
  };
}

function ledger(rows = [row()], overrides = {}) {
  return {
    schemaVersion: 2,
    requirementsManifest: 'docs/linux-port/product-parity-requirements.json',
    semantics: { productParityClaim: false },
    rows,
    environmentCoverage: [],
    ...overrides
  };
}

function repo() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-ledger-'));
  fs.mkdirSync(path.join(root, 'docs/linux-port'), { recursive: true });
  fs.writeFileSync(path.join(root, 'docs/linux-port/parity-ledger.json'), '{}\n');
  return root;
}

function writeReadyEvidence(repoRoot, targetRow, options = {}) {
  const artifactRel = `artifacts/${targetRow.id}.txt`;
  const artifactPath = path.join(repoRoot, artifactRel);
  fs.mkdirSync(path.dirname(artifactPath), { recursive: true });
  fs.writeFileSync(artifactPath, options.artifact ?? `proof for ${targetRow.id}\n`);
  const digest = crypto.createHash('sha256').update(fs.readFileSync(artifactPath)).digest('hex');
  const evidencePath = path.join(repoRoot, targetRow.evidencePath);
  fs.mkdirSync(path.dirname(evidencePath), { recursive: true });
  fs.writeFileSync(evidencePath, `${JSON.stringify({
    schemaVersion: 1,
    rowId: targetRow.id,
    requirementId: targetRow.requirementId,
    targetHead: options.targetHead ?? HEAD,
    status: 'passed',
    artifacts: [{ path: artifactRel, sha256: options.sha256 ?? digest }]
  }, null, 2)}\n`);
  return artifactPath;
}

function validate(value, repoRoot, catalog = requirements(), allowBlocked = false) {
  return validateParityLedger(value, {
    allowBlocked,
    currentHead: HEAD,
    repoRoot,
    ledgerPath: 'docs/linux-port/parity-ledger.json',
    requirements: catalog
  });
}

test('blocked complete inventory is structurally valid but never promotable', () => {
  const result = validate(ledger(), repo(), requirements(), true);
  assert.equal(result.passed, true);
  assert.equal(result.structuralPassed, true);
  assert.equal(result.promotionPassed, false);
  assert.ok(result.promotionFailures.some((failure) => /P-01 is blocked/.test(failure.message)));
});

test('missing catalog row fails structural validation', () => {
  const result = validate(ledger([]), repo(), requirements(), true);
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /P-01 has no ledger row/.test(failure.message)));
});

test('unknown extra product row fails structural validation', () => {
  const result = validate(ledger([row('P-01'), row('P-02')]), repo(), requirements(), true);
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /unknown product parity requirement id: P-02/.test(failure.message)));
});

test('duplicate requirement mapping fails exact one-to-one coverage', () => {
  const duplicate = row('P-01', { id: 'P-01-copy' });
  const result = validate(ledger([row('P-01'), duplicate]), repo(), requirements(), true);
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /expected exactly one/.test(failure.message)));
});

test('historical rows cannot satisfy product coverage', () => {
  const result = validate(ledger([row('P-01', { scope: 'historical-infrastructure' })]), repo(), requirements(), true);
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /scope product-parity/.test(failure.message)));
});

test('lexical path traversal fails even for a blocked row', () => {
  const result = validate(ledger([row('P-01', { evidencePath: '../outside.json' })]), repo(), requirements(), true);
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /escapes the repository/.test(failure.message)));
});

test('symlink escape fails even when the target exists', () => {
  const root = repo();
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-outside-'));
  fs.writeFileSync(path.join(outside, 'P-01.json'), '{}\n');
  fs.symlinkSync(outside, path.join(root, 'evidence'));
  const result = validate(ledger(), root, requirements(), true);
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /through a symlink/.test(failure.message)));
});

test('tracked HEAD fields are forbidden and cannot disable drift checks', () => {
  const result = validate(
    ledger([row('P-01', { staleWhenHeadDiffers: false, commit: HEAD })]),
    repo(),
    requirements(),
    true
  );
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /staleWhenHeadDiffers is forbidden/.test(failure.message)));
});

test('current-HEAD attestation with valid artifact hashes can promote', () => {
  const root = repo();
  const ready = row('P-01', { status: 'ready' });
  writeReadyEvidence(root, ready);
  const result = validate(
    ledger([ready], { semantics: { productParityClaim: true } }),
    root,
    requirements(),
    false
  );
  assert.equal(result.structuralPassed, true);
  assert.equal(result.promotionPassed, true);
  assert.equal(result.passed, true);
});

test('one-byte artifact mutation fails promotion in diagnostic mode', () => {
  const root = repo();
  const ready = row('P-01', { status: 'ready' });
  const artifact = writeReadyEvidence(root, ready);
  fs.appendFileSync(artifact, 'x');
  const result = validate(
    ledger([ready], { semantics: { productParityClaim: false } }),
    root,
    requirements(),
    true
  );
  assert.equal(result.structuralPassed, true);
  assert.equal(result.promotionPassed, false);
  assert.ok(result.promotionFailures.some((failure) => /artifact hash mismatch/.test(failure.message)));
});

test('stale attestation makes claim=true structurally contradictory even in diagnostic mode', () => {
  const root = repo();
  const ready = row('P-01', { status: 'ready' });
  writeReadyEvidence(root, ready, { targetHead: 'old-head' });
  const result = validate(
    ledger([ready], { semantics: { productParityClaim: true } }),
    root,
    requirements(),
    true
  );
  assert.equal(result.passed, false);
  assert.equal(result.structuralPassed, false);
  assert.ok(result.promotionFailures.some((failure) => /differs from current HEAD/.test(failure.message)));
  assert.ok(result.structuralFailures.some((failure) => /contradicts/.test(failure.message)));
});

test('ledger cannot cite itself as evidence', () => {
  const result = validate(
    ledger([row('P-01', { evidencePath: 'docs/linux-port/parity-ledger.json' })]),
    repo(),
    requirements(),
    true
  );
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /self-referential proof/.test(failure.message)));
});

test('structured accepted divergence requires ownership and review fields', () => {
  const result = validate(
    ledger([row('P-01', { acceptedDivergence: { reason: 'native substitute' } })]),
    repo(),
    requirements(),
    true
  );
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /acceptedDivergence.owner is required/.test(failure.message)));
});

test('minimum support environment requires exactly one coverage row', () => {
  const result = validate(ledger(), repo(), requirements(['P-01'], ['ubuntu']), true);
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /ubuntu has no coverage row/.test(failure.message)));
});

test('ready environment evidence must be current-HEAD and artifact-hash bound', () => {
  const root = repo();
  const ready = row('P-01', { status: 'ready' });
  writeReadyEvidence(root, ready);
  const artifactRel = 'artifacts/environment.txt';
  const artifactPath = path.join(root, artifactRel);
  fs.writeFileSync(artifactPath, 'environment proof\n');
  const hash = crypto.createHash('sha256').update(fs.readFileSync(artifactPath)).digest('hex');
  const evidenceRel = 'evidence/environment.json';
  fs.writeFileSync(path.join(root, evidenceRel), `${JSON.stringify({
    schemaVersion: 1,
    environmentId: 'ubuntu',
    targetHead: 'old-head',
    status: 'passed',
    artifacts: [{ path: artifactRel, sha256: hash }]
  })}\n`);
  const value = ledger([ready], {
    semantics: { productParityClaim: true },
    environmentCoverage: [{ id: 'ubuntu', status: 'ready', evidencePath: evidenceRel }]
  });
  const result = validate(value, root, requirements(['P-01'], ['ubuntu']), true);
  assert.equal(result.passed, false);
  assert.ok(result.promotionFailures.some((failure) => /does not match current HEAD/.test(failure.message)));
});
