import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { after } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  PARITY_PREFLIGHT_FILENAME,
  PARITY_PREFLIGHT_ROLE,
  REQUIREMENT_IDS,
  certificationTestExecutionsMatch,
  classifyOwnershipTestSpawn,
  collectCertificationTestExecutions,
  createCertificationExecutionPlan,
  executeCertificationOwnershipTest,
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
const OPENBURNBAR_PARITY_COLLECTOR_CONCURRENCY = 'OPENBURNBAR_PARITY_COLLECTOR_CONCURRENCY';
const PRIVATE_TMP_ROOT = fs.realpathSync('/private/tmp');
const GIT_FIXTURE_DATE = '2026-08-10T00:00:00Z';

function withCollectorConcurrency(value, callback) {
  const previous = process.env[OPENBURNBAR_PARITY_COLLECTOR_CONCURRENCY];
  if (value === undefined) delete process.env[OPENBURNBAR_PARITY_COLLECTOR_CONCURRENCY];
  else process.env[OPENBURNBAR_PARITY_COLLECTOR_CONCURRENCY] = value;
  try {
    return callback();
  } finally {
    if (previous === undefined) delete process.env[OPENBURNBAR_PARITY_COLLECTOR_CONCURRENCY];
    else process.env[OPENBURNBAR_PARITY_COLLECTOR_CONCURRENCY] = previous;
  }
}


function withPrivateTmpRoot(callback) {
  const previous = process.env.TMPDIR;
  process.env.TMPDIR = `${PRIVATE_TMP_ROOT}${path.sep}`;
  try {
    return callback();
  } finally {
    if (previous === undefined) delete process.env.TMPDIR;
    else process.env.TMPDIR = previous;
  }
}

function makePrivateTempDir(prefix) {
  return fs.mkdtempSync(path.join(PRIVATE_TMP_ROOT, prefix));
}


const SHARED_FIXTURE_BYTE_PATHS = [
  'scripts/linux-port/product-validators/P-05.mjs',
  'scripts/linux-port/ownership-tests/P-05.test.mjs',
  'scripts/linux-port/product-validators/P-06.mjs',
  'scripts/linux-port/ownership-tests/P-06.test.mjs'
];

let sharedOwnershipFixture;
let sharedOwnershipFixturePromise;
let sharedOwnershipFixtureRoot;

after(async () => {
  try {
    await sharedOwnershipFixturePromise;
  } catch {
    // The test that awaited fixture creation owns the failure; the suite hook still cleans up.
  }
  if (sharedOwnershipFixtureRoot) {
    fs.rmSync(sharedOwnershipFixtureRoot, { recursive: true, force: true });
  }
  sharedOwnershipFixture = undefined;
  sharedOwnershipFixturePromise = undefined;
  sharedOwnershipFixtureRoot = undefined;
});

function stableStringify(value) {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${stableStringify(value[key])}`
    ).join(',')}}`;
  }
  return JSON.stringify(value);
}

function rowsFingerprint(rows) {
  return crypto.createHash('sha256').update(stableStringify(rows)).digest('hex');
}

function deepFreeze(value) {
  if (!value || typeof value !== 'object' || Object.isFrozen(value)) return value;
  for (const child of Object.values(value)) deepFreeze(child);
  return Object.freeze(value);
}

function immutableRows(rows) {
  return deepFreeze(JSON.parse(JSON.stringify(rows)));
}

function cloneRows(rows) {
  return JSON.parse(JSON.stringify(rows));
}

function rowKey(row) {
  return `${row.requirementId}:${row.component}`;
}

function savedFixtureBytes(subject) {
  return new Map(SHARED_FIXTURE_BYTE_PATHS.map((relativePath) => [
    relativePath,
    Buffer.from(fs.readFileSync(path.join(subject.root, relativePath)))
  ]));
}

function assertSavedFixtureBytes(subject, expectedBytes) {
  for (const [relativePath, bytes] of expectedBytes) {
    assert.ok(bytes.equals(fs.readFileSync(path.join(subject.root, relativePath))), relativePath);
  }
}

function assertCachedRows(label, rows, fingerprint) {
  assert.equal(Object.isFrozen(rows), true, `${label} rows array is protected`);
  assert.equal(rows.every((row) => Object.isFrozen(row)), true, `${label} rows are protected`);
  assert.equal(rowsFingerprint(rows), fingerprint, `${label} fingerprint`);
  assert.equal(rows.length, 120, `${label} row count`);
  assert.equal(new Set(rows.map(rowKey)).size, 120, `${label} unique execution keys`);
  assert.ok(rows.every((row) => row.status === 'passed'), JSON.stringify(
    rows.filter((row) => row.status !== 'passed'), null, 2
  ));
  assert.ok(rows.every((row) => row.mutationDetected === true), label);
}

