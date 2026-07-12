import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { parseAttestationArguments } from './attest-product-requirement.mjs';
import {
  attestProductRequirement,
  canonicalValidatorCommand,
  canonicalValidatorReceiptPath,
  POLICY_MANIFEST_ID,
  validatePolicyManifest
} from './lib/product-requirement-attestation.mjs';

const SOURCE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const ENVIRONMENTS = [
  'ubuntu-24.04-gnome-x11-x86_64',
  'ubuntu-24.04-gnome-x11-aarch64',
  'ubuntu-24.04-gnome-wayland-x86_64',
  'ubuntu-24.04-gnome-wayland-aarch64',
  'fedora-kde-wayland-x86_64',
  'fedora-kde-wayland-aarch64',
  'arch-sway-wayland-x86_64'
];
const REQUIREMENT_IDS = Array.from({ length: 40 }, (_, index) => `P-${String(index + 1).padStart(2, '0')}`);
const TARGET = 'P-01';
const TARGET_CHECK = 'p-01.release-integrity';

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function writeJson(root, relative, value) {
  const destination = path.join(root, relative);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, `${JSON.stringify(value, null, 2)}\n`);
}

function git(root, args) {
  const result = spawnSync('git', args, { cwd: root, encoding: 'utf8' });
  assert.equal(result.status, 0, `git ${args.join(' ')}: ${result.stderr}`);
  return result.stdout.trim();
}

function requirements() {
  return JSON.parse(fs.readFileSync(path.join(SOURCE_ROOT, 'docs/linux-port/product-parity-requirements.json'), 'utf8'));
}

