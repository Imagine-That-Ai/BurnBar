import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { captureP31Accessibility } from './capture-p31-accessibility.mjs';
import { main as finalizeProductFeatureProofClosure } from './finalize-product-feature-proof-closure.mjs';
import { validateProductRequirement } from './product-validators/P-31.mjs';
import {
  P31_ENVIRONMENTS,
  P31_REQUIRED_ROUTES,
  P31_ROLES,
  validateP31LiveSession,
  validateP31Proof
} from './lib/p31-accessibility-proof.mjs';
import {
  applyDesktopAccessibilityPreferences,
  buildP31LiveSession,
  detectYdotoolDialect,
  discoverP31GraphicalSessionId,
  openP31OrcaLog,
  P31_LIVE_ENVIRONMENTS,
  parseP31LiveArguments,
  parseKScreenOutputs,
  parseSwayOutputs,
  validateP31HostIdentity
} from './run-p31-live-accessibility-session.mjs';
import { readRegularSnapshot } from './lib/product-proof-closure.mjs';
import { validateFeatureProofRegistry } from './lib/product-feature-proof.mjs';

const ENVIRONMENT = 'ubuntu-24.04-gnome-wayland-x86_64';
const TARGET_HEAD = 'a'.repeat(40);
const CANDIDATE_RUN_ID = '12345';
const CANDIDATE_ARTIFACT_DIGEST = `sha256:${'b'.repeat(64)}`;
const VERSION = '1.2.3';
const FEATURE_ROOT = 'docs/linux-port/evidence/product-parity-inputs/P-31';
const X11_ARM_ENVIRONMENT = 'ubuntu-24.04-gnome-x11-aarch64';
const CANONICAL_ENVIRONMENTS = Object.keys(P31_ENVIRONMENTS);

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

function hostIdentityFixture(environmentId) {
  const profile = P31_LIVE_ENVIRONMENTS[environmentId];
  const environment = {
    XDG_SESSION_TYPE: profile.session.toLowerCase(),
    XDG_CURRENT_DESKTOP: profile.desktop,
    DBUS_SESSION_BUS_ADDRESS: 'unix:path=/run/user/1000/bus',
    XDG_RUNTIME_DIR: '/run/user/1000'
  };
  if (profile.session === 'X11') environment.DISPLAY = ':0';
  else environment.WAYLAND_DISPLAY = 'wayland-0';
  return {
    environmentId,
    platform: 'linux',
    architecture: profile.architecture,
    release: {
      ID: profile.osId,
      ...(profile.versionId === null ? {} : { VERSION_ID: profile.versionId })
    },
    environment,
    loginctl: {
      Type: profile.session.toLowerCase(),
      Desktop: profile.desktop,
      Active: 'yes',
      Remote: 'no',
      Class: 'user',
      State: 'active'
    },
    compositorIdentity: `${profile.compositor} live compositor`,
    waylandSocketIsReal: profile.session === 'Wayland' ? true : null
  };
}

test('P-31 live producer admits every canonical identity and binds it to the real host', () => {
  assert.deepEqual(Object.keys(P31_LIVE_ENVIRONMENTS), CANONICAL_ENVIRONMENTS);
  for (const environmentId of CANONICAL_ENVIRONMENTS) {
    const profile = P31_LIVE_ENVIRONMENTS[environmentId];
    assert.deepEqual(validateP31HostIdentity(hostIdentityFixture(environmentId)), {
      environmentId,
      architecture: profile.architecture,
      desktop: profile.desktop,
      session: profile.session,
      compositor: profile.compositor
    });
  }

  const x11 = hostIdentityFixture('ubuntu-24.04-gnome-x11-aarch64');
  const wayland = hostIdentityFixture('ubuntu-24.04-gnome-wayland-x86_64');
  const kde = hostIdentityFixture('fedora-kde-wayland-x86_64');
  const sway = hostIdentityFixture('arch-sway-wayland-x86_64');
  for (const invalid of [
    { ...x11, architecture: 'x86_64' },
    { ...x11, release: { ID: 'fedora' } },
    { ...x11, environment: { ...x11.environment, XDG_CURRENT_DESKTOP: 'XFCE' } },
    { ...x11, environment: { ...x11.environment, DISPLAY: 'Xvfb:99' } },
    { ...wayland, waylandSocketIsReal: false },
    { ...kde, compositorIdentity: 'Mutter' },
    { ...sway, loginctl: { ...sway.loginctl, Remote: 'yes' } }
  ]) {
    assert.throws(() => validateP31HostIdentity(invalid), /P-31/u);
  }
});