function committedSha256AtHead(subject, relativePath) {
  const bytes = execFileSync('git', ['show', `${subject.head}:${relativePath}`], {
    cwd: subject.root,
    encoding: 'buffer',
    stdio: ['ignore', 'pipe', 'ignore']
  });
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function executionSourceBindingFingerprint(subject, rows) {
  const pathShas = new Map();
  const pathSha = (relativePath) => {
    if (!pathShas.has(relativePath)) pathShas.set(relativePath, committedSha256AtHead(subject, relativePath));
    return pathShas.get(relativePath);
  };
  const bindings = rows.map((row) => {
    const sourceSha256 = pathSha(row.sourcePath);
    const testSha256 = pathSha(row.testPath);
    assert.equal(row.sourceSha256, sourceSha256, `${rowKey(row)} source is bound to fixture HEAD`);
    assert.equal(row.testSha256, testSha256, `${rowKey(row)} test is bound to fixture HEAD`);
    return {
      key: rowKey(row),
      sourcePath: row.sourcePath,
      sourceSha256,
      testPath: row.testPath,
      testSha256
    };
  });
  return rowsFingerprint(bindings);
}

function assertCachedRowsBindToFixtureHead(label, subject, rows, fingerprint) {
  assert.equal(executionSourceBindingFingerprint(subject, rows), fingerprint, `${label} source binding fingerprint`);
}

function assertSharedOwnershipFixture(fixture) {
  assert.equal(git(fixture.subject.root, ['rev-parse', 'HEAD']), fixture.subject.head, 'shared fixture HEAD');
  assertSavedFixtureBytes(fixture.subject, fixture.savedBytes);
  assertCachedRows('1-worker', fixture.oneWorkerRows, fixture.oneWorkerFingerprint);
  assertCachedRows('4-worker', fixture.fourWorkerRows, fixture.fourWorkerFingerprint);
  assertCachedRowsBindToFixtureHead(
    '1-worker', fixture.subject, fixture.oneWorkerRows, fixture.oneWorkerSourceBindingFingerprint
  );
  assertCachedRowsBindToFixtureHead(
    '4-worker', fixture.subject, fixture.fourWorkerRows, fixture.fourWorkerSourceBindingFingerprint
  );
}

function copySubjectSnapshot(sourceSubject, root) {
  fs.cpSync(sourceSubject.root, root, {
    recursive: true,
    dereference: false,
    preserveTimestamps: true,
    mode: fs.constants.COPYFILE_FICLONE,
    filter: (sourcePath) => {
      const relative = path.relative(sourceSubject.root, sourcePath);
      return relative === '' || relative.split(path.sep)[0] !== '.git';
    }
  });
  git(root, ['init', '-q']);
  git(root, ['config', 'user.name', 'OpenBurnBar Test']);
  git(root, ['config', 'user.email', 'test@openburnbar.invalid']);
  git(root, ['config', 'gc.auto', '0']);
  git(root, ['add', '.']);
  git(root, ['commit', '-qm', 'complete parity inventory']);
  assert.equal(git(root, ['rev-parse', 'HEAD']), sourceSubject.head, 'private clone HEAD');
}

function cloneSubjectForCollector(subject, label) {
  const cloneParent = makePrivateTempDir(`openburnbar-parity-preflight-${label}-collector-`);
  const root = path.join(cloneParent, 'repo');
  copySubjectSnapshot(subject, root);
  return {
    subject: {
      ...subject,
      root,
      inputRoot: path.join(root, subject.inputRelative),
      aggregatePath: path.join(root, path.relative(subject.root, subject.aggregatePath))
    },
    cleanup: () => fs.rmSync(cloneParent, { recursive: true, force: true })
  };
}

function collectRowsInChild(subject, concurrency) {
  return new Promise((resolve, reject) => {
    const collectorModule = pathToFileURL(path.join(
      SOURCE_ROOT,
      'scripts/linux-port/lib/parity-certification-preflight.mjs'
    )).href;
    const child = spawn(process.execPath, [
      '--input-type=module',
      '-e',
      `import { collectCertificationTestExecutions } from ${JSON.stringify(collectorModule)};
`
        + `const [repoRoot, targetHead] = process.argv.slice(1);
`
        + `const rows = collectCertificationTestExecutions(repoRoot, targetHead);
`
        + `process.stdout.write(JSON.stringify(rows));
`,
      subject.root,
      subject.head
    ], {
      cwd: SOURCE_ROOT,
      env: {
        ...process.env,
        TMPDIR: `${PRIVATE_TMP_ROOT}${path.sep}`,
        [OPENBURNBAR_PARITY_COLLECTOR_CONCURRENCY]: concurrency
      },
      stdio: ['ignore', 'pipe', 'pipe']
    });
    const stdout = [];
    const stderr = [];
    child.stdout.on('data', (chunk) => stdout.push(chunk));
    child.stderr.on('data', (chunk) => stderr.push(chunk));
    child.on('error', reject);
    child.on('close', (code, signal) => {
      if (code !== 0 || signal) {
        reject(new Error(
          `collector ${concurrency}-worker child failed: code=${code ?? 'null'} signal=${signal ?? 'null'} `
          + Buffer.concat(stderr).toString('utf8')
        ));
        return;
      }
      try {
        resolve(JSON.parse(Buffer.concat(stdout).toString('utf8')));
      } catch (error) {
        error.message = `collector ${concurrency}-worker child emitted invalid JSON: ${error.message}`;
        reject(error);
      }
    });
  });
}

async function buildSharedOwnershipFixture() {
  const subject = withPrivateTmpRoot(() => createRepository());
  sharedOwnershipFixtureRoot = subject.root;
  const savedBytes = savedFixtureBytes(subject);
  const oneWorkerCollector = cloneSubjectForCollector(subject, 'one-worker');
  const fourWorkerCollector = cloneSubjectForCollector(subject, 'four-worker');
  let oneWorkerRawRows;
  let fourWorkerRawRows;
  try {
    [oneWorkerRawRows, fourWorkerRawRows] = await Promise.all([
      collectRowsInChild(oneWorkerCollector.subject, '1'),
      collectRowsInChild(fourWorkerCollector.subject, '4')
    ]);
  } finally {
    oneWorkerCollector.cleanup();
    fourWorkerCollector.cleanup();
  }
  const oneWorkerRows = immutableRows(oneWorkerRawRows);
  const fourWorkerRows = immutableRows(fourWorkerRawRows);
  sharedOwnershipFixture = {
    subject,
    savedBytes,
    oneWorkerRows,
    fourWorkerRows,
    oneWorkerFingerprint: rowsFingerprint(oneWorkerRows),
    fourWorkerFingerprint: rowsFingerprint(fourWorkerRows),
    oneWorkerSourceBindingFingerprint: executionSourceBindingFingerprint(subject, oneWorkerRows),
    fourWorkerSourceBindingFingerprint: executionSourceBindingFingerprint(subject, fourWorkerRows)
  };
  assertSharedOwnershipFixture(sharedOwnershipFixture);
  return sharedOwnershipFixture;
}

async function getSharedOwnershipFixture() {
  if (!sharedOwnershipFixturePromise) sharedOwnershipFixturePromise = buildSharedOwnershipFixture();
  const fixture = await sharedOwnershipFixturePromise;
  assertSharedOwnershipFixture(fixture);
  return fixture;
}

function privateCloneSubject(t, fixture) {
  const cloneParent = makePrivateTempDir('openburnbar-parity-preflight-clone-');
  t.after(() => fs.rmSync(cloneParent, { recursive: true, force: true }));
  const root = path.join(cloneParent, 'repo');
  copySubjectSnapshot(fixture.subject, root);
  return {
    ...fixture.subject,
    root,
    inputRoot: path.join(root, fixture.subject.inputRelative),
    aggregatePath: path.join(root, path.relative(fixture.subject.root, fixture.subject.aggregatePath))
  };
}

function collectRealOwnershipRows(subject, predicate) {
  return withPrivateTmpRoot(() => {
    const plan = createCertificationExecutionPlan(subject.root, subject.head);
    try {
      const entries = plan.entries.filter(predicate);
      assert.ok(entries.length > 0, 'real ownership row selector matched no entries');
      return entries.map((entry) => executeCertificationOwnershipTest(
        plan.repository, plan.targetHead, plan.templateRoot, entry
      )).sort((left, right) => rowKey(left).localeCompare(rowKey(right)));
    } finally {
      fs.rmSync(plan.templateRoot, { recursive: true, force: true });
    }
  });
}

function collectRequirementOwnershipRows(subject, requirementId, components = ['validator', 'capture', 'materializer']) {
  const componentSet = new Set(components);
  const rows = collectRealOwnershipRows(subject, (entry) =>
    entry.requirementId === requirementId && componentSet.has(entry.component)
  );
  assert.equal(rows.length, componentSet.size, `${requirementId} selected real ownership rows`);
  return rows;
}

function rowsWithRealOwnershipReplacements(cachedRows, replacements) {
  const byKey = new Map(replacements.map((row) => [rowKey(row), row]));
  const replaced = cachedRows.map((row) => byKey.get(rowKey(row)) ?? row);
  assert.equal(new Set(replaced.map(rowKey)).size, cachedRows.length, 'replacement rows preserve execution key set');
  for (const row of replacements) {
    assert.ok(replaced.some((entry) => entry === row), `missing replacement row ${rowKey(row)}`);
  }
  return cloneRows(replaced);
}

function assertOwnershipRowsAuthenticated(claimed, independent) {
  if (!certificationTestExecutionsMatch(claimed, independent)) {
    throw new Error('parity certification ownership executions are not independently authenticated');
  }
}

function captureWithCachedFixtureRows(subject, fixture, overrides = {}) {
  return capture(subject, {
    testExecutions: cloneRows(fixture.fourWorkerRows),
    ...overrides
  });
}

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
  return execFileSync('git', args, {
    cwd: root,
    encoding: 'utf8',
    env: {
      ...process.env,
      GIT_AUTHOR_DATE: GIT_FIXTURE_DATE,
      GIT_COMMITTER_DATE: GIT_FIXTURE_DATE
    }
  }).trim();
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

function registry() {
  const featureRequirements = REQUIREMENT_IDS.filter((id) =>
    !RELEASE_ONLY.has(id) && id !== 'P-39'
  );
  const certificationIds = REQUIREMENT_IDS;
  return {
    schemaVersion: 1,
    id: 'openburnbar-linux-product-feature-proof-registry-v1',
    requirements: featureRequirements.map((requirementId) => ({
      requirementId,
      artifacts: [{
        role: requirementId === 'P-02'
          ? PARITY_PREFLIGHT_ROLE
          : requirementId === 'P-13'
            ? 'feature.onboarding-installed'
          : requirementId === 'P-14'
            ? 'feature.chat-installed'
          : requirementId === 'P-15'
            ? 'feature.account-billing-installed'
          : requirementId === 'P-16'
            ? 'feature.cloud-devices-installed'
          : requirementId === 'P-18'
            ? 'feature.memory-review-installed'
          : requirementId === 'P-19'
            ? 'feature.projects-installed'
          : requirementId === 'P-20'
            ? 'feature.missions-installed'
          : requirementId === 'P-21'
            ? 'feature.insights-installed'
          : requirementId === 'P-22'
            ? 'feature.database-installed'
          : requirementId === 'P-23'
            ? 'feature.provider-workspace-installed'
          : requirementId === 'P-24'
            ? 'feature.settings-installed'
          : requirementId === 'P-25'
            ? 'feature.updates-installed'
          : requirementId === 'P-26'
            ? 'feature.tray-native-shell-installed'
          : requirementId === 'P-27'
            ? 'feature.notifications-deep-links-installed'
          : requirementId === 'P-28'
            ? 'feature.smarthub-installed'
          : requirementId === 'P-29'
            ? 'feature.text-expansion-installed'
          : requirementId === 'P-30'
            ? 'feature.pet-companion-installed'
          : requirementId === 'P-32'
            ? 'feature.performance-installed'
          : requirementId === 'P-33'
            ? 'feature.reliability-installed'
          : requirementId === 'P-35'
            ? 'feature.diagnostics-support-installed'
          : requirementId === 'P-36'
            ? 'feature.visual-interaction-polish-installed'
            : `feature.${requirementId.toLowerCase()}-proof`,
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
        : requirementId === 'P-11'
          ? 'scripts/linux-port/capture-p11-usage-ingestion-proof.mjs'
        : requirementId === 'P-12'
          ? 'scripts/linux-port/capture-p12-quota-proof.mjs'
        : requirementId === 'P-13'
          ? 'scripts/linux-port/capture-p13-onboarding-proof.mjs'
        : requirementId === 'P-14'
          ? 'scripts/linux-port/capture-p14-chat-proof.mjs'
        : requirementId === 'P-15'
          ? 'scripts/linux-port/capture-p15-account-billing-proof.mjs'
        : requirementId === 'P-16'
          ? 'scripts/linux-port/capture-p16-cloud-devices-proof.mjs'
          : requirementId === 'P-17'
          ? 'scripts/linux-port/capture-p17-activity-proof.mjs'
        : requirementId === 'P-18'
          ? 'scripts/linux-port/capture-p18-memory-review-proof.mjs'
        : requirementId === 'P-19'
          ? 'scripts/linux-port/capture-p19-projects-proof.mjs'
        : requirementId === 'P-20'
          ? 'scripts/linux-port/capture-p20-missions-proof.mjs'
        : requirementId === 'P-21'
          ? 'scripts/linux-port/capture-p21-insights-proof.mjs'
        : requirementId === 'P-22'
          ? 'scripts/linux-port/capture-p22-database-proof.mjs'
        : requirementId === 'P-23'
          ? 'scripts/linux-port/capture-p23-provider-workspace-proof.mjs'
        : requirementId === 'P-24'
          ? 'scripts/linux-port/capture-p24-settings-proof.mjs'
        : requirementId === 'P-25'
          ? 'scripts/linux-port/capture-p25-updates-proof.mjs'
        : requirementId === 'P-26'
          ? 'scripts/linux-port/capture-p26-tray-proof.mjs'
        : requirementId === 'P-27'
          ? 'scripts/linux-port/capture-p27-notifications-proof.mjs'
        : requirementId === 'P-28'
          ? 'scripts/linux-port/capture-p28-smarthub-proof.mjs'
        : requirementId === 'P-29'
          ? 'scripts/linux-port/capture-p29-text-expansion-proof.mjs'
        : requirementId === 'P-30'
          ? 'scripts/linux-port/capture-p30-pet-proof.mjs'
        : requirementId === 'P-32'
          ? 'scripts/linux-port/capture-p32-performance-proof.mjs'
        : requirementId === 'P-33'
          ? 'scripts/linux-port/capture-p33-reliability-proof.mjs'
        : requirementId === 'P-35'
          ? 'scripts/linux-port/capture-p35-diagnostics-support-proof.mjs'
        : requirementId === 'P-36'
          ? 'scripts/linux-port/capture-p36-visual-polish-proof.mjs'
        : requirementId === 'P-02'
          ? 'scripts/linux-port/capture-parity-certification-preflight.mjs'
          : `scripts/linux-port/capture-${requirementId.toLowerCase()}.mjs`;
      const materializerProducerPath = RELEASE_ONLY.has(requirementId)
        ? 'scripts/linux-port/prepare-product-requirement-input.mjs'
        : requirementId === 'P-39'
          ? 'scripts/linux-port/prepare-product-requirement-input.mjs'
        : featureRequirements.includes(requirementId)
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
            : ['P-02', 'P-11', 'P-12', 'P-13', 'P-14', 'P-15', 'P-16', 'P-17', 'P-18', 'P-19', 'P-20', 'P-21', 'P-22', 'P-23', 'P-24', 'P-25', 'P-26', 'P-27', 'P-28', 'P-29', 'P-30', 'P-32', 'P-33', 'P-35', 'P-36'].includes(requirementId)
              ? '.github/workflows/linux-product-parity.yml'
              : `.github/workflows/${requirementId.toLowerCase()}-capture.yml`,
          testPath,
          testName: `${requirementId} capture executes`
        },
        materializer: {
          producerPath: materializerProducerPath,
          entrypoint: 'requirement',
          workflowPath: RELEASE_ONLY.has(requirementId) || featureRequirements.includes(requirementId) || requirementId === 'P-39'
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
  git(root, ['config', 'gc.auto', '0']);
  const requirements = requirementsManifest();
  writeJson(root, 'docs/linux-port/product-parity-requirements.json', requirements);
  writeJson(root, 'docs/linux-port/product-parity-evidence-policies.json', policies(requirements));
  writeJson(root, 'docs/linux-port/product-feature-proof-registry.json', registry(complete));
  write(root, '.gitignore', 'docs/linux-port/evidence/\n');
  for (const schema of [
    'schemas/linux-parity-certification-preflight.schema.json',
    'schemas/linux-product-feature-proof-registry.schema.json'
  ]) write(root, schema, fs.readFileSync(path.join(SOURCE_ROOT, schema)));
  const validatorIds = REQUIREMENT_IDS;
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
  const { testExecutions: overriddenExecutions, ...remainingOverrides } = overrides;
  let executions = overriddenExecutions;
  if (executions === undefined) {
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
    executions = [];
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
    ...remainingOverrides
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

test('ownership-ready fixture authenticates all 40 requirement lanes', async (t) => {
  const fixture = await getSharedOwnershipFixture();
  assertSharedOwnershipFixture(fixture);
  try {
    const subject = privateCloneSubject(t, fixture);
    const captured = capture(subject, {
      testExecutions: cloneRows(fixture.fourWorkerRows)
    });
    const p39 = captured.document.requirements.find((row) => row.requirementId === 'P-39');
    const p11 = captured.document.requirements.find((row) => row.requirementId === 'P-11');
    const p12 = captured.document.requirements.find((row) => row.requirementId === 'P-12');
    const p13 = captured.document.requirements.find((row) => row.requirementId === 'P-13');
    const p14 = captured.document.requirements.find((row) => row.requirementId === 'P-14');
    const p17 = captured.document.requirements.find((row) => row.requirementId === 'P-17');
    const p18 = captured.document.requirements.find((row) => row.requirementId === 'P-18');
    const p19 = captured.document.requirements.find((row) => row.requirementId === 'P-19');
    const p20 = captured.document.requirements.find((row) => row.requirementId === 'P-20');
    const p21 = captured.document.requirements.find((row) => row.requirementId === 'P-21');
    const p22 = captured.document.requirements.find((row) => row.requirementId === 'P-22');
    const p23 = captured.document.requirements.find((row) => row.requirementId === 'P-23');
    const p24 = captured.document.requirements.find((row) => row.requirementId === 'P-24');
    const p25 = captured.document.requirements.find((row) => row.requirementId === 'P-25');
    const p26 = captured.document.requirements.find((row) => row.requirementId === 'P-26');
    const p27 = captured.document.requirements.find((row) => row.requirementId === 'P-27');
    const p28 = captured.document.requirements.find((row) => row.requirementId === 'P-28');
    const p29 = captured.document.requirements.find((row) => row.requirementId === 'P-29');
    const p30 = captured.document.requirements.find((row) => row.requirementId === 'P-30');
    const p32 = captured.document.requirements.find((row) => row.requirementId === 'P-32');
    assert.equal(p39.ready, true, JSON.stringify(p39));
    assert.equal(p11.ready, true, JSON.stringify(p11));
    assert.equal(p12.ready, true, JSON.stringify(p12));
    assert.equal(p13.ready, true, JSON.stringify(p13));
    assert.equal(p14.ready, true, JSON.stringify(p14));
    assert.equal(p17.ready, true, JSON.stringify(p17));
    assert.equal(p18.ready, true, JSON.stringify(p18));
    assert.equal(p19.ready, true, JSON.stringify(p19));
    assert.equal(p20.ready, true, JSON.stringify(p20));
    assert.equal(p21.ready, true, JSON.stringify(p21));
    assert.equal(p22.ready, true, JSON.stringify(p22));
    assert.equal(p23.ready, true, JSON.stringify(p23));
    assert.equal(p24.ready, true, JSON.stringify(p24));
    assert.equal(p25.ready, true, JSON.stringify(p25));
    assert.equal(p26.ready, true, JSON.stringify(p26));
    assert.equal(p27.ready, true, JSON.stringify(p27));
    assert.equal(p28.ready, true, JSON.stringify(p28));
    assert.equal(p29.ready, true, JSON.stringify(p29));
    assert.equal(p30.ready, true, JSON.stringify(p30));
    assert.equal(p32.ready, true, JSON.stringify(p32));
    assert.equal(captured.document.status, 'passed');
    assert.equal(captured.document.summary.validatorCount, 40);
    assert.equal(captured.document.summary.captureCount, 40);
    assert.equal(captured.document.summary.materializerCount, 40);
    assert.equal(captured.document.summary.readyCount, 40, JSON.stringify(p32));
    assert.deepEqual(
      captured.document.requirements.filter((row) => !row.ready).map((row) => row.requirementId),
      []
    );
    await assert.doesNotReject(
      () => validateProductRequirement(validatorContext(subject, captured))
    );
  } finally {
    assertSharedOwnershipFixture(fixture);
  }
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

test('P-02 capture emits a passed candidate-bound diagnostic inventory', (t) => {
  const subject = createRepository({ complete: false });
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  const captured = capture(subject);
  assert.equal(captured.document.targetHead, subject.head);
  assert.equal(captured.document.candidate.runId, RUN_ID);
  assert.equal(captured.document.candidate.artifactDigest, DIGEST);
  assert.equal(captured.document.status, 'passed');
  assert.equal(captured.document.summary.readyCount, 40);
  assert.equal(fs.existsSync(captured.output), true);
});

test('inventory detects every missing, duplicate, reused, invalid, and unsupported ownership gap', async (t) => {
  const fixture = await getSharedOwnershipFixture();
  t.after(() => assertSharedOwnershipFixture(fixture));
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
    await t.test(name, (subtest) => {
      const subject = privateCloneSubject(subtest, fixture);
      mutate(subject);
      commitMutation(subject, `mutation: ${name}`);
      const captured = name === 'reused validator'
        ? capture(subject)
        : captureWithCachedFixtureRows(subject, fixture);
      assert.equal(captured.document.status, 'blocked');
      for (const code of Array.isArray(expectedCodes) ? expectedCodes : [expectedCodes]) {
        assert.ok(captured.document.blockers.some((blocker) => blocker.code === code), code);
      }
    });
  }
});

test('executed semantic mutation ownership rejects a unique no-op validator', async (t) => {
  const fixture = await getSharedOwnershipFixture();
  assertSharedOwnershipFixture(fixture);
  try {
    const subject = privateCloneSubject(t, fixture);
    const baseline = fixture.fourWorkerRows;
    assert.ok(baseline.every((entry) => entry.status === 'passed'), JSON.stringify(baseline, null, 2));
    write(subject.root, 'scripts/linux-port/product-validators/P-05.mjs',
      "export async function validateProductRequirement() { return { status: 'passed' }; }\n");
    commitMutation(subject, 'replace P-05 with semantic no-op');
    const [execution] = collectRequirementOwnershipRows(subject, 'P-05', ['validator']);
    assert.equal(execution.testName, 'P-05 semantic mutation fails closed');
    assert.equal(execution.status, 'failed');
    const mutatedRows = rowsWithRealOwnershipReplacements(fixture.fourWorkerRows, [execution]);
    assert.throws(
      () => captureParityCertificationPreflight({
        repoRoot: subject.root,
        inputRoot: subject.inputRoot,
        environmentId: ENVIRONMENT,
        targetHead: subject.head,
        candidateRunId: RUN_ID,
        candidateArtifactDigest: DIGEST,
        testExecutions: mutatedRows
      }),
      /ownership tests failed/u
    );
  } finally {
    assertSharedOwnershipFixture(fixture);
  }
});

test('bounded ownership collector rejects invalid concurrency before collection', (t) => {
  const subject = createRepository();
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  for (const value of ['0', '9', '1.5', 'abc']) {
    withCollectorConcurrency(value, () => {
      assert.throws(
        () => collectCertificationTestExecutions(subject.root, subject.head),
        /must be an integer between 1 and 8/u,
        value
      );
    });
  }
});

test('bounded ownership collector is deterministic and isolates semantic mutations across concurrency', async () => {
  const fixture = await getSharedOwnershipFixture();
  assertSharedOwnershipFixture(fixture);
  try {
    const single = fixture.oneWorkerRows;
    const quad = fixture.fourWorkerRows;
    assert.deepEqual(quad, single);
    assert.equal(single.length, 120);
    assert.equal(new Set(single.map((row) => `${row.requirementId}:${row.component}`)).size, 120);
    assert.ok(single.every((row) => row.status === 'passed'), JSON.stringify(
      single.filter((row) => row.status !== 'passed'), null, 2
    ));
    assert.ok(single.every((row) => row.mutationDetected === true));
    for (const [relativePath, bytes] of fixture.savedBytes) {
      assert.ok(bytes.equals(fs.readFileSync(path.join(fixture.subject.root, relativePath))), relativePath);
    }
  } finally {
    assertSharedOwnershipFixture(fixture);
  }
});

test('paired no-op ownership, duplicate tests, workflow comments, and untracked imports fail closed', async (t) => {
  const fixture = await getSharedOwnershipFixture();
  t.after(() => assertSharedOwnershipFixture(fixture));

  await t.test('paired no-op validator and ownership test cannot authenticate fabricated passing executions', (subtest) => {
    const subject = privateCloneSubject(subtest, fixture);
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
    assert.ok(fabricated.document.testExecutions.every((entry) => entry.status === 'passed'),
      'caller-substituted rows claim the mutated target passed');
    assert.throws(() => validateParityCertificationPreflight(fabricated.document, {
      repoRoot: subject.root,
      targetHead: subject.head,
      environmentId: ENVIRONMENT,
      materializedProofPath: `${subject.inputRelative}/release-subjects/proof.json`,
      candidate: fabricated.document.candidate
    }), /independent target-commit ownership test execution failed/u);
  });

  await t.test('duplicate ownership test registration is rejected', (subtest) => {
    const subject = privateCloneSubject(subtest, fixture);
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

  await t.test('a YAML comment mentioning the producer is not executable workflow wiring', (subtest) => {
    const subject = privateCloneSubject(subtest, fixture);
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
    await t.test(`${name} is not executable workflow wiring`, (subtest) => {
      const subject = privateCloneSubject(subtest, fixture);
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

  await t.test('a producer command in an unrelated step is not executable workflow wiring', (subtest) => {
    const subject = privateCloneSubject(subtest, fixture);
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

  await t.test('an untracked imported helper cannot influence isolated target execution', (subtest) => {
    const subject = privateCloneSubject(subtest, fixture);
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
    const executions = collectRequirementOwnershipRows(subject, 'P-05');
    assert.equal(executions.length, 3);
    assert.ok(executions.every((entry) => entry.status === 'failed'));
  });

  await t.test('a committed target symlink cannot escape isolated ownership execution', (subtest) => {
    const subject = privateCloneSubject(subtest, fixture);
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

test('P-15/P-16/P-33/P-35/P-36 canonical workflow blocks reject mutations', async (t) => {
  const fixture = await getSharedOwnershipFixture();
  t.after(() => assertSharedOwnershipFixture(fixture));
  for (const requirementId of ['P-15', 'P-16', 'P-33', 'P-35', 'P-36']) {
    const subject = privateCloneSubject(t, fixture);
    const ownership = registry().certification.find((row) =>
      row.requirementId === requirementId
    ).capture;
    const workflow = path.join(subject.root, ownership.workflowPath);
    const invocation = `node ${ownership.producerPath}`;
    const original = fs.readFileSync(workflow, 'utf8');
    assert.equal(original.split(invocation).length - 1, 1);
    write(subject.root, ownership.workflowPath,
      original.replace(invocation, `${invocation} --tampered`));
    commitMutation(subject, `mutate ${requirementId} canonical workflow block`);
    const captured = captureWithCachedFixtureRows(subject, fixture);
    const row = captured.document.requirements.find((entry) =>
      entry.requirementId === requirementId
    );
    assert.equal(row.capture.status, 'invalid');
    assert.equal(row.ready, false);
  }
});

test('capture failure always leaves an uploadable non-promotable diagnostic', async (t) => {
  const fixture = await getSharedOwnershipFixture();
  t.after(() => assertSharedOwnershipFixture(fixture));
  const subject = privateCloneSubject(t, fixture);
  const runnerTemporaryRoot = fs.realpathSync(process.env.RUNNER_TEMP ?? os.tmpdir());
  const diagnosticRoot = fs.mkdtempSync(path.join(runnerTemporaryRoot, 'openburnbar-p02-diagnostic-test-'));
  t.after(() => fs.rmSync(diagnosticRoot, { recursive: true, force: true }));
  write(subject.root, '.linux-parity-diagnostics', 'hostile repository path\n');
  const failedExecutions = cloneRows(fixture.fourWorkerRows).map((entry, index) =>
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

test('uncommitted target inventory and validator substitutions cannot affect the commit snapshot', async (t) => {
  const fixture = await getSharedOwnershipFixture();
  t.after(() => assertSharedOwnershipFixture(fixture));
  const subject = privateCloneSubject(t, fixture);
  const baseline = captureWithCachedFixtureRows(subject, fixture);
  mutateJson(subject.root, 'docs/linux-port/product-parity-requirements.json', (value) => {
    value.requirements = value.requirements.filter((row) => row.id !== 'P-05');
  });
  write(subject.root, 'scripts/linux-port/product-validators/P-05.mjs',
    "export async function validateProductRequirement() { return { status: 'passed' }; }\n");
  const recaptured = captureWithCachedFixtureRows(subject, fixture);
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
  const fixture = await getSharedOwnershipFixture();
  t.after(() => assertSharedOwnershipFixture(fixture));

  await t.test('stale candidate after a new target commit', (subtest) => {
    const subject = privateCloneSubject(subtest, fixture);
    write(subject.root, 'target-change.txt', 'new target bytes\n');
    commitMutation(subject, 'new target', { syncCandidate: false, updateAggregateTarget: false });
    const captured = captureWithCachedFixtureRows(subject, fixture);
    assert.equal(captured.document.status, 'blocked');
    assert.ok(captured.document.blockers.some((blocker) => blocker.code === 'stale-candidate'));
  });
  await t.test('candidate substitution', (subtest) => {
    const subject = privateCloneSubject(subtest, fixture);
    const captured = captureWithCachedFixtureRows(subject, fixture);
    assert.throws(() => validateParityCertificationPreflight(captured.document, {
      repoRoot: subject.root,
      targetHead: subject.head,
      environmentId: ENVIRONMENT,
      materializedProofPath: `${subject.inputRelative}/release-subjects/proof.json`,
      candidate: { ...captured.document.candidate, artifactDigest: `sha256:${'c'.repeat(64)}` }
    }), /stale, substituted, or not bound/u);
  });
  await t.test('unowned test execution', (subtest) => {
    const subject = privateCloneSubject(subtest, fixture);
    const captured = captureWithCachedFixtureRows(subject, fixture);
    const independentRows = cloneRows(captured.document.testExecutions);
    captured.document.testExecutions.push({
      ...captured.document.testExecutions[0],
      testName: 'unowned passing test'
    });
    assert.throws(
      () => assertOwnershipRowsAuthenticated(captured.document.testExecutions, independentRows),
      /not independently authenticated/u
    );
  });
  await t.test('stale candidate registry', (subtest) => {
    const subject = privateCloneSubject(subtest, fixture);
    mutateFeatureRegistry(subject, (value) => {
      value.requirements.find((row) => row.requirementId === 'P-05').artifacts[0].maxBytes -= 1;
    }, { syncCandidate: false });
    commitMutation(subject, 'mutate target registry', { syncCandidate: false });
    const captured = captureWithCachedFixtureRows(subject, fixture);
    assert.equal(captured.document.status, 'blocked');
    assert.ok(captured.document.blockers.some((blocker) => blocker.code === 'stale-candidate-registry'));
  });
  await t.test('self-referential inventory source', (subtest) => {
    const subject = privateCloneSubject(subtest, fixture);
    const captured = captureWithCachedFixtureRows(subject, fixture);
    captured.document.sources.requirementsManifest.path = captured.document.proofPath;
    assert.throws(() => validateParityCertificationPreflight(captured.document, {
      repoRoot: subject.root,
      targetHead: subject.head,
      environmentId: ENVIRONMENT,
      materializedProofPath: `${subject.inputRelative}/release-subjects/proof.json`,
      candidate: captured.document.candidate
    }), /self-referential/u);
  });
  await t.test('materialized proof self-reference', (subtest) => {
    const subject = privateCloneSubject(subtest, fixture);
    const captured = captureWithCachedFixtureRows(subject, fixture);
    assert.throws(() => validateParityCertificationPreflight(captured.document, {
      repoRoot: subject.root,
      targetHead: subject.head,
      environmentId: ENVIRONMENT,
      materializedProofPath: captured.document.proofPath,
      candidate: captured.document.candidate
    }), /self-referential/u);
  });
});
