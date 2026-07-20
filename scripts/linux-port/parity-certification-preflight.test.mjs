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
  certificationTestExecutionsMatch,
  classifyOwnershipTestSpawn,
  collectCertificationTestExecutions,
  validateParityCertificationPreflight
} from './lib/parity-certification-preflight.mjs';
import { SUPPORT_ENVIRONMENTS } from './lib/product-proof-closure.mjs';
import { captureParityCertificationPreflight } from './capture-parity-certification-preflight.mjs';
import { validateProductRequirement } from './product-validators/P-02.mjs';

const SOURCE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const ENVIRONMENT = SUPPORT_ENVIRONMENTS[0];
const RUN_ID = '12345';
const DIGEST = `sha256:${'b'.repeat(64)}`;
const RELEASE_ONLY = new Set(['P-01', 'P-03', 'P-04', 'P-37', 'P-38']);

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

function aggregateAttestationSubjects(releaseArtifacts, packages) {
  const row = (role, format = null, architecture = null) => {
    const suffix = [role, format, architecture].filter(Boolean).join('-');
    const subjectPath = `attestations/${suffix}`;
    return {
      role,
      ...(format ? { format } : {}),
      ...(architecture ? { architecture } : {}),
      subject: { path: subjectPath, sha256: '1'.repeat(64), size: 1 },
      bundle: { path: `${subjectPath}.sigstore.json`, sha256: '2'.repeat(64), size: 1 }
    };
  };
  return [
    ...releaseArtifacts.map((artifact) => row('release-artifact', artifact.type, artifact.architecture)),
    ...packages.flatMap((entry) => [
      row('installed-manifest', entry.format, entry.architecture),
      row('installed-manifest-signature', entry.format, entry.architecture)
    ]),
    ...[
      'checksums', 'sbom', 'vex', 'provenance', 'source-archive',
      'arch-pkgbuild', 'arch-release-metadata', 'update-feed'
    ].map((role) => row(role))
  ];
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
    ? ['P-02', 'P-05', 'P-06', 'P-07', 'P-08', 'P-31', 'P-34', 'P-40']
    : ['P-02', 'P-05', 'P-06', 'P-07', 'P-08', 'P-31', 'P-34', 'P-40'];
  const certificationIds = complete
    ? ['P-01', 'P-02', 'P-03', 'P-04', 'P-05', 'P-06', 'P-07', 'P-08', 'P-31', 'P-34', 'P-37', 'P-38', 'P-39', 'P-40']
    : ['P-01', 'P-02', 'P-03', 'P-04', 'P-05', 'P-06', 'P-07', 'P-08', 'P-31', 'P-34', 'P-37', 'P-38', 'P-39', 'P-40'];
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
    })),
    certification: certificationIds.map((requirementId) => {
      const testPath = `scripts/linux-port/ownership-tests/${requirementId}.test.mjs`;
      const captureProducerPath = RELEASE_ONLY.has(requirementId)
        ? 'scripts/linux-port/finalize-product-proof-closure.mjs'
        : requirementId === 'P-39'
          ? 'scripts/linux-port/capture-p39-differential.mjs'
        : requirementId === 'P-02'
          ? 'scripts/linux-port/capture-parity-certification-preflight.mjs'
          : `scripts/linux-port/capture-${requirementId.toLowerCase()}.mjs`;
      const materializerProducerPath = RELEASE_ONLY.has(requirementId)
        ? 'scripts/linux-port/prepare-product-requirement-input.mjs'
        : requirementId === 'P-39'
          ? 'scripts/linux-port/prepare-product-requirement-input.mjs'
        : ['P-02', 'P-05', 'P-06', 'P-07', 'P-08', 'P-31', 'P-34', 'P-40'].includes(requirementId)
          ? 'scripts/linux-port/finalize-product-feature-proof-closure.mjs'
          : `scripts/linux-port/materialize-${requirementId.toLowerCase()}.mjs`;
      return {
        requirementId,
        validator: {
          sourcePath: `scripts/linux-port/product-validators/${requirementId}.mjs`,
          entrypoint: 'validateProductRequirement',
          testPath,
          mutationTestName: `${requirementId} semantic mutation fails closed`
        },
        capture: {
          producerPath: captureProducerPath,
          entrypoint: 'requirement',
          workflowPath: RELEASE_ONLY.has(requirementId)
            ? '.github/workflows/linux-release.yml'
            : requirementId === 'P-39'
              ? '.github/workflows/linux-product-parity.yml'
            : requirementId === 'P-02'
              ? '.github/workflows/linux-product-parity.yml'
              : `.github/workflows/${requirementId.toLowerCase()}-capture.yml`,
          testPath,
          testName: `${requirementId} capture executes`
        },
        materializer: {
          producerPath: materializerProducerPath,
          entrypoint: 'requirement',
          workflowPath: RELEASE_ONLY.has(requirementId) || ['P-02', 'P-05', 'P-06', 'P-07', 'P-08', 'P-31', 'P-34', 'P-39', 'P-40'].includes(requirementId)
            ? '.github/workflows/linux-product-parity.yml'
            : `.github/workflows/${requirementId.toLowerCase()}-materialize.yml`,
          testPath,
          testName: `${requirementId} materializer executes`
        }
      };
    })
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
  write(root, '.gitignore', 'docs/linux-port/evidence/\n');
  for (const schema of [
    'schemas/linux-parity-certification-preflight.schema.json',
    'schemas/linux-product-feature-proof-registry.schema.json'
  ]) write(root, schema, fs.readFileSync(path.join(SOURCE_ROOT, schema)));
  const validatorIds = complete
    ? ['P-01', 'P-02', 'P-03', 'P-04', 'P-05', 'P-06', 'P-07', 'P-08', 'P-31', 'P-34', 'P-37', 'P-38', 'P-39', 'P-40']
    : ['P-01', 'P-02', 'P-03', 'P-04', 'P-05', 'P-06', 'P-07', 'P-08', 'P-31', 'P-34', 'P-37', 'P-38', 'P-39', 'P-40'];
  for (const requirementId of validatorIds) {
    write(root, `scripts/linux-port/product-validators/${requirementId}.mjs`,
      `export async function validateProductRequirement(context) {\n`
      + `  if (context.observedRequirement !== '${requirementId}') throw new Error('${requirementId} semantic mutation');\n`
      + `  return { status: 'passed', requirementId: '${requirementId}' };\n}\n`);
    const ownership = registry(complete).certification.find((entry) => entry.requirementId === requirementId);
    const testDirectory = path.posix.dirname(ownership.validator.testPath);
    const relativeModule = (modulePath) => {
      const relative = path.posix.relative(testDirectory, modulePath);
      return relative.startsWith('.') ? relative : `./${relative}`;
    };
    write(root, ownership.validator.testPath,
      `import assert from 'node:assert/strict';\n`
      + `import test from 'node:test';\n`
      + `import { validateProductRequirement } from '../product-validators/${requirementId}.mjs';\n`
      + `import * as captureProducer from '${relativeModule(ownership.capture.producerPath)}';\n`
      + `import * as materializerProducer from '${relativeModule(ownership.materializer.producerPath)}';\n`
      + `test('${ownership.validator.mutationTestName}', async () => {\n`
      + `  await assert.rejects(() => validateProductRequirement({ observedRequirement: 'substituted' }), /semantic mutation/u);\n`
      + `});\n`
      + `test('${ownership.capture.testName}', () => assert.equal(typeof captureProducer.requirement, 'string'));\n`
      + `test('${ownership.materializer.testName}', () => assert.equal(typeof materializerProducer.requirement, 'string'));\n`);
    for (const component of ['capture', 'materializer']) {
      write(root, ownership[component].producerPath, `export const requirement = '${requirementId}';\n`);
      const workflowPath = ownership[component].workflowPath;
      if (['.github/workflows/linux-release.yml', '.github/workflows/linux-product-parity.yml']
        .includes(workflowPath)) {
        write(root, workflowPath, fs.readFileSync(path.join(SOURCE_ROOT, workflowPath)));
      } else {
        write(root, workflowPath,
          `jobs:\n  certification:\n    steps:\n`
          + `      - name: ${requirementId} ${component} executes\n`
          + `        run: node ${ownership[component].producerPath}\n`);
      }
    }
  }
  write(root, 'scripts/linux-port/run-product-requirement-validator.mjs', 'export const runner = true;\n');
  git(root, ['add', '.']);
  git(root, ['commit', '-qm', 'complete parity inventory']);
  const head = git(root, ['rev-parse', 'HEAD']);
  const inputRelative = `docs/linux-port/evidence/product-parity-inputs/P-02/${ENVIRONMENT}`;
  const inputRoot = path.join(root, inputRelative);
  const releaseArtifacts = ['appimage', 'arch', 'daemon', 'deb', 'rpm'].flatMap((type) =>
    ['aarch64', 'x86_64'].map((architecture) => ({
      type,
      architecture,
      artifact: { path: 'unused', sha256: 'a'.repeat(64) },
      detachedSignature: { path: 'unused', sha256: 'a'.repeat(64) },
      sigstore: { path: 'unused', sha256: 'a'.repeat(64) }
    }))
  );
  const packages = ['arch', 'deb', 'rpm'].flatMap((format) =>
    ['aarch64', 'x86_64'].map((architecture) => ({
      format,
      architecture,
      artifact: { path: 'unused', sha256: 'a'.repeat(64) },
      installedManifest: { path: 'unused', sha256: 'a'.repeat(64) },
      installedManifestSignature: { path: 'unused', sha256: 'a'.repeat(64) }
    }))
  );
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
    releaseArtifacts,
    packages,
    attestationSubjects: aggregateAttestationSubjects(releaseArtifacts, packages),
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
  const committedBytes = (relativePath) => {
    try {
      return execFileSync('git', ['show', `${subject.head}:${relativePath}`], {
        cwd: subject.root,
        encoding: 'buffer',
        stdio: ['ignore', 'pipe', 'ignore']
      });
    } catch {
      return null;
    }
  };
  const registryValue = JSON.parse(committedBytes(
    'docs/linux-port/product-feature-proof-registry.json'
  ).toString('utf8'));
  const executions = [];
  for (const ownership of registryValue.certification ?? []) {
    for (const [component, nameField] of [
      ['validator', 'mutationTestName'], ['capture', 'testName'], ['materializer', 'testName']
    ]) {
      const owned = ownership[component];
      const sourcePath = component === 'validator' ? owned.sourcePath : owned.producerPath;
      const sourceBytes = committedBytes(sourcePath);
      const testBytes = committedBytes(owned.testPath);
      if (!sourceBytes || !testBytes) continue;
      executions.push({
        requirementId: ownership.requirementId,
        component,
        sourcePath,
        sourceEntrypoint: owned.entrypoint,
        sourceSha256: crypto.createHash('sha256').update(sourceBytes).digest('hex'),
        testPath: owned.testPath,
        testName: owned[nameField],
        testSha256: crypto.createHash('sha256').update(testBytes).digest('hex'),
        status: 'passed',
        exitCode: 0,
        spawnSignal: null,
        spawnErrorCode: null,
        outputSha256: 'c'.repeat(64),
        mutationDetected: true,
        mutationExitCode: 1,
        mutationSignal: null,
        mutationSpawnErrorCode: null,
        mutationOutputSha256: 'd'.repeat(64)
      });
    }
  }
  return captureParityCertificationPreflight({
    repoRoot: subject.root,
    inputRoot: subject.inputRoot,
    environmentId: ENVIRONMENT,
    targetHead: subject.head,
    candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST,
    testExecutions: executions.sort((left, right) =>
      `${left.requirementId}:${left.component}`.localeCompare(`${right.requirementId}:${right.component}`)
    ),
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

function commitMutation(subject, message, { syncCandidate = true, updateAggregateTarget = true } = {}) {
  git(subject.root, ['add', '.']);
  git(subject.root, ['commit', '-qm', message]);
  subject.head = git(subject.root, ['rev-parse', 'HEAD']);
  if (syncCandidate) {
    const sidecarRelative = `${subject.inputRelative}/.linux-release/sidecars/product-feature-proof-registry.json`;
    const sidecar = write(
      subject.root,
      sidecarRelative,
      fs.readFileSync(path.join(subject.root, 'docs/linux-port/product-feature-proof-registry.json'))
    );
    mutateJson(subject.root, path.relative(subject.root, subject.aggregatePath), (aggregate) => {
      aggregate.targetHead = subject.head;
      aggregate.sourceCommit = subject.head;
      aggregate.featureProofRegistry = {
        path: 'sidecars/product-feature-proof-registry.json',
        sha256: sha256(sidecar),
        size: fs.statSync(sidecar).size
      };
    });
  } else if (updateAggregateTarget) {
    mutateJson(subject.root, path.relative(subject.root, subject.aggregatePath), (aggregate) => {
      aggregate.targetHead = subject.head;
      aggregate.sourceCommit = subject.head;
    });
  }
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

test('ownership-ready fixture blocks exactly the 26 unregistered requirement lanes', async (t) => {
  const subject = createRepository({ complete: false });
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  const captured = capture(subject, {
    testExecutions: collectCertificationTestExecutions(subject.root, subject.head)
  });
  const p39 = captured.document.requirements.find((row) => row.requirementId === 'P-39');
  assert.equal(p39.ready, true, JSON.stringify(p39));
  assert.equal(captured.document.status, 'blocked');
  assert.equal(captured.document.summary.validatorCount, 14);
  assert.equal(captured.document.summary.captureCount, 14);
  assert.equal(captured.document.summary.materializerCount, 14);
  assert.equal(captured.document.summary.readyCount, 14);
  assert.deepEqual(
    captured.document.requirements.filter((row) => !row.ready).map((row) => row.requirementId),
    REQUIREMENT_IDS.filter((id) => ![
      'P-01', 'P-02', 'P-03', 'P-04', 'P-05', 'P-06', 'P-07', 'P-08',
      'P-31', 'P-34', 'P-37', 'P-38', 'P-39', 'P-40'
    ].includes(id))
  );
  await assert.rejects(
    () => validateProductRequirement(validatorContext(subject, captured)),
    /remains blocked by incomplete substantive parity coverage/u
  );
});

test('P-02 validator rejects an invocation without a passed release closure', async () => {
  await assert.rejects(
    () => validateProductRequirement({}),
    /requirement release closure is not passed and invocation-bound/u
  );
});

test('ownership mutation accepts only a normal nonzero child exit', () => {
  const testName = 'P-02 mutation target';
  const normalFailure = classifyOwnershipTestSpawn({
    status: 1, signal: null, stdout: '', stderr: 'expected failure\n'
  }, testName);
  assert.equal(normalFailure.failedNormally, true);
  for (const [name, result, expectedError, expectedSignal] of [
    ['timeout', { status: null, signal: 'SIGKILL', error: { code: 'ETIMEDOUT' } }, 'ETIMEDOUT', 'SIGKILL'],
    ['output overflow', { status: null, signal: null, error: { code: 'ENOBUFS' } }, 'ENOBUFS', null],
    ['abnormal signal', { status: null, signal: 'SIGABRT' }, null, 'SIGABRT']
  ]) {
    const classified = classifyOwnershipTestSpawn({ stdout: '', stderr: '', ...result }, testName);
    assert.equal(classified.failedNormally, false, name);
    assert.equal(classified.passed, false, name);
    assert.equal(classified.exitCode, null, name);
    assert.equal(classified.errorCode, expectedError, name);
    assert.equal(classified.signal, expectedSignal, name);
  }
});

test('execution authentication binds baseline and mutation result metadata and output digests', (t) => {
  const subject = createRepository({ complete: false });
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  const executions = capture(subject).document.testExecutions;
  assert.equal(certificationTestExecutionsMatch(executions, executions), true);
  for (const [field, value] of [
    ['outputSha256', 'e'.repeat(64)],
    ['mutationExitCode', 2],
    ['mutationOutputSha256', 'f'.repeat(64)]
  ]) {
    const tampered = executions.map((entry, index) => index === 0 ? { ...entry, [field]: value } : entry);
    assert.equal(certificationTestExecutionsMatch(tampered, executions), false, field);
  }
});

test('P-02 capture emits a blocked candidate-bound diagnostic inventory', (t) => {
  const subject = createRepository({ complete: false });
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  const captured = capture(subject);
  assert.equal(captured.document.targetHead, subject.head);
  assert.equal(captured.document.candidate.runId, RUN_ID);
  assert.equal(captured.document.candidate.artifactDigest, DIGEST);
  assert.equal(captured.document.status, 'blocked');
  assert.equal(captured.document.summary.readyCount, 14);
  assert.equal(fs.existsSync(captured.output), true);
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
    }), 'invalid-policy'],
    ['declaration without capture producer', (subject) => fs.rmSync(
      path.join(subject.root, 'scripts/linux-port/capture-p-05.mjs')
    ), ['invalid-capture', 'unsupported-materializer']],
    ['declaration without ownership test', (subject) => fs.rmSync(
      path.join(subject.root, 'scripts/linux-port/ownership-tests/P-05.test.mjs')
    ), ['invalid-validator', 'invalid-capture', 'unsupported-materializer']],
    ['missing policy', (subject) => mutateJson(subject.root, 'docs/linux-port/product-parity-evidence-policies.json',
      (value) => { value.policies = value.policies.filter((row) => row.requirementId !== 'P-05'); }), 'missing-policy'],
    ['duplicate policy', (subject) => mutateJson(subject.root, 'docs/linux-port/product-parity-evidence-policies.json',
      (value) => { value.policies.push({ ...value.policies.find((row) => row.requirementId === 'P-05') }); }), 'duplicate-policy'],
    ['weakened artifact root', (subject) => mutateJson(subject.root, 'docs/linux-port/product-parity-evidence-policies.json', (value) => {
      value.policies.find((row) => row.requirementId === 'P-05').allowedArtifactRoots = ['docs/linux-port/evidence'];
    }), 'invalid-policy'],
    ['weakened minimum artifact count', (subject) => mutateJson(subject.root, 'docs/linux-port/product-parity-evidence-policies.json', (value) => {
      value.policies.find((row) => row.requirementId === 'P-05').minArtifactCount = 0;
    }), 'invalid-policy'],
    ['weakened signer workflow', (subject) => mutateJson(subject.root, 'docs/linux-port/product-parity-evidence-policies.json', (value) => {
      value.policies.find((row) => row.requirementId === 'P-05').registeredProducer.signerWorkflow = 'github.com/example/unsafe.yml';
    }), 'invalid-policy'],
    ['incomplete installed subject binding', (subject) => mutateJson(subject.root, 'docs/linux-port/product-parity-evidence-policies.json', (value) => {
      value.policies.find((row) => row.requirementId === 'P-05').requiredSubjectFields.pop();
    }), 'invalid-policy'],
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
      commitMutation(subject, `mutation: ${name}`);
      const captured = capture(subject);
      assert.equal(captured.document.status, 'blocked');
      for (const code of Array.isArray(expectedCodes) ? expectedCodes : [expectedCodes]) {
        assert.ok(captured.document.blockers.some((blocker) => blocker.code === code), code);
      }
    });
  }
});

