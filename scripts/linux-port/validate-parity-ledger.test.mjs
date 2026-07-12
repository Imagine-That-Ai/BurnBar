import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  PRODUCT_EVIDENCE_POLICY_ID,
  PRODUCT_REQUIREMENTS_SHA256,
  validateParityLedger
} from './lib/parity-ledger-validate.mjs';

const HEAD = '0123456789abcdef0123456789abcdef01234567';
const CANDIDATE = Object.freeze({
  runId: '12345',
  artifactDigest: `sha256:${'a'.repeat(64)}`,
  productProofClosureSha256: '0'.repeat(64)
});

function requirements(ids = ['P-01'], environments = ['test-linux']) {
  return {
    schemaVersion: 1,
    id: 'openburnbar-linux-macos-parity-v1',
    requirements: ids.map((id) => ({
      id,
      area: 'test',
      priority: 'Critical',
      minimumEvidenceTier: 'A'
    })),
    minimumSupportMatrix: environments.map((id) => ({ id }))
  };
}

function evidencePolicies(ids = ['P-01'], environments = ['test-linux']) {
  return {
    schemaVersion: 1,
    id: PRODUCT_EVIDENCE_POLICY_ID,
    requirementsManifest: 'docs/linux-port/product-parity-requirements.json',
    policies: ids.map((requirementId) => ({
      requirementId,
      policyVersion: 1,
      requiredCheckIds: [`${requirementId.toLowerCase()}.test`],
      requiredEnvironmentIds: environments,
      allowedArtifactRoots: [`docs/linux-port/evidence/product-parity-inputs/${requirementId}`],
      minArtifactCount: 1,
      registeredProducer: {
        id: 'openburnbar-linux-product-validator',
        version: 1,
        commandTemplate: `node scripts/linux-port/run-product-requirement-validator.mjs --requirement ${requirementId} --environment {environment} --release-closure docs/linux-port/evidence/product-parity-inputs/${requirementId}/{environment}/release-closure.json --output docs/linux-port/evidence/validator-receipts/${requirementId}/{checkId}/{environment}.json`,
        sourcePaths: [
          'scripts/linux-port/run-product-requirement-validator.mjs',
          `scripts/linux-port/product-validators/${requirementId}.mjs`
        ],
        repository: 'Imagine-That-Ai/BurnBar',
        signerWorkflow: 'github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-product-parity.yml'
      },
      requiredSubjectFields: [
        'releaseClosureSha256',
        'packageManifestSha256',
        'installedEnvironmentSha256',
        'runtimeManifestSha256'
      ]
    }))
  };
}

function row(id = 'P-01', overrides = {}) {
  return {
    id,
    requirementId: id,
    tier: 'A',
    status: 'blocked',
    scope: 'product-parity',
    evidencePath: `docs/linux-port/evidence/product-parity/${id}.json`,
    command: `node scripts/linux-port/attest-product-requirement.mjs --requirement ${id}`,
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
    evidencePolicyManifest: 'docs/linux-port/product-parity-evidence-policies.json',
    semantics: { productParityClaim: false },
    rows,
    environmentCoverage: [{
      id: 'test-linux',
      status: 'blocked',
      evidencePath: 'docs/linux-port/evidence/environments/test-linux.json'
    }],
    ...overrides
  };
}

function repo() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-ledger-'));
  fs.mkdirSync(path.join(root, 'docs/linux-port'), { recursive: true });
  fs.mkdirSync(path.join(root, 'scripts/linux-port'), { recursive: true });
  fs.writeFileSync(path.join(root, 'scripts/linux-port/attest-product-requirement.mjs'), '#!/usr/bin/env node\n');
  fs.chmodSync(path.join(root, 'scripts/linux-port/attest-product-requirement.mjs'), 0o755);
  fs.writeFileSync(path.join(root, 'docs/linux-port/parity-ledger.json'), '{}\n');
  return root;
}

