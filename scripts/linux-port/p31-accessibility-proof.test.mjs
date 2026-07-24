import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { captureP31Accessibility } from './capture-p31-accessibility.mjs';
import { main as finalizeProductFeatureProofClosure } from './finalize-product-feature-proof-closure.mjs';
import { validateProductRequirement } from './product-validators/P-31.mjs';
import {
  P31_REQUIRED_ROUTES,
  P31_ROLES,
  validateP31LiveSession,
  validateP31Proof
} from './lib/p31-accessibility-proof.mjs';
import { readRegularSnapshot } from './lib/product-proof-closure.mjs';
import { validateFeatureProofRegistry } from './lib/product-feature-proof.mjs';

const ENVIRONMENT = 'ubuntu-24.04-gnome-wayland-x86_64';
const TARGET_HEAD = 'a'.repeat(40);
const CANDIDATE_RUN_ID = '12345';
const CANDIDATE_ARTIFACT_DIGEST = `sha256:${'b'.repeat(64)}`;
const VERSION = '1.2.3';
const FEATURE_ROOT = 'docs/linux-port/evidence/product-parity-inputs/P-31';

function write(file, contents) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, contents);
  return file;
}

function writeJson(file, value) {
  return write(file, `${JSON.stringify(value, null, 2)}\n`);
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function initRepo() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-p31-'));
  execFileSync('git', ['init', '-q'], { cwd: root });
  execFileSync('git', ['config', 'user.name', 'OpenBurnBar P31 Test'], { cwd: root });
  execFileSync('git', ['config', 'user.email', 'p31@openburnbar.invalid'], { cwd: root });
  write(root + '/anchor.txt', 'p31\n');
  execFileSync('git', ['add', 'anchor.txt'], { cwd: root });
  execFileSync('git', ['commit', '-qm', 'p31 fixture'], { cwd: root });
  return root;
}

function currentHead(root) {
  return execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
}

function liveSession({ targetHead = TARGET_HEAD, exactScale = true } = {}) {
  return {
    schemaVersion: 1,
    id: 'openburnbar-linux-p31-live-session-v1',
    requirementId: 'P-31',
    environmentId: ENVIRONMENT,
    targetHead,
    candidate: { runId: CANDIDATE_RUN_ID, artifactDigest: CANDIDATE_ARTIFACT_DIGEST },
    package: {
      architecture: 'x86_64',
      format: 'deb',
      installed: true,
      manifestSha256: 'c'.repeat(64),
      source: 'signed-installed-candidate',
      version: VERSION
    },
    desktop: {
      compositor: 'mutter-live',
      desktop: 'GNOME',
      liveSession: true,
      session: 'Wayland'
    },
    observations: {
      scale: {
        accessibilityTreeObserved: true,
        clippedCount: 0,
        exactScaleObservable: exactScale,
        evidencePaths: ['screenshots/overview-200.png', 'atspi/overview-200.json'],
        focusPreserved: true,
        horizontalScrollbars: 0,
        method: 'installed-WebKitGTK live desktop zoom',
        observedPercent: exactScale ? 200 : 199,
        overflowCount: 0,
        reflowPass: exactScale,
        requestedPercent: 200
      },
      contrast: {
        evidencePaths: ['screenshots/forced-colors.png', 'screenshots/high-contrast.png', 'screenshots/no-color.png'],
        forcedColors: { evidencePath: 'screenshots/forced-colors.png', mode: 'forced-colors', observed: true, pass: true, test: 'CSS forced-colors media query and computed colors' },
        highContrast: { evidencePath: 'screenshots/high-contrast.png', mode: 'high-contrast', observed: true, pass: true, test: 'GNOME high-contrast setting and visual review' },
        method: 'installed-live contrast modes',
        noColor: { evidencePath: 'screenshots/no-color.png', mode: 'no-color', observed: true, pass: true, test: 'essential labels and controls remain distinguishable without color' },
        semanticContrastPass: true
      },
      motion: {
        animationsObserved: 0,
        evidencePaths: ['atspi/reduced-motion.json', 'screenshots/reduced-motion.png'],
        mediaQuery: '(prefers-reduced-motion: reduce)',
        method: 'installed-live motion preferences',
        reducedMotion: { enabled: true, observed: true, pass: true },
        runtimeStylesPass: true,
        transitionsObserved: 0
      },
      assistiveTech: {
        evidencePaths: ['atspi/focus-sequence.json', 'orca/announcements.txt', 'screenshots/keyboard-only.png'],
        keyboard: {
          distinctFocusedTargets: 5,
          focusTrap: false,
          namedFocusedTargets: 5,
          pass: true,
          physicalKeyPressCount: 14,
          stepCount: 10
        },
        liveRegionsAnnounced: true,
        method: 'installed-live Orca AT-SPI keyboard traversal',
        routesCovered: [...P31_REQUIRED_ROUTES],
        screenReader: {
          announcementsObserved: true,
          name: 'Orca',
          processObserved: true,
          treeObserved: true
        }
      }
    }
  };
}