test('executed semantic mutation ownership rejects a unique no-op validator', (t) => {
  const subject = createRepository();
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  const baseline = collectCertificationTestExecutions(subject.root, subject.head);
  assert.ok(baseline.every((entry) => entry.status === 'passed'), JSON.stringify(baseline, null, 2));
  write(subject.root, 'scripts/linux-port/product-validators/P-05.mjs',
    "export async function validateProductRequirement() { return { status: 'passed' }; }\n");
  commitMutation(subject, 'replace P-05 with semantic no-op');
  const mutated = collectCertificationTestExecutions(subject.root, subject.head);
  const execution = mutated.find((entry) =>
    entry.testName === 'P-05 semantic mutation fails closed'
  );
  assert.equal(execution.status, 'failed');
  assert.throws(
    () => captureParityCertificationPreflight({
      repoRoot: subject.root,
      inputRoot: subject.inputRoot,
      environmentId: ENVIRONMENT,
      targetHead: subject.head,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST
    }),
    /ownership tests failed/u
  );
});

test('paired no-op ownership, duplicate tests, workflow comments, and untracked imports fail closed', async (t) => {
  await t.test('paired no-op validator and ownership test cannot authenticate fabricated passing executions', () => {
    const subject = createRepository();
    t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
    const ownership = registry(true).certification.find((row) => row.requirementId === 'P-05');
    write(subject.root, ownership.validator.sourcePath,
      "export async function validateProductRequirement() { return { status: 'passed' }; }\n");
    write(subject.root, ownership.validator.testPath,
      `import test from 'node:test';\n`
      + `test('${ownership.validator.mutationTestName}', () => {});\n`
      + `test('${ownership.capture.testName}', () => {});\n`
      + `test('${ownership.materializer.testName}', () => {});\n`);
    commitMutation(subject, 'paired no-op validator and ownership test');
    const fabricated = capture(subject);
    assert.throws(() => validateParityCertificationPreflight(fabricated.document, {
      repoRoot: subject.root,
      targetHead: subject.head,
      environmentId: ENVIRONMENT,
      materializedProofPath: `${subject.inputRelative}/release-subjects/proof.json`,
      candidate: fabricated.document.candidate
    }), /independent target-commit ownership test execution failed/u);
  });

  await t.test('duplicate ownership test registration is rejected', () => {
    const subject = createRepository();
    t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
    mutateFeatureRegistry(subject, (value) => {
      const p05 = value.certification.find((row) => row.requirementId === 'P-05');
      const p06 = value.certification.find((row) => row.requirementId === 'P-06');
      p06.validator.testPath = p05.validator.testPath;
      p06.validator.mutationTestName = p05.validator.mutationTestName;
    });
    commitMutation(subject, 'reuse ownership test');
    assert.throws(
      () => collectCertificationTestExecutions(subject.root, subject.head),
      /ownership tests must be unique/u
    );
    const captured = capture(subject);
    assert.ok(captured.document.blockers.some((blocker) => blocker.code === 'reused-ownership-test'));
  });

  await t.test('a YAML comment mentioning the producer is not executable workflow wiring', () => {
    const subject = createRepository();
    t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
    const ownership = registry(true).certification.find((row) => row.requirementId === 'P-05').capture;
    write(subject.root, ownership.workflowPath,
      `jobs:\n  certification:\n    steps:\n      - run: echo safe # node ${ownership.producerPath}\n`);
    commitMutation(subject, 'replace capture command with comment');
    const captured = capture(subject);
    const p05 = captured.document.requirements.find((row) => row.requirementId === 'P-05');
    assert.equal(p05.capture.status, 'invalid');
    assert.equal(p05.ready, false);
  });

  for (const [name, run] of [
    ['a command behind an always-false branch', (producer) => `if false; then node ${producer}; fi`],
    ['a command whose failure is swallowed', (producer) => `node ${producer} --help || true`]
  ]) {
    await t.test(`${name} is not executable workflow wiring`, () => {
      const subject = createRepository();
      t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
      const ownership = registry(true).certification.find((row) => row.requirementId === 'P-05').capture;
      write(subject.root, ownership.workflowPath,
        `jobs:\n  certification:\n    steps:\n`
        + `      - name: P-05 capture executes\n`
        + `        run: ${run(ownership.producerPath)}\n`);
      commitMutation(subject, `replace capture command: ${name}`);
      const captured = capture(subject);
      const p05 = captured.document.requirements.find((row) => row.requirementId === 'P-05');
      assert.equal(p05.capture.status, 'invalid');
      assert.equal(p05.ready, false);
    });
  }

  await t.test('a producer command in an unrelated step is not executable workflow wiring', () => {
    const subject = createRepository();
    t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
    const ownership = registry(true).certification.find((row) => row.requirementId === 'P-05').capture;
    write(subject.root, ownership.workflowPath,
      `jobs:\n  certification:\n    steps:\n`
      + `      - name: P-05 capture executes\n`
      + `        run: echo safe\n`
      + `      - name: unrelated\n`
      + `        run: node ${ownership.producerPath}\n`);
    commitMutation(subject, 'move capture command to unrelated step');
    const captured = capture(subject);
    const p05 = captured.document.requirements.find((row) => row.requirementId === 'P-05');
    assert.equal(p05.capture.status, 'invalid');
    assert.equal(p05.ready, false);
  });

  await t.test('an untracked imported helper cannot influence isolated target execution', () => {
    const subject = createRepository();
    t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
    const ownership = registry(true).certification.find((row) => row.requirementId === 'P-05');
    write(subject.root, ownership.validator.testPath,
      `import assert from 'node:assert/strict';\n`
      + `import test from 'node:test';\n`
      + `import { semanticPass } from './untracked-helper.mjs';\n`
      + `test('${ownership.validator.mutationTestName}', () => assert.equal(semanticPass, true));\n`
      + `test('${ownership.capture.testName}', () => assert.equal(semanticPass, true));\n`
      + `test('${ownership.materializer.testName}', () => assert.equal(semanticPass, true));\n`);
    commitMutation(subject, 'ownership test imports absent helper');
    write(subject.root, 'scripts/linux-port/ownership-tests/untracked-helper.mjs',
      'export const semanticPass = true;\n');
    const executions = collectCertificationTestExecutions(subject.root, subject.head);
    assert.ok(executions.filter((entry) => entry.requirementId === 'P-05')
      .every((entry) => entry.status === 'failed'));
  });

  await t.test('a committed target symlink cannot escape isolated ownership execution', () => {
    const subject = createRepository();
    t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
    fs.symlinkSync('/etc/hosts', path.join(
      subject.root, 'scripts/linux-port/ownership-tests/external-helper.mjs'
    ));
    commitMutation(subject, 'add target symlink outside isolated checkout');
    assert.throws(
      () => collectCertificationTestExecutions(subject.root, subject.head),
      /target archive contains a symbolic link/u
    );
  });
});