function liveArguments(environmentId) {
  const profile = P31_LIVE_ENVIRONMENTS[environmentId];
  return [
    '--output-root', '/repo/input',
    '--raw-output-dir', '/repo/input/p31-live',
    '--state-home', '/tmp/p31-home',
    '--environment', environmentId,
    '--target-head', TARGET_HEAD,
    '--candidate-run-id', CANDIDATE_RUN_ID,
    '--candidate-artifact-digest', CANDIDATE_ARTIFACT_DIGEST,
    '--package-version', VERSION,
    '--manifest-sha256', 'c'.repeat(64),
    '--manifest-signature-sha256', 'd'.repeat(64),
    '--compositor', profile.compositor
  ];
}

test('P-31 live producer binds every canonical invocation and rejects unsupported substitution', () => {
  for (const environmentId of CANONICAL_ENVIRONMENTS) {
    assert.equal(parseP31LiveArguments(liveArguments(environmentId)).environmentId, environmentId);
  }
  const substituted = liveArguments(X11_ARM_ENVIRONMENT);
  substituted[substituted.indexOf('--environment') + 1] = 'debian-gnome-x11-aarch64';
  assert.throws(() => parseP31LiveArguments(substituted), /canonical environment/u);
  const wrongCompositor = liveArguments('fedora-kde-wayland-x86_64');
  wrongCompositor[wrongCompositor.indexOf('--compositor') + 1] = 'Mutter';
  assert.throws(() => parseP31LiveArguments(wrongCompositor), /requires the KWin/u);
  const values = liveArguments(X11_ARM_ENVIRONMENT);
  const approximate = [...values];
  approximate[approximate.indexOf('--manifest-sha256') + 1] = 'not-a-digest';
  assert.throws(() => parseP31LiveArguments(approximate), /candidate binding/u);
});

