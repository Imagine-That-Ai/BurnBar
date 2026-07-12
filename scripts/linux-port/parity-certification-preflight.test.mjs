import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  PARITY_PREFLIGHT_FILENAME,
  PARITY_PREFLIGHT_ROLE,
  REQUIREMENT_IDS,
  validateParityCertificationPreflight
} from './lib/parity-certification-preflight.mjs';
import { SUPPORT_ENVIRONMENTS } from './lib/product-proof-closure.mjs';
import { captureParityCertificationPreflight } from './capture-parity-certification-preflight.mjs';
import { validateProductRequirement } from './product-validators/P-02.mjs';

const SOURCE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const ENVIRONMENT = SUPPORT_ENVIRONMENTS[0];
const RUN_ID = '12345';
const DIGEST = `sha256:${'b'.repeat(64)}`;
const RELEASE_ONLY = new Set(['P-01', 'P-03', 'P-04', 'P-37']);

function write(root, relativePath, bytes) {
  const absolute = path.join(root, relativePath);
  fs.mkdirSync(path.dirname(absolute), { recursive: true });
  fs.writeFileSync(absolute, bytes);
  return absolute;
}

function writeJson(root, relativePath, value) {
  return write(root, relativePath, `${JSON.stringify(value, null, 2)}\n`);
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function git(root, args) {
  return execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trim();
}

function commandTemplate(requirementId, area) {
  return [
    'node scripts/linux-port/run-product-requirement-validator.mjs',
    `--requirement ${requirementId}`,
    '--environment {environment}',
    `--release-closure docs/linux-port/evidence/product-parity-inputs/${requirementId}/{environment}/release-closure.json`,
    `--output docs/linux-port/evidence/validator-receipts/${requirementId}/{checkId}/{environment}.json`
  ].join(' ');
}

function requirementsManifest() {
  return {
    schemaVersion: 1,
    id: 'openburnbar-linux-macos-parity-v1',
    minimumSupportMatrix: SUPPORT_ENVIRONMENTS.map((id) => ({
      id,
      os: id.startsWith('ubuntu-') ? 'Ubuntu 24.04' : id.startsWith('fedora-') ? 'Fedora' : 'Arch Linux',
      desktop: id.includes('gnome') ? 'GNOME' : id.includes('kde') ? 'KDE Plasma' : 'Sway/wlroots',
      session: id.includes('x11') ? 'X11' : 'Wayland',
      architecture: id.endsWith('aarch64') ? 'aarch64' : 'x86_64'
    })),
    requirements: REQUIREMENT_IDS.map((id) => ({ id, area: `area-${id.slice(2)}` }))
  };
}

function policies(requirements) {
  return {
    schemaVersion: 1,
    id: 'openburnbar-linux-product-parity-evidence-policies-v1',
    requirementsManifest: 'docs/linux-port/product-parity-requirements.json',
    policies: requirements.requirements.map(({ id, area }) => ({
      requirementId: id,
      policyVersion: 1,
      requiredCheckIds: [`${id.toLowerCase()}.${area}`],
      requiredEnvironmentIds: [...SUPPORT_ENVIRONMENTS],
      allowedArtifactRoots: [`docs/linux-port/evidence/product-parity-inputs/${id}`],
      minArtifactCount: 1,
      registeredProducer: {
        id: 'openburnbar-linux-product-validator',
        version: 1,
        commandTemplate: commandTemplate(id, area),
        sourcePaths: [
          'scripts/linux-port/run-product-requirement-validator.mjs',
          `scripts/linux-port/product-validators/${id}.mjs`
        ],
        repository: 'Imagine-That-Ai/BurnBar',
        signerWorkflow: 'github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-product-parity.yml'
      },
      requiredSubjectFields: [
        'releaseClosureSha256', 'packageManifestSha256',
        'installedEnvironmentSha256', 'runtimeManifestSha256'
      ]
    }))
  };
}

function registry(complete) {
  const featureRequirements = complete
    ? REQUIREMENT_IDS.filter((id) => !RELEASE_ONLY.has(id))
    : ['P-02'];
  return {
    schemaVersion: 1,
    id: 'openburnbar-linux-product-feature-proof-registry-v1',
    requirements: featureRequirements.map((requirementId) => ({
      requirementId,
      artifacts: [{
        role: requirementId === 'P-02' ? PARITY_PREFLIGHT_ROLE : `feature.${requirementId.toLowerCase()}-proof`,
        mediaType: 'application/json',
        maxBytes: 1048576
      }]
    }))
  };
}

function createRepository({ complete = true } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-parity-preflight-'));
  git(root, ['init', '-q']);
  git(root, ['config', 'user.name', 'OpenBurnBar Test']);
  git(root, ['config', 'user.email', 'test@openburnbar.invalid']);
  const requirements = requirementsManifest();
  writeJson(root, 'docs/linux-port/product-parity-requirements.json', requirements);
  writeJson(root, 'docs/linux-port/product-parity-evidence-policies.json', policies(requirements));
  writeJson(root, 'docs/linux-port/product-feature-proof-registry.json', registry(complete));
  for (const schema of [
    'schemas/linux-parity-certification-preflight.schema.json',
    'schemas/linux-product-feature-proof-registry.schema.json'
  ]) write(root, schema, fs.readFileSync(path.join(SOURCE_ROOT, schema)));
  const validatorIds = complete ? REQUIREMENT_IDS : ['P-01', 'P-02', 'P-03', 'P-04', 'P-37'];
  for (const requirementId of validatorIds) {
    write(root, `scripts/linux-port/product-validators/${requirementId}.mjs`,
      `import { result, validateRequirementContext } from './lib.mjs';\n`
      + `export async function validateProductRequirement(context) {\n`
      + `  const validated = validateRequirementContext(context, ['feature.${requirementId.toLowerCase()}-proof']);\n`
      + `  if (!validated.proofs.has('feature.${requirementId.toLowerCase()}-proof')) throw new Error('${requirementId} proof is required');\n`
      + `  return result(context, validated.artifacts);\n}\n`);
  }
  write(root, 'scripts/linux-port/run-product-requirement-validator.mjs', 'export const runner = true;\n');
  git(root, ['add', '.']);
  git(root, ['commit', '-qm', 'complete parity inventory']);
  const head = git(root, ['rev-parse', 'HEAD']);
  const inputRelative = `docs/linux-port/evidence/product-parity-inputs/P-02/${ENVIRONMENT}`;
  const inputRoot = path.join(root, inputRelative);
  const aggregate = {
    schemaVersion: 2,
    stage: 'candidate',
    status: 'passed',
    targetHead: head,
    sourceCommit: head,
    version: '1.2.3',
    git: { dirty: false },
    architectures: ['aarch64', 'x86_64'],
    supportEnvironments: [...SUPPORT_ENVIRONMENTS],
    releaseArtifacts: ['appimage', 'daemon', 'deb', 'rpm'].flatMap((type) =>
      ['aarch64', 'x86_64'].map((architecture) => ({
        type,
        architecture,
        artifact: { path: 'unused', sha256: 'a'.repeat(64) },
        detachedSignature: { path: 'unused', sha256: 'a'.repeat(64) },
        sigstore: { path: 'unused', sha256: 'a'.repeat(64) }
      }))
    ),
    packages: ['deb', 'rpm'].flatMap((format) => ['aarch64', 'x86_64'].map((architecture) => ({
      format,
      architecture,
      artifact: { path: 'unused', sha256: 'a'.repeat(64) },
      installedManifest: { path: 'unused', sha256: 'a'.repeat(64) },
      installedManifestSignature: { path: 'unused', sha256: 'a'.repeat(64) }
    }))),
    featureProofRegistry: null,
    proofs: [{ role: 'inventory' }],
    blockers: []
  };
  const registrySidecar = write(
    root,
    `${inputRelative}/.linux-release/sidecars/product-feature-proof-registry.json`,
    fs.readFileSync(path.join(root, 'docs/linux-port/product-feature-proof-registry.json'))
  );
  aggregate.featureProofRegistry = {
    path: 'sidecars/product-feature-proof-registry.json',
    sha256: sha256(registrySidecar),
    size: fs.statSync(registrySidecar).size
  };
  const aggregatePath = writeJson(root, `${inputRelative}/.linux-release/product-proof-closure.json`, aggregate);
  return { root, head, inputRoot, inputRelative, aggregatePath };
}

function capture(subject, overrides = {}) {
  return captureParityCertificationPreflight({
    repoRoot: subject.root,
    inputRoot: subject.inputRoot,
    environmentId: ENVIRONMENT,
    targetHead: subject.head,
    candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST,
    ...overrides
  });
}

function mutateJson(root, relativePath, mutate) {
  const absolute = path.join(root, relativePath);
  const value = JSON.parse(fs.readFileSync(absolute, 'utf8'));
  mutate(value);
  writeJson(root, relativePath, value);
}

function mutateFeatureRegistry(subject, mutate, { syncCandidate = true } = {}) {
  mutateJson(subject.root, 'docs/linux-port/product-feature-proof-registry.json', mutate);
  if (!syncCandidate) return;
  const sidecarRelative = `${subject.inputRelative}/.linux-release/sidecars/product-feature-proof-registry.json`;
  const sidecar = write(
    subject.root,
    sidecarRelative,
    fs.readFileSync(path.join(subject.root, 'docs/linux-port/product-feature-proof-registry.json'))
  );
  mutateJson(subject.root, path.relative(subject.root, subject.aggregatePath), (aggregate) => {
    aggregate.featureProofRegistry = {
      path: 'sidecars/product-feature-proof-registry.json',
      sha256: sha256(sidecar),
      size: fs.statSync(sidecar).size
    };
  });
}

function record(root, relativePath) {
  return { path: relativePath, sha256: sha256(path.join(root, relativePath)) };
}

function validatorContext(subject, captureResult) {
  const materialized = `${subject.inputRelative}/release-subjects/00-feature-parity-certification-preflight-${PARITY_PREFLIGHT_FILENAME}`;
  write(subject.root, materialized, fs.readFileSync(captureResult.output));
  const manifestPath = `${subject.inputRelative}/release-subjects/installed-manifest.json`;
  writeJson(subject.root, manifestPath, {
    gitCommit: subject.head,
    packageArchitecture: 'x86_64',
    packageFormat: 'deb',
    packageVersion: '1.2.3',
    brokerProtocolVersion: 1
  });
  const signaturePath = `${subject.inputRelative}/release-subjects/installed-manifest.json.sig`;
  const packagePath = `${subject.inputRelative}/release-subjects/installed-package.deb`;
  const runtimePath = `${subject.inputRelative}/live-runtime-capabilities.json`;
  const environmentPath = `${subject.inputRelative}/live-environment-manifest.json`;
  const featureClosurePath = `${subject.inputRelative}/feature-proof-closure.json`;
  const registrySidecarPath = `${subject.inputRelative}/.linux-release/sidecars/product-feature-proof-registry.json`;
  write(subject.root, signaturePath, 'signature\n');
  write(subject.root, packagePath, 'package\n');
  writeJson(subject.root, runtimePath, { shellVersion: '1.2.3', daemonVersion: '1.2.3' });
  writeJson(subject.root, environmentPath, {
    environmentId: ENVIRONMENT,
    targetHead: subject.head,
    architecture: 'x86_64',
    passed: true
  });
  writeJson(subject.root, featureClosurePath, { status: 'collected' });
  write(subject.root, registrySidecarPath, fs.readFileSync(path.join(subject.root, 'docs/linux-port/product-feature-proof-registry.json')));
  const proofs = [
    { role: 'aggregate-product-proof-closure', ...record(subject.root, path.relative(subject.root, subject.aggregatePath)) },
    { role: 'feature-proof-closure', ...record(subject.root, featureClosurePath) },
    { role: 'feature-proof-registry', ...record(subject.root, registrySidecarPath) },
    {
      role: PARITY_PREFLIGHT_ROLE,
      mediaType: 'application/json',
      evidenceClass: 'feature',
      ...record(subject.root, materialized)
    }
  ];
  const closurePath = `${subject.inputRelative}/release-closure.json`;
  const closure = {
    schemaVersion: 3,
    targetHead: subject.head,
    sourceCommit: subject.head,
    status: 'passed',
    requirementId: 'P-02',
    environmentId: ENVIRONMENT,
    version: '1.2.3',
    architectures: ['aarch64', 'x86_64'],
    supportEnvironments: [...SUPPORT_ENVIRONMENTS],
    selectedPackage: { architecture: 'x86_64', format: 'deb' },
    candidate: captureResult.document.candidate,
    packageManifestSignature: record(subject.root, signaturePath),
    proofs,
    blockers: []
  };
  writeJson(subject.root, closurePath, closure);
  return {
    schemaVersion: 1,
    repoRoot: subject.root,
    requirementId: 'P-02',
    checkId: 'p-02.parity-certification',
    environmentId: ENVIRONMENT,
    targetHead: subject.head,
    releaseClosure: { path: closurePath, sha256: sha256(path.join(subject.root, closurePath)), document: closure },
    subjects: {
      release: record(subject.root, closurePath),
      packageManifest: record(subject.root, manifestPath),
      packageManifestSignature: record(subject.root, signaturePath),
      packages: [record(subject.root, packagePath)],
      features: [record(subject.root, materialized)],
      runtimes: [record(subject.root, runtimePath)],
      installation: [],
      environment: record(subject.root, environmentPath)
    }
  };
}

test('complete isolated inventory captures candidate-bound semantic evidence and P-02 validates it', async (t) => {
  const subject = createRepository();
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  const captured = capture(subject);
  assert.equal(captured.document.status, 'passed');
  assert.deepEqual(captured.document.summary, {
    requirementCount: 40,
    policyCount: 40,
    environmentCount: 7,
    validatorCount: 40,
    captureCount: 40,
    materializerCount: 40,
    readyCount: 40,
    blockerCount: 0
  });
  assert.equal(captured.document.requirements.map((row) => row.requirementId).join(','), REQUIREMENT_IDS.join(','));
  const registration = JSON.parse(fs.readFileSync(captured.registration, 'utf8'));
  assert.deepEqual(registration.artifacts, [{
    role: PARITY_PREFLIGHT_ROLE,
    path: `feature-artifacts/${PARITY_PREFLIGHT_FILENAME}`
  }]);
  const result = await validateProductRequirement(validatorContext(subject, captured));
  assert.equal(result.status, 'passed');
  assert.ok(result.artifacts.some((artifact) => artifact.path.includes(PARITY_PREFLIGHT_FILENAME)));
});

test('current implementation inventory truthfully blocks exactly the 35 unimplemented requirement lanes', async (t) => {
  const subject = createRepository({ complete: false });
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  const captured = capture(subject);
  assert.equal(captured.document.status, 'blocked');
  assert.equal(captured.document.summary.validatorCount, 5);
  assert.equal(captured.document.summary.captureCount, 5);
  assert.equal(captured.document.summary.materializerCount, 5);
  assert.equal(captured.document.summary.readyCount, 5);
  assert.deepEqual(
    captured.document.requirements.filter((row) => !row.ready).map((row) => row.requirementId),
    REQUIREMENT_IDS.filter((id) => !['P-01', 'P-02', 'P-03', 'P-04', 'P-37'].includes(id))
  );
  await assert.rejects(
    () => validateProductRequirement(validatorContext(subject, captured)),
    /remains blocked by incomplete substantive parity coverage/u
  );
});

test('inventory detects every missing, duplicate, reused, invalid, and unsupported ownership gap', async (t) => {
  const cases = [
    ['missing validator', (subject) => fs.rmSync(path.join(subject.root, 'scripts/linux-port/product-validators/P-05.mjs')), 'missing-validator'],
    ['reused validator', (subject) => fs.copyFileSync(
      path.join(subject.root, 'scripts/linux-port/product-validators/P-05.mjs'),
      path.join(subject.root, 'scripts/linux-port/product-validators/P-06.mjs')
    ), 'reused-validator'],
    ['duplicate validator registration', (subject) => mutateJson(subject.root, 'docs/linux-port/product-parity-evidence-policies.json', (value) => {
      const policy = value.policies.find((row) => row.requirementId === 'P-05');
      policy.registeredProducer.sourcePaths.push('scripts/linux-port/product-validators/P-05.mjs');
    }), 'duplicate-validator'],
    ['fixture validator', (subject) => write(subject.root, 'scripts/linux-port/product-validators/P-05.mjs',
      'export async function validateProductRequirement() { return true; } // placeholder\n'), 'fixture-validator'],
    ['non-substantive validator', (subject) => write(subject.root, 'scripts/linux-port/product-validators/P-05.mjs',
      'export async function validateProductRequirement(context) { return context; }\n'), 'fixture-validator'],
    ['missing policy', (subject) => mutateJson(subject.root, 'docs/linux-port/product-parity-evidence-policies.json',
      (value) => { value.policies = value.policies.filter((row) => row.requirementId !== 'P-05'); }), 'missing-policy'],
    ['duplicate policy', (subject) => mutateJson(subject.root, 'docs/linux-port/product-parity-evidence-policies.json',
      (value) => { value.policies.push({ ...value.policies.find((row) => row.requirementId === 'P-05') }); }), 'duplicate-policy'],
    ['missing environment', (subject) => mutateJson(subject.root, 'docs/linux-port/product-parity-requirements.json',
      (value) => { value.minimumSupportMatrix = value.minimumSupportMatrix.filter((row) => row.id !== SUPPORT_ENVIRONMENTS[1]); }), 'missing-environment'],
    ['duplicate environment', (subject) => mutateJson(subject.root, 'docs/linux-port/product-parity-requirements.json',
      (value) => { value.minimumSupportMatrix.push({ ...value.minimumSupportMatrix[0] }); }), 'duplicate-environment'],
    ['missing capture and materializer', (subject) => mutateFeatureRegistry(subject,
      (value) => { value.requirements = value.requirements.filter((row) => row.requirementId !== 'P-05'); }), ['missing-capture', 'unsupported-materializer']],
    ['duplicate capture', (subject) => mutateFeatureRegistry(subject,
      (value) => { value.requirements.push({ ...value.requirements.find((row) => row.requirementId === 'P-05') }); }), 'duplicate-capture'],
    ['reused capture', (subject) => mutateFeatureRegistry(subject, (value) => {
      const p05 = value.requirements.find((row) => row.requirementId === 'P-05');
      value.requirements.find((row) => row.requirementId === 'P-06').artifacts[0].role = p05.artifacts[0].role;
    }), 'reused-capture'],
    ['missing requirement', (subject) => mutateJson(subject.root, 'docs/linux-port/product-parity-requirements.json',
      (value) => { value.requirements = value.requirements.filter((row) => row.id !== 'P-05'); }), 'missing-requirement'],
    ['duplicate requirement', (subject) => mutateJson(subject.root, 'docs/linux-port/product-parity-requirements.json',
      (value) => { value.requirements.push({ ...value.requirements.find((row) => row.id === 'P-05') }); }), 'duplicate-requirement']
  ];
  for (const [name, mutate, expectedCodes] of cases) {
    await t.test(name, () => {
      const subject = createRepository();
      t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
      mutate(subject);
      const captured = capture(subject);
      assert.equal(captured.document.status, 'blocked');
      for (const code of Array.isArray(expectedCodes) ? expectedCodes : [expectedCodes]) {
        assert.ok(captured.document.blockers.some((blocker) => blocker.code === code), code);
      }
    });
  }
});

test('stale HEAD, candidate substitution, and self-referential proof fail closed', async (t) => {
  await t.test('stale HEAD', () => {
    const subject = createRepository();
    t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
    const captured = capture(subject, { targetHead: 'f'.repeat(40) });
    assert.equal(captured.document.status, 'blocked');
    assert.ok(captured.document.blockers.some((blocker) => blocker.code === 'stale-target-head'));
    assert.ok(captured.document.blockers.some((blocker) => blocker.code === 'stale-candidate'));
  });
  await t.test('candidate substitution', () => {
    const subject = createRepository();
    t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
    const captured = capture(subject);
    assert.throws(() => validateParityCertificationPreflight(captured.document, {
      repoRoot: subject.root,
      targetHead: subject.head,
      environmentId: ENVIRONMENT,
      materializedProofPath: `${subject.inputRelative}/release-subjects/proof.json`,
      candidate: { ...captured.document.candidate, artifactDigest: `sha256:${'c'.repeat(64)}` }
    }), /stale, substituted, or not bound/u);
  });
  await t.test('stale candidate registry', () => {
    const subject = createRepository();
    t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
    mutateFeatureRegistry(subject, (value) => {
      value.requirements.find((row) => row.requirementId === 'P-05').artifacts[0].maxBytes -= 1;
    }, { syncCandidate: false });
    const captured = capture(subject);
    assert.equal(captured.document.status, 'blocked');
    assert.ok(captured.document.blockers.some((blocker) => blocker.code === 'stale-candidate-registry'));
  });
  await t.test('self-referential inventory source', () => {
    const subject = createRepository();
    t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
    const captured = capture(subject);
    captured.document.sources.requirementsManifest.path = captured.document.proofPath;
    assert.throws(() => validateParityCertificationPreflight(captured.document, {
      repoRoot: subject.root,
      targetHead: subject.head,
      environmentId: ENVIRONMENT,
      materializedProofPath: `${subject.inputRelative}/release-subjects/proof.json`,
      candidate: captured.document.candidate
    }), /self-referential/u);
  });
  await t.test('materialized proof self-reference', () => {
    const subject = createRepository();
    t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
    const captured = capture(subject);
    assert.throws(() => validateParityCertificationPreflight(captured.document, {
      repoRoot: subject.root,
      targetHead: subject.head,
      environmentId: ENVIRONMENT,
      materializedProofPath: captured.document.proofPath,
      candidate: captured.document.candidate
    }), /self-referential/u);
  });
});