function writeReadyEvidence(repoRoot, targetRow, options = {}) {
  const artifactRel = `docs/linux-port/evidence/product-parity-inputs/${targetRow.id}/proof.txt`;
  const artifactPath = path.join(repoRoot, artifactRel);
  fs.mkdirSync(path.dirname(artifactPath), { recursive: true });
  fs.writeFileSync(artifactPath, options.artifact ?? `proof for ${targetRow.id}\n`);
  const digest = crypto.createHash('sha256').update(fs.readFileSync(artifactPath)).digest('hex');
  const candidate = options.candidate ?? { ...CANDIDATE, productProofClosureSha256: options.sha256 ?? digest };
  const checkId = `${targetRow.id.toLowerCase()}.test`;
  const environmentId = options.environmentId ?? 'test-linux';
  const receiptRel = `docs/linux-port/evidence/validator-receipts/${targetRow.id}/${checkId}/${environmentId}.json`;
  const receiptPath = path.join(repoRoot, receiptRel);
  fs.mkdirSync(path.dirname(receiptPath), { recursive: true });
  fs.writeFileSync(receiptPath, `${JSON.stringify({
    schemaVersion: 2,
    requirementId: targetRow.requirementId,
    checkId,
    environmentId,
    targetHead: options.targetHead ?? HEAD,
    status: 'passed',
    candidate,
    subject: {
      releaseClosureSha256: options.sha256 ?? digest,
      packageManifestSha256: options.sha256 ?? digest,
      installedEnvironmentSha256: options.sha256 ?? digest,
      runtimeManifestSha256: options.sha256 ?? digest
    },
    producer: {
      id: 'openburnbar-linux-product-validator',
      version: 1,
      command: `node scripts/linux-port/run-product-requirement-validator.mjs --requirement ${targetRow.requirementId} --environment ${environmentId} --release-closure docs/linux-port/evidence/product-parity-inputs/${targetRow.requirementId}/${environmentId}/release-closure.json --output ${receiptRel}`,
      sourceTree: options.targetHead ?? HEAD,
      repository: 'Imagine-That-Ai/BurnBar',
      workflow: 'github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-product-parity.yml',
      sourceRef: 'refs/heads/test'
    },
    artifacts: [{ path: artifactRel, sha256: options.sha256 ?? digest }]
  }, null, 2)}\n`);
  const bundleRel = `${receiptRel}.sigstore.jsonl`;
  fs.writeFileSync(path.join(repoRoot, bundleRel), '{"testBundle":true}\n');
  const bundleDigest = crypto.createHash('sha256').update(fs.readFileSync(path.join(repoRoot, bundleRel))).digest('hex');
  const receiptDigest = crypto.createHash('sha256').update(fs.readFileSync(receiptPath)).digest('hex');
  const evidencePath = path.join(repoRoot, targetRow.evidencePath);
  fs.mkdirSync(path.dirname(evidencePath), { recursive: true });
  fs.writeFileSync(evidencePath, `${JSON.stringify({
    schemaVersion: 1,
    rowId: targetRow.id,
    requirementId: targetRow.requirementId,
    targetHead: options.targetHead ?? HEAD,
    status: 'passed',
    candidate,
    policy: {
      manifest: 'docs/linux-port/product-parity-evidence-policies.json',
      manifestId: PRODUCT_EVIDENCE_POLICY_ID,
      policyVersion: 1
    },
    checks: [checkId],
    environments: [environmentId],
    validatorReceipts: [{
      path: receiptRel,
      sha256: receiptDigest,
      checkId,
      environmentId,
      candidate,
      subject: {
        releaseClosureSha256: options.sha256 ?? digest,
        packageManifestSha256: options.sha256 ?? digest,
        installedEnvironmentSha256: options.sha256 ?? digest,
        runtimeManifestSha256: options.sha256 ?? digest
      },
      producer: {
        id: 'openburnbar-linux-product-validator',
        version: 1,
        command: `node scripts/linux-port/run-product-requirement-validator.mjs --requirement ${targetRow.requirementId} --environment ${environmentId} --release-closure docs/linux-port/evidence/product-parity-inputs/${targetRow.requirementId}/${environmentId}/release-closure.json --output ${receiptRel}`,
        sourceTree: options.targetHead ?? HEAD,
        repository: 'Imagine-That-Ai/BurnBar',
        workflow: 'github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-product-parity.yml',
        sourceRef: 'refs/heads/test'
      },
      provenance: {
        bundlePath: bundleRel,
        bundleSha256: bundleDigest
      }
    }],
    artifacts: [{ path: artifactRel, sha256: options.sha256 ?? digest }]
  }, null, 2)}\n`);
  return artifactPath;
}