function policies() {
  return {
    schemaVersion: 1,
    id: POLICY_MANIFEST_ID,
    requirementsManifest: 'docs/linux-port/product-parity-requirements.json',
    policies: requirements().requirements.map(({ id: requirementId, area }) => ({
      requirementId,
      policyVersion: 1,
      requiredCheckIds: [`${requirementId.toLowerCase()}.${area}`],
      requiredEnvironmentIds: [...ENVIRONMENTS],
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

function ledger() {
  return {
    schemaVersion: 2,
    requirementsManifest: 'docs/linux-port/product-parity-requirements.json',
    evidencePolicyManifest: 'docs/linux-port/product-parity-evidence-policies.json',
    rows: REQUIREMENT_IDS.map((id) => ({
      id,
      requirementId: id,
      evidencePath: `docs/linux-port/evidence/product-parity/${id}.json`,
      command: `node scripts/linux-port/attest-product-requirement.mjs --requirement ${id}`
    }))
  };
}

function refreshReceipts(value, mutate = null) {
  value.head = git(value.root, ['rev-parse', 'HEAD']);
  const digest = sha256(value.artifactAbsolute);
  value.receiptPaths = ENVIRONMENTS.map((environmentId, index) => {
    const relative = canonicalValidatorReceiptPath(TARGET, TARGET_CHECK, environmentId);
    const receipt = {
      schemaVersion: 2,
      requirementId: TARGET,
      checkId: TARGET_CHECK,
      environmentId,
      targetHead: value.head,
      status: 'passed',
      subject: {
        releaseClosureSha256: digest,
        packageManifestSha256: digest,
        installedEnvironmentSha256: digest,
        runtimeManifestSha256: digest
      },
      producer: {
        id: 'openburnbar-linux-product-validator',
        version: 1,
        command: canonicalValidatorCommand(TARGET, TARGET_CHECK, environmentId),
        sourceTree: value.head,
        repository: 'Imagine-That-Ai/BurnBar',
        workflow: 'github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-product-parity.yml',
        sourceRef: 'refs/heads/test'
      },
      artifacts: [{ path: value.artifactRelative, sha256: digest }]
    };
    if (mutate) mutate(receipt, index);
    writeJson(value.root, relative, receipt);
    fs.writeFileSync(path.join(value.root, `${relative}.sigstore.jsonl`), '{"testBundle":true}\n');
    return relative;
  });
}

function verifyFixtureProvenance({ receiptPath }) {
  return {
    receiptSha256: sha256(receiptPath),
    verifiedAttestationCount: 1,
    certificates: []
  };
}

function fixture(options = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-product-attester-'));
  const ignoredEvidence = options.ignoreEvidence !== false
    ? [
        'docs/linux-port/evidence/product-parity/',
        'docs/linux-port/evidence/product-parity-inputs/',
        'docs/linux-port/evidence/validator-receipts/'
      ]
    : [];
  fs.writeFileSync(path.join(root, '.gitignore'), `${ignoredEvidence.join('\n')}\n`);
  const requirementsDestination = path.join(root, 'docs/linux-port/product-parity-requirements.json');
  fs.mkdirSync(path.dirname(requirementsDestination), { recursive: true });
  fs.copyFileSync(path.join(SOURCE_ROOT, 'docs/linux-port/product-parity-requirements.json'), requirementsDestination);
  writeJson(root, 'docs/linux-port/product-parity-evidence-policies.json', policies());
  writeJson(root, 'docs/linux-port/parity-ledger.json', ledger());
  git(root, ['init', '-q']);
  git(root, ['config', 'user.email', 'tests@openburnbar.local']);
  git(root, ['config', 'user.name', 'OpenBurnBar Tests']);
  git(root, ['add', '.']);
  git(root, ['commit', '-qm', 'fixture']);

  const artifactRelative = `docs/linux-port/evidence/product-parity-inputs/${TARGET}/proof.txt`;
  const artifactAbsolute = path.join(root, artifactRelative);
  fs.mkdirSync(path.dirname(artifactAbsolute), { recursive: true });
  fs.writeFileSync(artifactAbsolute, 'installed product behavior proof\n');
  const value = { root, artifactRelative, artifactAbsolute, output: path.join(root, `docs/linux-port/evidence/product-parity/${TARGET}.json`) };
  refreshReceipts(value);
  return value;
}

function invoke(value, overrides = {}) {
  return attestProductRequirement({
    repoRoot: value.root,
    requirementId: TARGET,
    validatorReceiptPaths: value.receiptPaths,
    artifactPaths: [value.artifactRelative],
    provenanceVerifier: verifyFixtureProvenance,
    ...overrides
  });
}

function expectFailure(value, pattern, overrides = {}) {
  fs.mkdirSync(path.dirname(value.output), { recursive: true });
  fs.writeFileSync(value.output, '{"stale":true}\n');
  assert.throws(() => invoke(value, overrides), pattern);
  assert.equal(fs.existsSync(value.output), false, 'failure must remove stale output');
}

test('canonical policy manifest has one nonempty, requirement-specific policy for all 40 requirements', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(SOURCE_ROOT, 'docs/linux-port/product-parity-evidence-policies.json')));
  const catalog = JSON.parse(fs.readFileSync(path.join(SOURCE_ROOT, 'docs/linux-port/product-parity-requirements.json')));
  const validated = validatePolicyManifest(manifest, {
    requirementIds: catalog.requirements.map((entry) => entry.id),
    environmentIds: catalog.minimumSupportMatrix.map((entry) => entry.id),
    areasByRequirement: new Map(catalog.requirements.map((entry) => [entry.id, entry.area]))
  });
  assert.equal(validated.policies.length, 40);
  assert.equal(new Set(validated.policies.flatMap((policy) => policy.requiredCheckIds)).size, 40);
  for (const policy of validated.policies) {
    assert.ok(policy.allowedArtifactRoots.every((root) => root.endsWith(policy.requirementId)));
    assert.deepEqual(policy.requiredEnvironmentIds, ENVIRONMENTS);
  }
});

test('CLI accepts the canonical ledger command and optional exact-set overrides', () => {
  assert.deepEqual(parseAttestationArguments(['--requirement', 'P-01']), {
    requirementId: 'P-01',
    validatorReceiptPaths: [],
    artifactPaths: []
  });
  assert.deepEqual(parseAttestationArguments([
    '--requirement', 'P-01',
    '--validator-receipt', 'receipts/a.json',
    '--artifact', 'artifacts/a.txt'
  ]), {
    requirementId: 'P-01',
    validatorReceiptPaths: ['receipts/a.json'],
    artifactPaths: ['artifacts/a.txt']
  });
  for (const forbidden of ['--status', '--pass', '--passed', '--output']) {
    assert.throws(() => parseAttestationArguments([
      '--requirement', 'P-01', forbidden, 'passed',
      '--validator-receipt', 'receipts/a.json', '--artifact', 'artifacts/a.txt'
    ]), /unknown argument/u);
  }
});

test('generates validator-compatible policy-bound evidence at the exact ledger path', (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const result = invoke(value);
  assert.equal(result.outputPath, `docs/linux-port/evidence/product-parity/${TARGET}.json`);
  assert.deepEqual(JSON.parse(fs.readFileSync(value.output)), result.attestation);
  assert.equal(result.attestation.schemaVersion, 1);
  assert.equal(result.attestation.rowId, TARGET);
  assert.equal(result.attestation.requirementId, TARGET);
  assert.equal(result.attestation.targetHead, value.head);
  assert.equal(result.attestation.status, 'passed');
  assert.equal(result.attestation.policy.manifestId, POLICY_MANIFEST_ID);
  assert.deepEqual(result.attestation.checks, [TARGET_CHECK]);
  assert.deepEqual(result.attestation.environments, ENVIRONMENTS);
  assert.equal(result.attestation.validatorReceipts.length, ENVIRONMENTS.length);
  assert.deepEqual(result.attestation.artifacts, [{ path: value.artifactRelative, sha256: sha256(value.artifactAbsolute) }]);
  assert.deepEqual(fs.readdirSync(path.dirname(value.output)).filter((name) => name.includes('.tmp-')), []);
});

test('canonical ledger command discovers the exact receipt matrix and artifact union', (t) => {
  const value = fixture({ ignoreEvidence: false });
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const result = attestProductRequirement({
    repoRoot: value.root,
    requirementId: TARGET,
    provenanceVerifier: verifyFixtureProvenance
  });
  assert.equal(result.outputPath, `docs/linux-port/evidence/product-parity/${TARGET}.json`);
  assert.deepEqual(result.attestation.validatorReceipts.map((receipt) => receipt.path).sort(), [...value.receiptPaths].sort());
  assert.deepEqual(result.attestation.artifacts, [{
    path: value.artifactRelative,
    sha256: sha256(value.artifactAbsolute)
  }]);
});

test('requires a clean real git HEAD and removes stale output on rejection', (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  fs.writeFileSync(path.join(value.root, 'dirty.txt'), 'dirty\n');
  expectFailure(value, /unexpected untracked files/u);
});

test('rejects reviewed requirements-manifest byte drift even after it is committed', (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const manifest = path.join(value.root, 'docs/linux-port/product-parity-requirements.json');
  fs.appendFileSync(manifest, '\n');
  git(value.root, ['add', 'docs/linux-port/product-parity-requirements.json']);
  git(value.root, ['commit', '-qm', 'mutate requirements bytes']);
  refreshReceipts(value);
  expectFailure(value, /digest differs from the reviewed canonical contract/u);
});

test('failure removes a stale output symlink without touching its target', (t) => {
  const value = fixture();
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-attester-stale-output-'));
  t.after(() => {
    fs.rmSync(value.root, { recursive: true, force: true });
    fs.rmSync(outside, { recursive: true, force: true });
  });
  const target = path.join(outside, 'target.json');
  fs.writeFileSync(target, '{"outside":true}\n');
  fs.mkdirSync(path.dirname(value.output), { recursive: true });
  fs.symlinkSync(target, value.output);
  assert.throws(
    () => invoke(value, { validatorReceiptPaths: value.receiptPaths.slice(0, -1) }),
    /canonical policy matrix paths/u
  );
  assert.equal(fs.existsSync(value.output), false);
  assert.equal(fs.readFileSync(target, 'utf8'), '{"outside":true}\n');
});

test('rejects traversal, symlink escape, duplicate, and missing receipt inputs', (t) => {
  const traversal = fixture();
  const duplicate = fixture();
  const missing = fixture();
  const symlinked = fixture();
  t.after(() => {
    for (const value of [traversal, duplicate, missing, symlinked]) fs.rmSync(value.root, { recursive: true, force: true });
  });
  expectFailure(traversal, /canonical policy matrix paths/u, { validatorReceiptPaths: ['../receipt.json'] });
  expectFailure(duplicate, /duplicate/u, { validatorReceiptPaths: [duplicate.receiptPaths[0], duplicate.receiptPaths[0]] });
  expectFailure(missing, /canonical policy matrix paths/u, { validatorReceiptPaths: missing.receiptPaths.slice(0, -1) });
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-attester-outside-'));
  t.after(() => fs.rmSync(outside, { recursive: true, force: true }));
  fs.writeFileSync(path.join(outside, 'receipt.json'), '{}\n');
  const linked = path.join(symlinked.root, symlinked.receiptPaths[0]);
  fs.rmSync(linked);
  fs.symlinkSync(path.join(outside, 'receipt.json'), linked);
  expectFailure(symlinked, /symlink/u, {
    validatorReceiptPaths: symlinked.receiptPaths
  });
});

test('rejects unknown checks, wrong environments, failed status, stale HEAD, and extra receipt fields', (t) => {
  const scenarios = [
    ['unknown checkId', (receipt, index) => { if (index === 0) receipt.checkId = 'p-01.unknown'; }],
    ['wrong environmentId', (receipt, index) => { if (index === 0) receipt.environmentId = 'ubuntu-99'; }],
    ['status must be passed', (receipt, index) => { if (index === 0) receipt.status = 'failed'; }],
    ['does not match current HEAD', (receipt, index) => { if (index === 0) receipt.targetHead = '0'.repeat(40); }],
    ['producer binding is invalid', (receipt, index) => { if (index === 0) receipt.producer.command += ' --caller-passed'; }],
    ['not bound to an artifact', (receipt, index) => { if (index === 0) receipt.subject.releaseClosureSha256 = 'f'.repeat(64); }],
    ['fields must be exactly', (receipt, index) => { if (index === 0) receipt.callerPassed = true; }]
  ];
  for (const [pattern, mutate] of scenarios) {
    const value = fixture();
    t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
    refreshReceipts(value, mutate);
    expectFailure(value, new RegExp(pattern, 'u'));
  }
});

test('rejects hand-authored receipts without exact GitHub Artifact Attestation provenance', (t) => {
  const missing = fixture();
  const mismatched = fixture();
  t.after(() => {
    fs.rmSync(missing.root, { recursive: true, force: true });
    fs.rmSync(mismatched.root, { recursive: true, force: true });
  });
  fs.rmSync(path.join(missing.root, `${missing.receiptPaths[0]}.sigstore.jsonl`));
  expectFailure(missing, /provenance .* does not exist/u);
  expectFailure(mismatched, /provenance did not verify the exact receipt bytes/u, {
    provenanceVerifier: () => ({ receiptSha256: '0'.repeat(64), verifiedAttestationCount: 1 })
  });
});

test('rejects missing, mutated, duplicate, extra, traversal, and symlinked artifacts', (t) => {
  const missing = fixture();
  const mutated = fixture();
  const duplicate = fixture();
  const extra = fixture();
  const traversal = fixture();
  const symlinked = fixture();
  t.after(() => {
    for (const value of [missing, mutated, duplicate, extra, traversal, symlinked]) fs.rmSync(value.root, { recursive: true, force: true });
  });
  fs.rmSync(missing.artifactAbsolute);
  expectFailure(missing, /does not exist/u);
  fs.appendFileSync(mutated.artifactAbsolute, 'mutation');
  expectFailure(mutated, /hash mismatch/u);
  expectFailure(duplicate, /explicit artifact paths contains a duplicate/u, {
    artifactPaths: [duplicate.artifactRelative, duplicate.artifactRelative]
  });
  const extraRelative = `docs/linux-port/evidence/product-parity-inputs/${TARGET}/extra.txt`;
  fs.writeFileSync(path.join(extra.root, extraRelative), 'extra\n');
  expectFailure(extra, /does not match receipt artifacts/u, { artifactPaths: [extra.artifactRelative, extraRelative] });
  expectFailure(traversal, /escapes the repository|not canonical/u, { artifactPaths: ['../outside.txt'] });
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-attester-artifact-outside-'));
  t.after(() => fs.rmSync(outside, { recursive: true, force: true }));
  fs.writeFileSync(path.join(outside, 'proof.txt'), 'installed product behavior proof\n');
  fs.rmSync(symlinked.artifactAbsolute);
  fs.symlinkSync(path.join(outside, 'proof.txt'), symlinked.artifactAbsolute);
  expectFailure(symlinked, /symlink/u);
});

test('rejects a non-canonical ledger output path before writing', (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const ledgerPath = path.join(value.root, 'docs/linux-port/parity-ledger.json');
  const content = JSON.parse(fs.readFileSync(ledgerPath));
  content.rows[0].evidencePath = 'docs/linux-port/evidence/product-parity/not-P-01.json';
  writeJson(value.root, 'docs/linux-port/parity-ledger.json', content);
  git(value.root, ['add', 'docs/linux-port/parity-ledger.json']);
  git(value.root, ['commit', '-qm', 'mutate ledger path']);
  refreshReceipts(value);
  expectFailure(value, /evidencePath must be exactly/u);
});

test('rejects ledger policy-manifest drift and non-canonical commands', (t) => {
  for (const scenario of ['policy', 'command']) {
    const value = fixture();
    t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
    const ledgerPath = path.join(value.root, 'docs/linux-port/parity-ledger.json');
    const content = JSON.parse(fs.readFileSync(ledgerPath));
    if (scenario === 'policy') content.evidencePolicyManifest = 'docs/linux-port/other-policy.json';
    else content.rows[0].command = 'node scripts/linux-port/attest-product-requirement.mjs --requirement P-02';
    writeJson(value.root, 'docs/linux-port/parity-ledger.json', content);
    git(value.root, ['add', 'docs/linux-port/parity-ledger.json']);
    git(value.root, ['commit', '-qm', `mutate ledger ${scenario}`]);
    refreshReceipts(value);
    expectFailure(value, scenario === 'policy' ? /evidence policy manifest/u : /ledger command must be exactly/u);
  }
});