test('capture failure always leaves an uploadable non-promotable diagnostic', (t) => {
  const subject = createRepository();
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  const runnerTemporaryRoot = fs.realpathSync(process.env.RUNNER_TEMP ?? os.tmpdir());
  const diagnosticRoot = fs.mkdtempSync(path.join(runnerTemporaryRoot, 'openburnbar-p02-diagnostic-test-'));
  t.after(() => fs.rmSync(diagnosticRoot, { recursive: true, force: true }));
  write(subject.root, '.linux-parity-diagnostics', 'hostile repository path\n');
  const baseline = capture(subject);
  const failedExecutions = baseline.document.testExecutions.map((entry, index) =>
    index === 0 ? { ...entry, status: 'failed', exitCode: 1 } : entry
  );
  assert.throws(() => captureParityCertificationPreflight({
    repoRoot: subject.root,
    inputRoot: subject.inputRoot,
    environmentId: ENVIRONMENT,
    targetHead: subject.head,
    candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST,
    diagnosticRoot,
    testExecutions: failedExecutions
  }), /ownership tests failed/u);
  const diagnosticPath = path.join(diagnosticRoot, 'capture-failure.json');
  const diagnostic = JSON.parse(fs.readFileSync(diagnosticPath, 'utf8'));
  assert.equal(diagnostic.status, 'capture-failed');
  assert.equal(diagnostic.targetHead, subject.head);
  assert.equal(fs.existsSync(path.join(subject.inputRoot, 'feature-proof-registration.json')), false);

  const hostileOutput = path.join(subject.inputRoot, 'feature-artifacts', PARITY_PREFLIGHT_FILENAME);
  fs.mkdirSync(hostileOutput, { recursive: true });
  assert.throws(() => captureParityCertificationPreflight({
    repoRoot: subject.root,
    inputRoot: subject.inputRoot,
    environmentId: ENVIRONMENT,
    targetHead: subject.head,
    candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST,
    diagnosticRoot,
    testExecutions: failedExecutions
  }));
  assert.equal(JSON.parse(fs.readFileSync(diagnosticPath, 'utf8')).status, 'capture-failed');
  assert.equal(fs.existsSync(path.join(subject.inputRoot, 'feature-proof-registration.json')), false);

  assert.throws(() => captureParityCertificationPreflight({
    repoRoot: subject.root,
    inputRoot: path.join(subject.root, 'missing-input-root'),
    environmentId: ENVIRONMENT,
    targetHead: subject.head,
    candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST,
    diagnosticRoot,
    testExecutions: failedExecutions
  }));
  assert.equal(JSON.parse(fs.readFileSync(diagnosticPath, 'utf8')).status, 'capture-failed');

  let fallbackError;
  try {
    captureParityCertificationPreflight({
      repoRoot: subject.root,
      inputRoot: path.join(subject.root, 'missing-input-root'),
      environmentId: ENVIRONMENT,
      targetHead: subject.head,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST,
      diagnosticRoot: path.join(subject.root, '.linux-parity-diagnostics'),
      testExecutions: failedExecutions
    });
    assert.fail('hostile diagnostic root unexpectedly succeeded');
  } catch (error) {
    fallbackError = error;
  }
  assert.equal(typeof fallbackError.diagnosticOutput, 'string');
  assert.notEqual(path.dirname(fallbackError.diagnosticOutput), path.join(
    subject.root, '.linux-parity-diagnostics'
  ));
  assert.equal(JSON.parse(fs.readFileSync(fallbackError.diagnosticOutput, 'utf8')).status, 'capture-failed');
  t.after(() => fs.rmSync(path.dirname(fallbackError.diagnosticOutput), {
    recursive: true,
    force: true
  }));
});