function writeReadyEnvironmentEvidence(repoRoot, environmentId = 'test-linux') {
  const artifactRel = `docs/linux-port/evidence/environments/${environmentId}/proof.txt`;
  const artifactPath = path.join(repoRoot, artifactRel);
  fs.mkdirSync(path.dirname(artifactPath), { recursive: true });
  fs.writeFileSync(artifactPath, `environment proof for ${environmentId}\n`);
  const digest = crypto.createHash('sha256').update(fs.readFileSync(artifactPath)).digest('hex');
  const evidencePath = `docs/linux-port/evidence/environments/${environmentId}.json`;
  fs.writeFileSync(path.join(repoRoot, evidencePath), `${JSON.stringify({
    schemaVersion: 1,
    environmentId,
    targetHead: HEAD,
    status: 'passed',
    artifacts: [{ path: artifactRel, sha256: digest }]
  }, null, 2)}\n`);
  return { id: environmentId, status: 'ready', evidencePath };
}

function validate(
  value,
  repoRoot,
  catalog = requirements(),
  allowBlocked = false,
  policies = evidencePolicies(
    catalog.requirements.map((requirement) => requirement.id),
    catalog.minimumSupportMatrix.map((environment) => environment.id)
  ),
  optionOverrides = {}
) {
  return validateParityLedger(value, {
    allowBlocked,
    currentHead: HEAD,
    repoRoot,
    ledgerPath: 'docs/linux-port/parity-ledger.json',
    requirements: catalog,
    requirementsDigest: PRODUCT_REQUIREMENTS_SHA256,
    evidencePolicies: policies,
    provenanceVerifier: ({ receiptPath }) => ({
      receiptSha256: crypto.createHash('sha256').update(fs.readFileSync(receiptPath)).digest('hex'),
      verifiedAttestationCount: 1
    }),
    ...optionOverrides
  });
}

test('blocked complete inventory is structurally valid but never promotable', () => {
  const result = validate(ledger(), repo(), requirements(), true);
  assert.equal(result.passed, true, JSON.stringify(result.structuralFailures));
  assert.equal(result.structuralPassed, true, JSON.stringify(result.structuralFailures));
  assert.equal(result.promotionPassed, false);
  assert.ok(result.promotionFailures.some((failure) => /P-01 is blocked/.test(failure.message)));
});

test('missing canonical attester is structural red even in diagnostic mode', () => {
  const root = repo();
  fs.unlinkSync(path.join(root, 'scripts/linux-port/attest-product-requirement.mjs'));
  const result = validate(ledger(), root, requirements(), true);
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /attester is missing/.test(failure.message)));
});

test('symlinked canonical attester is structural red even when confined', () => {
  const root = repo();
  const attester = path.join(root, 'scripts/linux-port/attest-product-requirement.mjs');
  const target = path.join(root, 'scripts/linux-port/alternate-attester.mjs');
  fs.unlinkSync(attester);
  fs.writeFileSync(target, '#!/usr/bin/env node\n');
  fs.symlinkSync(target, attester);
  const result = validate(ledger(), root, requirements(), true);
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /symlink/.test(failure.message)));
});

test('non-executable canonical attester is structural red even in diagnostic mode', () => {
  const root = repo();
  fs.chmodSync(path.join(root, 'scripts/linux-port/attest-product-requirement.mjs'), 0o644);
  const result = validate(ledger(), root, requirements(), true);
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /attester must be executable/.test(failure.message)));
});

test('noncanonical evidence command is structural red even for blocked rows', () => {
  const result = validate(
    ledger([row('P-01', { command: 'node scripts/linux-port/attest-product-requirement.mjs --requirement P-02' })]),
    repo(),
    requirements(),
    true
  );
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /evidence command must be exactly/.test(failure.message)));
});

test('missing requirement policy is structural red even for blocked rows', () => {
  const result = validate(ledger(), repo(), requirements(), true, evidencePolicies(['P-02']));
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /has no evidence policy/.test(failure.message)));
});

test('requirements manifest byte drift is structural red even when parsed fields look valid', () => {
  const result = validate(
    ledger(),
    repo(),
    requirements(),
    true,
    evidencePolicies(),
    { requirementsDigest: '0'.repeat(64) }
  );
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /digest differs/.test(failure.message)));
});