function stageCapture(root, { exactScale = true } = {}) {
  const inputRoot = path.join(root, FEATURE_ROOT, ENVIRONMENT);
  const head = currentHead(root);
  const session = liveSession({ targetHead: head, exactScale });
  const report = path.join(inputRoot, 'p31-live-session.json');
  writeJson(report, session);
  const evidencePaths = new Set();
  for (const observation of Object.values(session.observations)) {
    for (const evidencePath of observation.evidencePaths ?? []) evidencePaths.add(evidencePath);
    for (const nested of Object.values(observation)) {
      if (nested && typeof nested === 'object' && Array.isArray(nested.evidencePaths)) {
        for (const evidencePath of nested.evidencePaths) evidencePaths.add(evidencePath);
      }
    }
  }
  for (const evidencePath of evidencePaths) write(path.join(inputRoot, evidencePath), 'live evidence\n');
  const result = captureP31Accessibility({
    repoRoot: root,
    inputRoot,
    sessionReport: report,
    environmentId: ENVIRONMENT,
    targetHead: head,
    candidateRunId: CANDIDATE_RUN_ID,
    candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST
  });
  return { root, inputRoot, head, result, session };
}

function closureContext(staged) {
  const { inputRoot, head } = staged;
  const root = staged.root;
  const relative = (file) => path.relative(root, file).split(path.sep).join('/');
  const manifest = writeJson(path.join(inputRoot, 'installed-manifest.json'), {
    gitCommit: head, packageArchitecture: 'x86_64', packageFormat: 'deb', packageVersion: VERSION
  });
  const manifestSignature = write(path.join(inputRoot, 'installed-manifest.json.sig'), 'signed manifest');
  const runtime = writeJson(path.join(inputRoot, 'runtime.json'), { shellVersion: VERSION, daemonVersion: VERSION });
  const environment = writeJson(path.join(inputRoot, 'environment.json'), {
    environmentId: ENVIRONMENT, targetHead: head, architecture: 'x86_64', passed: true
  });
  const aggregate = writeJson(path.join(inputRoot, 'aggregate.json'), { passed: true });
  const packageFile = write(path.join(inputRoot, 'OpenBurnBar.deb'), 'package');
  const featureFiles = P31_ROLES.map((role) => {
    const name = role.slice('feature.'.length).replaceAll('.', '-');
    const file = path.join(inputRoot, `feature-artifacts/p31-${name}.json`);
    return { role, path: relative(file), sha256: sha256(file), mediaType: 'application/json', evidenceClass: 'feature' };
  });
  const closure = {
    schemaVersion: 3,
    targetHead: head,
    sourceCommit: head,
    status: 'passed',
    requirementId: 'P-31',
    environmentId: ENVIRONMENT,
    version: VERSION,
    candidate: { runId: CANDIDATE_RUN_ID, artifactDigest: CANDIDATE_ARTIFACT_DIGEST },
    architectures: ['aarch64', 'x86_64'],
    supportEnvironments: [
      'ubuntu-24.04-gnome-x11-x86_64', 'ubuntu-24.04-gnome-x11-aarch64',
      'ubuntu-24.04-gnome-wayland-x86_64', 'ubuntu-24.04-gnome-wayland-aarch64',
      'fedora-kde-wayland-x86_64', 'fedora-kde-wayland-aarch64', 'arch-sway-wayland-x86_64'
    ],
    selectedPackage: { architecture: 'x86_64', format: 'deb' },
    packageManifestSignature: { path: relative(manifestSignature), sha256: sha256(manifestSignature) },
    proofs: [
      { role: 'aggregate-product-proof-closure', path: relative(aggregate), sha256: sha256(aggregate) },
      ...featureFiles
    ],
    packages: [{ path: relative(packageFile), sha256: sha256(packageFile) }],
    blockers: []
  };
  const release = writeJson(path.join(inputRoot, 'release-closure.json'), closure);
  const record = (file) => ({ path: relative(file), sha256: sha256(file) });
  const context = {
    schemaVersion: 1,
    repoRoot: root,
    requirementId: 'P-31',
    checkId: 'p-31.accessibility',
    environmentId: ENVIRONMENT,
    targetHead: head,
    releaseClosure: { path: relative(release), sha256: sha256(release), document: closure },
    subjects: {
      release: record(release),
      packageManifest: record(manifest),
      packageManifestSignature: record(manifestSignature),
      packages: [record(packageFile)],
      features: featureFiles.map(({ role, path: featurePath, sha256: featureSha }) => ({
        role, mediaType: 'application/json', path: featurePath, sha256: featureSha
      })),
      runtimes: [record(runtime)],
      installation: [],
      environment: record(environment)
    }
  };
  return { context, featureFiles };
}