test('uncommitted target inventory and validator substitutions cannot affect the commit snapshot', (t) => {
  const subject = createRepository();
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  const baseline = capture(subject);
  mutateJson(subject.root, 'docs/linux-port/product-parity-requirements.json', (value) => {
    value.requirements = value.requirements.filter((row) => row.id !== 'P-05');
  });
  write(subject.root, 'scripts/linux-port/product-validators/P-05.mjs',
    "export async function validateProductRequirement() { return { status: 'passed' }; }\n");
  const recaptured = capture(subject);
  assert.deepEqual(recaptured.document.summary, baseline.document.summary);
  assert.equal(
    recaptured.document.requirements.find((row) => row.requirementId === 'P-05').validator.sha256,
    baseline.document.requirements.find((row) => row.requirementId === 'P-05').validator.sha256
  );
  assert.equal(
    recaptured.document.requirements.find((row) => row.requirementId === 'P-05').presentCount,
    1
  );
});

test('target snapshots, candidate substitution, and self-referential proof fail closed', async (t) => {
  await t.test('stale candidate after a new target commit', () => {
    const subject = createRepository();
    t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
    write(subject.root, 'target-change.txt', 'new target bytes\n');
    commitMutation(subject, 'new target', { syncCandidate: false, updateAggregateTarget: false });
    const captured = capture(subject);
    assert.equal(captured.document.status, 'blocked');
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
  await t.test('unowned test execution', () => {
    const subject = createRepository();
    t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
    const captured = capture(subject);
    captured.document.testExecutions.push({
      ...captured.document.testExecutions[0],
      testName: 'unowned passing test'
    });
    assert.throws(() => validateParityCertificationPreflight(captured.document, {
      repoRoot: subject.root,
      targetHead: subject.head,
      environmentId: ENVIRONMENT,
      materializedProofPath: `${subject.inputRelative}/release-subjects/proof.json`,
      candidate: captured.document.candidate
    }), /not independently authenticated/u);
  });
  await t.test('stale candidate registry', () => {
    const subject = createRepository();
    t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
    mutateFeatureRegistry(subject, (value) => {
      value.requirements.find((row) => row.requirementId === 'P-05').artifacts[0].maxBytes -= 1;
    }, { syncCandidate: false });
    commitMutation(subject, 'mutate target registry', { syncCandidate: false });
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