test('policy cannot add an unregistered check beside the canonical check', () => {
  const policies = evidencePolicies();
  policies.policies[0].requiredCheckIds.push('p-01.unregistered');
  const result = validate(ledger(), repo(), requirements(), true, policies);
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /check ids must be exactly/.test(failure.message)));
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
  fs.mkdirSync(path.join(root, 'docs/linux-port/evidence'), { recursive: true });
  fs.symlinkSync(outside, path.join(root, 'docs/linux-port/evidence/product-parity'));
  const result = validate(ledger(), root, requirements(), true);
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /symlink/.test(failure.message)));
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
  const environment = writeReadyEnvironmentEvidence(root);
  const result = validate(
    ledger([ready], {
      semantics: { productParityClaim: true },
      environmentCoverage: [environment]
    }),
    root,
    requirements(),
    false
  );
  assert.equal(result.structuralPassed, true);
  assert.equal(result.promotionPassed, true);
  assert.equal(result.passed, true);
  assert.deepEqual(result.validatedAttestations, [{
    requirementId: 'P-01',
    path: ready.evidencePath,
    sha256: crypto.createHash('sha256').update(fs.readFileSync(path.join(root, ready.evidencePath))).digest('hex'),
    candidate: { ...CANDIDATE, productProofClosureSha256: crypto.createHash('sha256').update(fs.readFileSync(
      path.join(root, 'docs/linux-port/evidence/product-parity-inputs/P-01/proof.txt')
    )).digest('hex') }
  }]);
});

test('strict validation rejects a product matrix that mixes release candidates', () => {
  const root = repo();
  const first = row('P-01', { status: 'ready' });
  const second = row('P-02', { status: 'ready' });
  writeReadyEvidence(root, first);
  writeReadyEvidence(root, second, {
    candidate: {
      runId: '67890',
      artifactDigest: `sha256:${'b'.repeat(64)}`,
      productProofClosureSha256: crypto.createHash('sha256').update('proof for P-02\n').digest('hex')
    }
  });
  const environment = writeReadyEnvironmentEvidence(root);
  const catalog = requirements(['P-01', 'P-02']);
  const result = validate(
    ledger([first, second], { semantics: { productParityClaim: true }, environmentCoverage: [environment] }),
    root,
    catalog,
    false,
    evidencePolicies(['P-01', 'P-02'])
  );
  assert.equal(result.promotionPassed, false);
  assert.ok(result.promotionFailures.some((failure) => /mix different release candidates/u.test(failure.message)));
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

test('ready evidence cannot traverse an in-repository receipt symlink', () => {
  const root = repo();
  const ready = row('P-01', { status: 'ready' });
  writeReadyEvidence(root, ready);
  const evidence = JSON.parse(fs.readFileSync(path.join(root, ready.evidencePath), 'utf8'));
  const receipt = path.join(root, evidence.validatorReceipts[0].path);
  const target = path.join(root, 'docs/linux-port/evidence/validator-receipts/P-01-target.json');
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(receipt, target);
  fs.rmSync(receipt);
  fs.symlinkSync(target, receipt);
  const result = validate(ledger([ready]), root, requirements(), true);
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /receipt path traverses a symlink/.test(failure.message)));
});

test('ready evidence cannot promote a hand-authored receipt without its signed bundle', () => {
  const root = repo();
  const ready = row('P-01', { status: 'ready' });
  writeReadyEvidence(root, ready);
  const evidence = JSON.parse(fs.readFileSync(path.join(root, ready.evidencePath), 'utf8'));
  fs.rmSync(path.join(root, evidence.validatorReceipts[0].provenance.bundlePath));
  const result = validate(ledger([ready]), root, requirements(), true);
  assert.equal(result.promotionPassed, false);
  assert.ok(result.promotionFailures.some((failure) => /provenance bundle is unavailable/.test(failure.message)));
});

test('hand-authored minimal passed JSON cannot bypass the policy closure', () => {
  const root = repo();
  const ready = row('P-01', { status: 'ready' });
  writeReadyEvidence(root, ready);
  const evidencePath = path.join(root, ready.evidencePath);
  const evidence = JSON.parse(fs.readFileSync(evidencePath, 'utf8'));
  delete evidence.policy;
  delete evidence.checks;
  delete evidence.environments;
  delete evidence.validatorReceipts;
  fs.writeFileSync(evidencePath, `${JSON.stringify(evidence)}\n`);
  const result = validate(
    ledger([ready], { semantics: { productParityClaim: true } }),
    root,
    requirements(),
    true
  );
  assert.equal(result.structuralPassed, false);
  assert.ok(result.structuralFailures.some((failure) => /fields are not canonical/.test(failure.message)));
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
  writeReadyEvidence(root, ready, { environmentId: 'ubuntu' });
  const artifactRel = 'artifacts/environment.txt';
  const artifactPath = path.join(root, artifactRel);
  fs.mkdirSync(path.dirname(artifactPath), { recursive: true });
  fs.writeFileSync(artifactPath, 'environment proof\n');
  const hash = crypto.createHash('sha256').update(fs.readFileSync(artifactPath)).digest('hex');
  const evidenceRel = 'evidence/environment.json';
  fs.mkdirSync(path.join(root, 'evidence'), { recursive: true });
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