test('P-31 capture emits four candidate-bound accessibility proofs', () => {
  const root = initRepo();
  const staged = stageCapture(root);
  assert.equal(staged.result.registration.artifacts.length, 4);
  assert.deepEqual(staged.result.registration.artifacts.map((row) => row.role), [...P31_ROLES]);
  for (const row of staged.result.registration.artifacts) {
    const proof = JSON.parse(fs.readFileSync(path.join(staged.inputRoot, row.path), 'utf8'));
    validateP31Proof(proof, {
      role: row.role,
      environmentId: ENVIRONMENT,
      targetHead: staged.head,
      candidateRunId: CANDIDATE_RUN_ID,
      candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST
    });
  }
});

test('P-31 capture rejects symlinked session reports and removes stale registrations', () => {
  const root = initRepo();
  const staged = stageCapture(root);
  const outside = path.join(root, 'outside-session.json');
  writeJson(outside, liveSession({ targetHead: staged.head }));
  const linked = path.join(staged.inputRoot, 'linked-session.json');
  fs.symlinkSync(outside, linked);
  assert.throws(() => captureP31Accessibility({
    repoRoot: root,
    inputRoot: staged.inputRoot,
    sessionReport: linked,
    environmentId: ENVIRONMENT,
    targetHead: staged.head,
    candidateRunId: CANDIDATE_RUN_ID,
    candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST
  }), /symlink|regular|session report/u);
  assert.equal(fs.existsSync(path.join(staged.inputRoot, 'feature-proof-registration.json')), false);
  assert.equal(fs.existsSync(path.join(staged.inputRoot, 'feature-artifacts/p31-accessibility-scale.json')), false);
});

test('P-31 independently rejects an accessibility proof missing exact 200 percent reflow', async () => {
  const root = initRepo();
  const staged = stageCapture(root);
  const { context, featureFiles } = closureContext(staged);
  const passed = await validateProductRequirement(context);
  assert.equal(passed.status, 'passed');
  const scale = featureFiles.find((row) => row.role === 'feature.accessibility-scale');
  const scaleFile = path.join(root, scale.path);
  const mutated = JSON.parse(fs.readFileSync(scaleFile, 'utf8'));
  mutated.claim.observedPercent = 199;
  fs.writeFileSync(scaleFile, `${JSON.stringify(mutated, null, 2)}\n`);
  const mutatedHash = sha256(scaleFile);
  const row = context.subjects.features.find((candidate) => candidate.role === scale.role);
  row.sha256 = mutatedHash;
  const closureRow = context.releaseClosure.document.proofs.find((candidate) => candidate.role === scale.role);
  closureRow.sha256 = mutatedHash;
  await assert.rejects(() => validateProductRequirement(context), /exact 200|reflow/u);
});

test('P-31 materializer selects accessibility feature proofs', () => {
  assert.throws(() => finalizeProductFeatureProofClosure([]), /--requirement is required/u);
  const registry = JSON.parse(fs.readFileSync('docs/linux-port/product-feature-proof-registry.json', 'utf8'));
  const snapshot = readRegularSnapshot('.', 'docs/linux-port/product-feature-proof-registry.json', 'P-31 registry');
  const { contracts } = validateFeatureProofRegistry('.', snapshot);
  const contract = contracts.get('P-31');
  assert.ok(contract);
  assert.deepEqual(contract.artifacts.map((row) => row.role), [...P31_ROLES]);
  assert.match(fs.readFileSync('scripts/linux-port/prepare-product-requirement-input.mjs', 'utf8'), /featureProofClosure/);
  assert.equal(registry.requirements.some((row) => row.requirementId === 'P-31'), true);
});

test('P-31 source session validator fails closed on approximate zoom', () => {
  const source = liveSession();
  source.observations.scale.exactScaleObservable = false;
  source.observations.scale.reflowPass = false;
  source.observations.scale.observedPercent = 199;
  assert.throws(() => validateP31LiveSession(source, {
    environmentId: ENVIRONMENT,
    targetHead: TARGET_HEAD,
    candidateRunId: CANDIDATE_RUN_ID,
    candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST
  }), /exact 200/u);
});