test('P-31 Orca log snapshot remains descriptor-bound across path replacement', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-p31-orca-log-'));
  const log = path.join(root, 'orca-debug.log');
  const moved = path.join(root, 'orca-debug.original.log');
  const outside = path.join(root, 'outside.log');
  try {
    fs.writeFileSync(log, 'baseline\n', { mode: 0o600 });
    const snapshot = openP31OrcaLog(log);
    assert.equal(snapshot.offset, Buffer.byteLength('baseline\n'));
    fs.renameSync(log, moved);
    fs.appendFileSync(moved, 'focused\n');
    fs.writeFileSync(log, 'replacement\n', { mode: 0o600 });
    assert.equal(snapshot.read().toString('utf8'), 'baseline\nfocused\n');
    snapshot.close();
    snapshot.close();
    assert.throws(() => snapshot.read(), /descriptor is closed/u);

    fs.writeFileSync(outside, 'outside\n', { mode: 0o600 });
    fs.rmSync(log);
    fs.symlinkSync(outside, log);
    assert.throws(() => openP31OrcaLog(log), /ELOOP|symbolic link|symlink/u);
    fs.rmSync(log);
    fs.writeFileSync(log, 'broad\n', { mode: 0o644 });
    assert.throws(() => openP31OrcaLog(log), /owner-only regular file/u);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

function liveProducerFixture(environmentId = X11_ARM_ENVIRONMENT) {
  const profile = P31_LIVE_ENVIRONMENTS[environmentId];
  const outputRoot = '/repo/input';
  const rawDir = '/repo/input/p31-live';
  const options = {
    outputRoot,
    rawOutputDir: rawDir,
    stateHome: '/tmp/p31-home',
    environmentId,
    targetHead: TARGET_HEAD,
    candidateRunId: CANDIDATE_RUN_ID,
    candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST,
    packageVersion: VERSION,
    manifestSha256: 'c'.repeat(64),
    manifestSignatureSha256: 'd'.repeat(64),
    compositor: profile.compositor
  };
  const navigation = {
    routes: P31_REQUIRED_ROUTES.map((route) => ({ route, atspi: `route-${route}-atspi.json` }))
  };
  const driverEvidence = {
    runtime: {
      dpr: 2,
      viewport: { width: 800, height: 600 },
      forcedColors: true,
      reducedMotion: true,
      animationsObserved: 0,
      transitionsObserved: 0,
      liveRegionCount: 2,
      namedControlCount: 8,
      horizontalScrollbars: 0
    },
    routeAudits: P31_REQUIRED_ROUTES.map((route) => ({
      route,
      routeIdentity: {
        hash: `#/${route}`,
        label: {
          overview: 'Overview',
          insights: 'Insights',
          database: 'Database',
          providers: 'Providers & models',
          projects: 'Projects',
          missions: 'Missions',
          activity: 'Activity & logs',
          chat: 'Chat / Hermes',
          memory: 'Memory',
          settings: 'Settings',
          account: 'Account & sync',
          updates: 'Updates',
          support: 'Support & diagnostics',
          onboarding: 'First-run setup',
          pet: 'Pet companion',
          'text-expansion': 'Text expansion',
          'computer-use': 'Computer Use',
          mercury: 'Mercury',
          smarthub: 'SmartHub / IoT'
        }[route],
        inMain: true,
        pass: true
      },
      layout: { horizontalOverflow: 0, clippedCount: 0 },
      focusPreserved: true
    })),
    evidence: {
      layout: 'p31-scale-route-audit.json',
      scaleAtspi: 'p31-scale-atspi.json',
      scaleScreenshot: 'p31-scale-200.png',
      highContrastScreenshot: 'p31-high-contrast.png',
      noColorScreenshot: 'p31-no-color.png',
      forcedColorsScreenshot: 'p31-forced-colors.png',
      runtime: 'p31-runtime-state.json',
      desktopSettings: 'p31-desktop-accessibility-settings.json'
    }
  };
  const keyboard = {
    distinctFocusedTargets: 4,
    focusTrap: false,
    namedFocusedTargets: 10,
    pass: true,
    physicalKeyPressCount: 28,
    stepCount: 16,
    announcementEventCount: 2
  };
  return {
    options,
    identity: {
      environmentId,
      architecture: profile.architecture,
      desktop: profile.desktop,
      session: profile.session,
      compositor: profile.compositor
    },
    navigation,
    driverEvidence,
    keyboard,
    rawDir
  };
}

test('P-31 live producer materializes canonical exact-scale sessions for every environment', () => {
  for (const environmentId of CANONICAL_ENVIRONMENTS) {
    const session = buildP31LiveSession(liveProducerFixture(environmentId));
    assert.equal(session.environmentId, environmentId);
    assert.equal(session.package.architecture, P31_ENVIRONMENTS[environmentId].architecture);
    assert.equal(session.package.format, P31_ENVIRONMENTS[environmentId].format);
    assert.equal(session.desktop.desktop, P31_ENVIRONMENTS[environmentId].desktop);
    assert.equal(session.desktop.session, P31_ENVIRONMENTS[environmentId].session);
    assert.equal(session.observations.scale.observedPercent, 200);
    assert.equal(session.observations.scale.exactScaleObservable, true);
    assert.deepEqual(session.observations.assistiveTech.routesCovered, [...P31_REQUIRED_ROUTES]);
    assert.ok(session.observations.scale.evidencePaths.every((value) => value.startsWith('p31-live/')));
  }

  const approximate = liveProducerFixture();
  approximate.driverEvidence.runtime.dpr = 1.99;
  assert.throws(() => buildP31LiveSession(approximate), /exact 200% scale/u);

  const missingRoute = liveProducerFixture();
  missingRoute.navigation.routes.pop();
  assert.throws(() => buildP31LiveSession(missingRoute), /every required route/u);

  const mislabeledRoute = liveProducerFixture();
  mislabeledRoute.driverEvidence.routeAudits[0].routeIdentity.label = 'Insights';
  assert.throws(() => buildP31LiveSession(mislabeledRoute), /exact 200|reflow/u);

  const missingDriverRoute = liveProducerFixture();
  missingDriverRoute.driverEvidence.routeAudits.pop();
  assert.throws(() => buildP31LiveSession(missingDriverRoute), /WebDriver.*every required route/u);

  const noAnnouncement = liveProducerFixture();
  noAnnouncement.keyboard.announcementEventCount = 0;
  assert.throws(() => buildP31LiveSession(noAnnouncement), /screen-reader|live-region/u);
});

test('P-31 workflow provisions every canonical distro and runs live production before proof capture', () => {
  const workflow = fs.readFileSync(path.join(
    path.dirname(fileURLToPath(import.meta.url)),
    '../../.github/workflows/linux-product-parity.yml'
  ), 'utf8');
  const install = workflow.indexOf("inputs.requirement == 'P-31'");
  const producer = workflow.indexOf('node scripts/linux-port/run-p31-live-accessibility-session.mjs');
  const capture = workflow.indexOf('node scripts/linux-port/capture-p31-accessibility.mjs');
  assert.ok(install >= 0 && producer > install && capture > producer);
  for (const marker of [
    'ubuntu-24.04-gnome-x11-*) compositor=Mutter',
    'ubuntu-24.04-gnome-wayland-*) compositor=Mutter',
    'fedora-kde-wayland-*) compositor=KWin',
    'arch-sway-wayland-x86_64) compositor=Sway',
    'sudo apt-get install -y --no-install-recommends',
    'sudo dnf install -y',
    'sudo pacman -S --needed --noconfirm',
    'test -n "${YDOTOOL_SOCKET:-}"',
    '--manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
    '--compositor "$compositor"',
    "inputs.requirement == 'P-31' || inputs.requirement == 'P-36'"
  ]) assert.match(workflow, new RegExp(marker.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'), 'u'));
});

test('P-31 live producer applies real compositor settings and paced Orca traversal', () => {
  const source = fs.readFileSync(path.join(
    path.dirname(fileURLToPath(import.meta.url)),
    'run-p31-live-accessibility-session.mjs'
  ), 'utf8');
  for (const marker of [
    "gsettings('scaling-factor', '2'",
    "gsettings('gtk-theme', 'HighContrast'",
    "gsettings('enable-animations', 'false'",
    "output.${output.id}.scale.${next}",
    "['output', output.name, 'scale', String(next)]",
    "profile.keyboardBackend === 'ydotool'",
    "'legacy-key-names'",
    "reverse ? 'shift+Tab' : 'Tab'",
    "'42:1', '15:1', '15:0', '42:0'",
    'exactHostArchitecture(platformArchitecture = os.machine())',
    'native Node runtime matching the Linux machine architecture',
    "assertRealOwnedDirectory(process.env.XDG_RUNTIME_DIR",
    "assertRealSessionSocket(environment.YDOTOOL_SOCKET",
    'XDG_CONFIG_HOME: path.join(options.stateHome',
    "await wait(1_250)",
    "await wait(8_000)",
    "const focusLogOffset = orcaLog.offset",
    "const debugBytes = orcaLog.read()",
    "'--mode', 'grab-focus'",
    "OPENBURNBAR_LINUX_FIXTURE_MODE: '0'",
    "openburnbar-p31-webdriver-atspi-navigation-v1",
    "fs.readdirSync(options.rawOutputDir).length === 0"
  ]) assert.ok(source.includes(marker), marker);
  assert.doesNotMatch(source,
    /spawn\(['"]Xvfb['"]|GDK_SCALE:|GTK_THEME:|GTK_ENABLE_ANIMATIONS:|spawnSync\(command|required\('sh'/u);
  assert.ok(
    source.lastIndexOf("preferences.restore()")
      < source.lastIndexOf("atomicJson(path.join(options.outputRoot, 'p31-live-session.json'), report)"),
    'P-31 report must be published only after preference restoration'
  );
  for (const marker of [
    'terminateNewDesktopProcesses(desktopBaseline)',
    'stopSpawnedProcess(orca',
    'restoreDaemonState(daemonWasActive)',
    'cleanupErrors'
  ]) assert.ok(source.includes(marker), marker);
});

test('P-31 discovers exactly one active local graphical session when XDG_SESSION_ID is not inherited', () => {
  const sessions = {
    2: { Type: 'tty', Class: 'user', Active: 'yes', Remote: 'no', State: 'active' },
    3: { Type: 'x11', Class: 'user', Active: 'yes', Remote: 'no', State: 'active' },
    4: { Type: 'x11', Class: 'greeter', Active: 'yes', Remote: 'no', State: 'active' },
    5: { Type: 'x11', Class: 'user', Active: 'yes', Remote: 'yes', State: 'active' }
  };
  const listed = [
    ' 2 1000 runner seat0 tty1',
    ' 3 1000 runner seat0 tty2',
    ' 4 1000 gdm seat0 tty3',
    ' 5 1000 runner',
    ' 6 0 root seat0 tty4'
  ].join('\n');
  const dependencies = {
    uid: 1000,
    listSessions: () => listed,
    showSession: (candidate) => sessions[candidate] ?? { Type: 'x11', Class: 'user', Active: 'yes', Remote: 'no', State: 'active' }
  };
  assert.equal(discoverP31GraphicalSessionId('X11', dependencies), '3');
  assert.throws(
    () => discoverP31GraphicalSessionId('Wayland', dependencies),
    /exactly one active local Wayland session .* found 0/u
  );
  assert.throws(
    () => discoverP31GraphicalSessionId('X11', {
      ...dependencies,
      listSessions: () => `${listed}\n 7 1000 runner seat0 tty5`,
      showSession: (candidate) => sessions[candidate]
        ?? { Type: 'x11', Class: 'user', Active: 'yes', Remote: 'no', State: 'active' }
    }),
    /found 2/u
  );
  assert.throws(
    () => discoverP31GraphicalSessionId('X11', {
      ...dependencies,
      listSessions: () => ' evil;id 1000 runner seat0 tty1'
    }),
    /unsafe session identifier/u
  );
});

test('P-31 identifies Ubuntu legacy and current ydotool keyboard contracts exactly', () => {
  assert.equal(detectYdotoolDialect([
    'Usage: key [--delay <ms>] <key sequence> ...',
    'Each key sequence can be any number of modifiers and keys, separated by plus (+)'
  ].join('\n')), 'legacy-key-names');
  assert.equal(detectYdotoolDialect(
    'key [-d,--key-delay <ms>] [<KEYCODE:PRESSED> ...]'
  ), 'linux-input-events');
  assert.throws(() => detectYdotoolDialect('generic keyboard helper'), /could not identify/u);
});

function fakeGsettings({ failApplyKey = null, failRestoreKey = null } = {}) {
  const original = new Map([
    ['scaling-factor', 'uint32 1'],
    ['gtk-theme', "'Yaru'"],
    ['enable-animations', 'true']
  ]);
  const values = new Map(original);
  const normalize = (key, value) => {
    if (key === 'scaling-factor') return value.startsWith('uint32 ') ? value : `uint32 ${value}`;
    if (key === 'gtk-theme') return value.startsWith("'") ? value : `'${value}'`;
    return value;
  };
  return {
    values,
    original,
    invoke(args) {
      const [, , key, value] = args;
      if (args[0] === 'get') return values.get(key);
      const normalized = normalize(key, value);
      if (key === failApplyKey && normalized !== original.get(key)) throw new Error(`apply ${key}`);
      if (key === failRestoreKey && normalized === original.get(key)) throw new Error(`restore ${key}`);
      values.set(key, normalized);
      return '';
    }
  };
}

function identityFor(environmentId) {
  const profile = P31_LIVE_ENVIRONMENTS[environmentId];
  return {
    environmentId,
    architecture: profile.architecture,
    desktop: profile.desktop,
    session: profile.session,
    compositor: profile.compositor
  };
}

function fakeKscreen() {
  const original = new Map([
    ['1', { name: 'eDP-1', scale: 1 }],
    ['2', { name: 'DP-1', scale: 1.25 }]
  ]);
  const values = new Map([...original].map(([id, output]) => [id, { ...output }]));
  const inventory = () => [...values].map(([id, output]) => [
    `Output: ${id} ${output.name}`,
    '        enabled',
    '        connected',
    `        Scale: ${output.scale}`
  ].join('\n')).join('\n');
  return {
    values,
    original,
    invoke(args) {
      if (args[0] === '-o') return inventory();
      const match = args[0]?.match(/^output\.([1-9][0-9]*)\.scale\.([0-9.]+)$/u);
      assert.ok(match, args.join(' '));
      values.get(match[1]).scale = Number(match[2]);
      return '';
    }
  };
}

function fakeSway() {
  const original = new Map([
    ['eDP-1', 1],
    ['DP-1', 1.5]
  ]);
  const values = new Map(original);
  const inventory = () => JSON.stringify([...values].map(([name, scale]) => ({
    name,
    active: true,
    scale
  })));
  return {
    values,
    original,
    invoke(args) {
      if (args.join(' ') === '-t get_outputs -r') return inventory();
      assert.deepEqual(args.slice(0, 1), ['output']);
      assert.equal(args[2], 'scale');
      values.set(args[1], Number(args[3]));
      return JSON.stringify([{ success: true }]);
    }
  };
}

test('P-31 compositor output parsers reject ambiguity and retain exact active scales', () => {
  assert.deepEqual(parseKScreenOutputs([
    'Output: 1 eDP-1',
    '        enabled',
    '        connected',
    '        Scale: 1.25',
    'Output: 2 DP-1',
    '        disabled',
    '        connected',
    '        Scale: 2'
  ].join('\n')), [{ id: '1', name: 'eDP-1', scale: 1.25 }]);
  assert.deepEqual(parseSwayOutputs(JSON.stringify([
    { name: 'eDP-1', active: true, scale: 2 },
    { name: 'DP-1', active: false, scale: 1 }
  ])), [{ name: 'eDP-1', scale: 2 }]);
  assert.throws(() => parseSwayOutputs('not-json'), /not JSON/u);
});

test('P-31 desktop preferences reach and restore exact GNOME, KDE, and Sway state', () => {
  const directory = () => fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-p31-settings-'));
  const success = fakeGsettings();
  const applied = applyDesktopAccessibilityPreferences(
    directory(),
    identityFor(X11_ARM_ENVIRONMENT),
    { invokeGsettings: success.invoke }
  );
  assert.equal(success.values.get('scaling-factor'), 'uint32 2');
  assert.deepEqual(applied.evidence.scaleOutputs, [{
    name: 'GNOME global scale',
    scale: 2,
    readback: 'uint32 2'
  }]);
  applied.restore();
  assert.deepEqual(success.values, success.original);

  const kdeSettings = fakeGsettings();
  const kscreen = fakeKscreen();
  const kde = applyDesktopAccessibilityPreferences(
    directory(),
    identityFor('fedora-kde-wayland-x86_64'),
    { invokeGsettings: kdeSettings.invoke, invokeKscreen: kscreen.invoke }
  );
  assert.deepEqual([...kscreen.values.values()].map((output) => output.scale), [2, 2]);
  kde.restore();
  assert.deepEqual(kscreen.values, kscreen.original);
  assert.deepEqual(kdeSettings.values, kdeSettings.original);

  const swaySettings = fakeGsettings();
  const sway = fakeSway();
  const swayApplied = applyDesktopAccessibilityPreferences(
    directory(),
    identityFor('arch-sway-wayland-x86_64'),
    { invokeGsettings: swaySettings.invoke, invokeSway: sway.invoke }
  );
  assert.deepEqual([...sway.values.values()], [2, 2]);
  swayApplied.restore();
  assert.deepEqual(sway.values, sway.original);
  assert.deepEqual(swaySettings.values, swaySettings.original);

  const partialApply = fakeGsettings({ failApplyKey: 'enable-animations' });
  assert.throws(
    () => applyDesktopAccessibilityPreferences(
      directory(),
      identityFor(X11_ARM_ENVIRONMENT),
      { invokeGsettings: partialApply.invoke }
    ),
    /apply enable-animations/u
  );
  assert.deepEqual(partialApply.values, partialApply.original);

  const partialRestore = fakeGsettings({ failRestoreKey: 'gtk-theme' });
  const restorable = applyDesktopAccessibilityPreferences(
    directory(),
    identityFor(X11_ARM_ENVIRONMENT),
    { invokeGsettings: partialRestore.invoke }
  );
  assert.throws(() => restorable.restore(), /restoration failed/u);
  assert.equal(partialRestore.values.get('scaling-factor'), 'uint32 1');
  assert.equal(partialRestore.values.get('enable-animations'), 'true');

  const evidenceFailure = fakeGsettings();
  const missing = path.join(directory(), 'missing');
  assert.throws(
    () => applyDesktopAccessibilityPreferences(
      missing,
      identityFor(X11_ARM_ENVIRONMENT),
      { invokeGsettings: evidenceFailure.invoke }
    ),
    /ENOENT|no such/u
  );
  assert.deepEqual(evidenceFailure.values, evidenceFailure.original);
});
