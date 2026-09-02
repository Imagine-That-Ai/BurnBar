#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const evidenceOutput = process.env.OB_EVIDENCE_OUT ?? process.env.OPENBURNBAR_LINUX_EVIDENCE_OUT;
const defaultEvidenceDir = evidenceOutput
  ? path.resolve(evidenceOutput)
  : path.join(root, 'docs/linux-port/evidence/mission-001-shell-ux');

const arg = process.argv[2];
const evidenceDir = arg && !['json', 'desktop', 'full'].includes(arg)
  ? path.resolve(arg)
  : defaultEvidenceDir;
const mode = arg && ['json', 'desktop', 'full'].includes(arg)
  ? arg
  : process.argv[3] ?? 'full';
const evidenceDirectoryPresent = fs.existsSync(evidenceDir);
fs.mkdirSync(evidenceDir, { recursive: true });

const requiredFailureIds = [
  'account-login',
  'account-logout',
  'provider-credentials',
  'sync-status',
  'update-status',
  'secret-store-setup',
  'secret-store-unavailable',
  'daemon-offline',
  'network-offline',
  'quota-exhausted',
  'permission-denied'
];

const requiredOnboardingTopics = [
  'daemonServiceSetup',
  'secretStoreTrust',
  'providerLogPaths',
  'cloudLowerTrustIdentity',
  'portalCaptureInputPermissions',
  'trayDesktopLimitations',
  'updates',
  'privacyChoices'
];

const requiredPerfRows = [
  'app.start',
  'route.navigation',
  'ipc.health.roundtrip',
  'tray.click.open'
];

const requiredRoutes = [
  'overview',
  'insights',
  'database',
  'providers',
  'projects',
  'missions',
  'activity',
  'chat',
  'memory',
  'settings',
  'account',
  'updates',
  'support',
  'onboarding',
  'pet',
  'text-expansion',
  'computer-use',
  'mercury',
  'smarthub'
];
const requiredRouteLabels = new Map([
  ['overview', 'Overview'],
  ['insights', 'Insights'],
  ['database', 'Database'],
  ['providers', 'Providers & models'],
  ['projects', 'Projects'],
  ['missions', 'Missions'],
  ['activity', 'Activity & logs'],
  ['chat', 'Chat / Hermes'],
  ['memory', 'Memory'],
  ['settings', 'Settings'],
  ['account', 'Account & sync'],
  ['updates', 'Updates'],
  ['support', 'Support & diagnostics'],
  ['onboarding', 'First-run setup'],
  ['pet', 'Pet companion'],
  ['text-expansion', 'Text expansion'],
  ['computer-use', 'Computer Use'],
  ['mercury', 'Mercury'],
  ['smarthub', 'SmartHub / IoT']
]);
const forbiddenPerfSources = [
  'route-state-loop',
  'progress-chunk-reducer',
  'sqlite-memory-query',
  'swift-source-incremental-file-scan',
  'fixture-index-regex-search',
  'control-frame-json-stage',
  'route-render'
];

const targetErrors = new Map([
  ['VAL-A11Y-001', []],
  ['VAL-SHELL-005', []],
  ['VAL-ONBOARDING-001', []],
  ['VAL-PET-001', []],
  ['VAL-TEXTEXP-001', []],
  ['VAL-PERF-001', []]
]);
const commonErrors = [];

function add(target, message) {
  targetErrors.get(target)?.push(message);
}

function common(message) {
  commonErrors.push(message);
}

function exists(file) {
  return fs.existsSync(path.join(evidenceDir, file));
}

function checkFile(file, target, minBytes = 1) {
  const full = path.join(evidenceDir, file);
  if (!fs.existsSync(full)) {
    add(target, `missing artifact ${file}`);
    return false;
  }
  const stat = fs.statSync(full);
  if (!stat.isFile() || stat.size < minBytes) {
    add(target, `artifact ${file} is empty or below ${minBytes} bytes`);
    return false;
  }
  return true;
}

function readJson(file, target) {
  const full = path.join(evidenceDir, file);
  if (!fs.existsSync(full)) {
    add(target, `missing artifact ${file}`);
    return null;
  }
  try {
    return JSON.parse(fs.readFileSync(full, 'utf8'));
  } catch (error) {
    add(target, `invalid JSON in ${file}: ${error.message}`);
    return null;
  }
}

function requirePackagedRoute(route, target) {
  const screenshot = `screenshot-route-${route}.png`;
  const xwininfo = `window-route-${route}-xwininfo.txt`;
  checkFile(screenshot, target, 256);
  checkFile(xwininfo, target);
}

function packagedRouteTarget(route) {
  if (route === 'onboarding') return 'VAL-ONBOARDING-001';
  if (route === 'pet') return 'VAL-PET-001';
  if (route === 'text-expansion') return 'VAL-TEXTEXP-001';
  if (['settings', 'account', 'updates', 'support'].includes(route)) return 'VAL-SHELL-005';
  return 'VAL-A11Y-001';
}

function checkPackagedRoutes() {
  if (mode === 'json') return null;
  const transcript = readJson('packaged-route-session-transcript.json', 'VAL-SHELL-005');
  if (!transcript) return null;
  if (transcript.mode !== 'packaged-desktop-route-navigation') {
    common(`packaged-route-session-transcript.json has unexpected mode ${transcript.mode}`);
  }
  const routes = new Set((transcript.routes ?? []).map((row) => row.route));
  for (const route of requiredRoutes) {
    const target = packagedRouteTarget(route);
    if (!routes.has(route)) add(target, `packaged route transcript missing ${route}`);
    const row = (transcript.routes ?? []).find((candidate) => candidate.route === route);
    if (row && row.navMethod !== 'atspi-command-palette-actions') {
      add(target, `packaged route ${route} used unexpected navigation method ${row.navMethod ?? 'missing'}`);
    }
    requirePackagedRoute(route, target);
  }
  return transcript;
}

function checkAxeRouteMatrix() {
  if (mode === 'desktop') return;
  const scan = readJson('axe-route-accessibility-scan.json', 'VAL-A11Y-001');
  if (!scan) return;
  if (scan.method !== 'axe-core-jsdom-route-and-capability-state-matrix') {
    add('VAL-A11Y-001', `unexpected axe scan method ${scan.method ?? 'missing'}`);
  }
  if (scan.allPass !== true) add('VAL-A11Y-001', 'axe route matrix did not pass');
  if (!String(scan.axeVersion ?? '').match(/^4\./)) {
    add('VAL-A11Y-001', `axe version is missing or unsupported: ${scan.axeVersion ?? 'missing'}`);
  }
  const states = Array.isArray(scan.states) ? scan.states : [];
  if (states.length !== requiredRoutes.length + 2) {
    add('VAL-A11Y-001', `axe route matrix must contain 21 states, got ${states.length}`);
  }
  const browserRoutes = new Set(
    states.filter((row) => row.state === 'browser-preview').map((row) => row.route)
  );
  for (const route of requiredRoutes) {
    if (!browserRoutes.has(route)) add('VAL-A11Y-001', `axe route matrix missing ${route}`);
  }
  for (const state of ['capability-unavailable', 'capability-degraded']) {
    if (!states.some((row) => row.state === state)) {
      add('VAL-A11Y-001', `axe route matrix missing ${state}`);
    }
  }
  for (const row of states) {
    if (row.violationCount !== 0 || (row.violations ?? []).length !== 0) {
      add('VAL-A11Y-001', `axe violations remain for ${row.state}:${row.route}`);
    }
  }
}

function validateAtspiSummary(file, expectedRoute = null) {
  const capture = readJson(file, 'VAL-A11Y-001');
  if (!capture) return null;
  if (capture.pass !== true) add('VAL-A11Y-001', `${file} did not pass`);
  if (expectedRoute && capture.route !== expectedRoute) {
    add('VAL-A11Y-001', `${file} route must be ${expectedRoute}, got ${capture.route ?? 'missing'}`);
  }
  if (capture.expectedNamePresent !== true) {
    add('VAL-A11Y-001', `${file} is missing its expected accessible name`);
  }
  if ((capture.nodeCount ?? 0) < 20) add('VAL-A11Y-001', `${file} has fewer than 20 nodes`);
  if ((capture.namedNodeCount ?? 0) < 8) add('VAL-A11Y-001', `${file} has fewer than 8 named nodes`);
  if ((capture.actionableNodeCount ?? 0) < 5) add('VAL-A11Y-001', `${file} has fewer than 5 actionable nodes`);
  if (capture.truncated !== false) add('VAL-A11Y-001', `${file} tree is truncated or unreported`);
  return capture;
}

function validateAtspiAction(file, expectedName, withinRole) {
  const action = readJson(file, 'VAL-A11Y-001');
  if (!action) return;
  if (action.pass !== true || action.activation?.activated !== true) {
    add('VAL-A11Y-001', `${file} did not activate its target`);
  }
  if (action.expectedName !== expectedName || action.withinRole !== withinRole) {
    add('VAL-A11Y-001', `${file} has an unexpected target or scope`);
  }
  if (!Array.isArray(action.activation?.availableActions) || action.activation.availableActions.length === 0) {
    add('VAL-A11Y-001', `${file} does not record an exposed AT-SPI action`);
  }
}

function checkPackagedAccessibility() {
  if (mode === 'json') return;
  checkFile('atspi-bus-address.txt', 'VAL-A11Y-001');
  checkFile('accessibility-tree-linux-desktop.txt', 'VAL-A11Y-001', 256);
  validateAtspiSummary('atspi-tree-linux-desktop.json');

  for (const route of requiredRoutes) {
    validateAtspiAction(`atspi-command-open-${route}.json`, 'Open command palette', null);
    validateAtspiAction(
      `atspi-command-route-${route}.json`,
      requiredRouteLabels.get(route),
      'dialog'
    );
    validateAtspiSummary(`atspi-route-${route}.json`, route);
  }

  const focus = readJson('atspi-keyboard-focus-sequence.json', 'VAL-A11Y-001');
  if (focus) {
    if (focus.pass !== true) add('VAL-A11Y-001', 'keyboard focus sequence did not pass');
    if (focus.method !== 'xdotool-tab-plus-orca-atspi-focus-events') {
      add('VAL-A11Y-001', `unexpected keyboard focus method ${focus.method ?? 'missing'}`);
    }
    const physicalKeyPressCount = focus.physicalKeyPressCount ?? focus.physicalTabPressCount;
    if (!Number.isInteger(physicalKeyPressCount) || physicalKeyPressCount < 14) {
      add('VAL-A11Y-001', `keyboard focus sequence must record at least 14 physical key presses, got ${physicalKeyPressCount ?? 'missing'}`);
    }
    if (focus.stepCount !== 10) add('VAL-A11Y-001', `keyboard focus sequence must contain 10 steps, got ${focus.stepCount ?? 'missing'}`);
    if ((focus.distinctFocusedTargets ?? 0) < 3) add('VAL-A11Y-001', 'keyboard focus sequence reached fewer than 3 distinct targets');
    if ((focus.namedFocusedTargets ?? 0) < 3) add('VAL-A11Y-001', 'keyboard focus sequence reached fewer than 3 named targets');
  }

  for (const file of ['orca-version.txt', 'orca-process.txt', 'orca-applications.txt', 'orca-debug.log']) {
    checkFile(file, 'VAL-A11Y-001');
  }
  if (exists('orca-version.txt') && !/^\d+\.\d+(?:\.\d+)?\s*$/i.test(fs.readFileSync(path.join(evidenceDir, 'orca-version.txt'), 'utf8'))) {
    add('VAL-A11Y-001', 'orca-version.txt does not contain an Orca version');
  }
  if (exists('orca-applications.txt') && !/OpenBurnBar/i.test(fs.readFileSync(path.join(evidenceDir, 'orca-applications.txt'), 'utf8'))) {
    add('VAL-A11Y-001', 'Orca did not list OpenBurnBar as an accessible application');
  }

  const zoom = readJson('zoom-accessibility-evidence.json', 'VAL-A11Y-001');
  if (zoom) {
    if (zoom.pass !== true || zoom.method !== 'packaged-webkitgtk-keyboard-zoom') {
      add('VAL-A11Y-001', 'packaged keyboard zoom evidence did not pass');
    }
    if (zoom.requestedApproximatePercent !== 200 || zoom.exactScaleObservable !== false) {
      add('VAL-A11Y-001', 'zoom evidence must record approximate 200% request and the exact-scale limitation');
    }
  }
  checkFile('screenshot-linux-desktop-zoom-200-requested.png', 'VAL-A11Y-001', 256);
  validateAtspiSummary('atspi-zoom-200-requested.json', 'overview');
}

function checkDaemonOracle() {
  if (mode === 'json') return;
  const oracle = readJson('daemon-session-oracle.json', 'VAL-SHELL-005');
  if (!oracle) return;
  if (oracle.mode !== 'openburnbar-daemon-af-unix' || oracle.status !== 'ready') {
    common(`daemon-session-oracle.json must prove real OpenBurnBarDaemon AF_UNIX, got mode=${oracle.mode ?? 'missing'} status=${oracle.status ?? 'missing'}`);
  }
  const transcript = exists('packaged-route-session-transcript.json')
    ? JSON.parse(fs.readFileSync(path.join(evidenceDir, 'packaged-route-session-transcript.json'), 'utf8'))
    : null;
  const routeModes = new Set((transcript?.routes ?? []).map((row) => row.daemonOracleMode));
  if (routeModes.has('accepted-fixture-af-unix')) {
    common('packaged route transcript contains accepted-fixture-af-unix rows');
  }
  const forbiddenProofStrings = [
    'accepted-fixture-af-unix',
    'fake-daemon',
    'gui-session-fake-daemon'
  ];
  for (const file of [
    'daemon-route-transcript.json',
    'linux-deb-install-run-transcript.txt',
    'linux-desktop-session-wrapper-transcript.txt',
    'linux-tauri-build-transcript.txt',
    'smoke-transcript.txt'
  ]) {
    const full = path.join(evidenceDir, file);
    if (!fs.existsSync(full)) continue;
    const text = fs.readFileSync(full, 'utf8');
    for (const forbidden of forbiddenProofStrings) {
      if (text.includes(forbidden)) common(`${file} still contains ${forbidden}`);
    }
  }
}

function checkShell005() {
  const failureTranscript = readJson('failure-state-transcript.json', 'VAL-SHELL-005');
  const scenarioEvidence = readJson('settings-account-update-support-scenarios.json', 'VAL-SHELL-005');
  if (!failureTranscript || !scenarioEvidence) return;
  const failureIds = new Set((failureTranscript.cases ?? []).map((row) => row.id));
  const scenarioIds = new Set((scenarioEvidence.scenarios ?? []).map((row) => row.id));
  for (const id of requiredFailureIds) {
    if (!failureIds.has(id)) add('VAL-SHELL-005', `failure-state-transcript missing ${id}`);
    if (!scenarioIds.has(id)) add('VAL-SHELL-005', `settings scenario evidence missing ${id}`);
  }
  for (const row of scenarioEvidence.scenarios ?? []) {
    if (!row.userVisibleFeedback || !row.recovery || !row.actionResult) {
      add('VAL-SHELL-005', `scenario ${row.id} lacks copy/recovery/actionResult`);
    }
  }
  if (scenarioEvidence.restartPersistence?.recoveredAfterRestart !== true) {
    add('VAL-SHELL-005', 'restart persistence did not prove recoveredAfterRestart=true');
  }
  const screenshots = new Set(scenarioEvidence.packagedScreenshots ?? []);
  for (const file of [
    'screenshot-route-settings.png',
    'screenshot-route-account.png',
    'screenshot-route-updates.png',
    'screenshot-route-support.png'
  ]) {
    if (!screenshots.has(file)) add('VAL-SHELL-005', `scenario evidence does not reference ${file}`);
  }
}

function checkOnboarding() {
  const evidence = readJson('onboarding-linux-flow-evidence.json', 'VAL-ONBOARDING-001');
  const transcript = readJson('onboarding-flow-transcript.json', 'VAL-ONBOARDING-001');
  if (!evidence || !transcript) return;
  const topics = evidence.linuxPermissionPathPrivacyCopy ?? {};
  for (const topic of requiredOnboardingTopics) {
    if (!topics[topic]) add('VAL-ONBOARDING-001', `missing onboarding topic ${topic}`);
  }
  const actions = new Set((transcript.steps ?? []).map((row) => row.action));
  for (const action of ['first-run', 'retry-check', 'skip-step', 'restart-resume', 'complete']) {
    if (!actions.has(action)) add('VAL-ONBOARDING-001', `onboarding transcript missing action ${action}`);
  }
  const denied = new Set((evidence.deniedRetryCases ?? []).map((row) => row.id));
  for (const id of ['permission-denied', 'secret-store-unavailable', 'onboarding-incomplete']) {
    if (!denied.has(id)) add('VAL-ONBOARDING-001', `missing denied/retry case ${id}`);
  }
  if (evidence.restartResumeProof?.resumedSameStep !== true) {
    add('VAL-ONBOARDING-001', 'restart resume proof did not preserve the same step');
  }
  if (!evidence.docsCopyReview || !String(evidence.docsCopyReview).includes('Linux-specific')) {
    add('VAL-ONBOARDING-001', 'docs/copy review does not prove Linux-specific copy');
  }
}

function checkPet() {
  const evidence = readJson('pet-runtime-behavior-evidence.json', 'VAL-PET-001');
  const matrix = readJson('pet-tier-matrix.json', 'VAL-PET-001');
  if (!evidence || !matrix) return;
  if ((evidence.gltf?.animationCount ?? 0) < 1) add('VAL-PET-001', 'GLB animationCount is missing/zero');
  if ((evidence.gltf?.sampledPointCount ?? 0) < 20) add('VAL-PET-001', 'GLB sampledPointCount is too low');
  const tiers = new Set((evidence.perDesktopEnvironment ?? []).map((row) => row.detected?.tier));
  if (!tiers.has('draggable-contained')) add('VAL-PET-001', 'missing degraded draggable-contained tier');
  if (!tiers.has('overlay-pass-through')) add('VAL-PET-001', 'missing overlay-pass-through tier matrix row');
  if (evidence.degradedDraggableFallback?.draggableAttribute !== true) {
    add('VAL-PET-001', 'degraded draggable fallback is not proven draggable');
  }
  if (!evidence.inputPassthrough?.restrictedTier || !evidence.overlayClickThrough?.claim) {
    add('VAL-PET-001', 'input passthrough/click-through policy is incomplete');
  }
  if (!Array.isArray(evidence.videoStoryboard) || evidence.videoStoryboard.length < 2) {
    add('VAL-PET-001', 'missing screenshot/video storyboard evidence');
  }
}

function checkTextExpansion() {
  const evidence = readJson('text-expansion-crud-safety-evidence.json', 'VAL-TEXTEXP-001');
  const safety = readJson('text-expansion-safety-proof.json', 'VAL-TEXTEXP-001');
  const nativePersistence = readJson('text-expansion-native-persistence-evidence.json', 'VAL-TEXTEXP-001');
  if (!evidence || !safety || !nativePersistence) return;
  if (evidence.deniedBeforeConsent !== true || evidence.permissionDeniedBehavior?.deniedBeforeConsent !== true) {
    add('VAL-TEXTEXP-001', 'permission-denied before consent is not proven');
  }
  if (
    nativePersistence.schemaVersion !== 1 ||
    nativePersistence.type !== 'openburnbar.linux.text-expansion-native-persistence' ||
    nativePersistence.source !== 'linux-swift-tests/daemon-linux.xml' ||
    nativePersistence.passed !== true ||
    nativePersistence.matchedTestCases !== 1 ||
    nativePersistence.test?.className !== 'OpenBurnBarDaemonLinuxGatewayTests.BurnBarTextExpansionServiceTests' ||
    nativePersistence.test?.name !== 'testEncryptedPersistenceConsentRestartAndPermissions' ||
    nativePersistence.test?.status !== 'passed' ||
    !Array.isArray(nativePersistence.test?.failureMarkers) ||
    nativePersistence.test.failureMarkers.length !== 0
  ) {
    add('VAL-TEXTEXP-001', 'snippet persistence across restart is not proven by the exact native daemon test receipt');
  }
  if (
    evidence.crud?.persistenceSurvivesRestart !== false ||
    evidence.crud?.persistenceBoundary !== 'daemon-owned AES-GCM sealed snapshot; fixture mode is memory-only'
  ) {
    add('VAL-TEXTEXP-001', 'renderer text-expansion fixture must remain explicitly memory-only');
  }
  if (evidence.enabledDisabledBehavior?.disabledPreservesTrigger !== true) {
    add('VAL-TEXTEXP-001', 'enable/disable behavior is not proven');
  }
  if (!evidence.parityLedgerSubstitution?.substitution && !safety.textExpansion?.parityLedgerRow?.substitution) {
    add('VAL-TEXTEXP-001', 'parity-ledger substitution row is missing');
  }
  if (evidence.unsafeGlobalKeyloggerProof?.globalCapture !== false || safety.textExpansion?.globalCapture !== false) {
    add('VAL-TEXTEXP-001', 'global keylogger safety proof does not fail closed');
  }
  for (const row of evidence.unsafeGlobalKeyloggerProof?.scan ?? []) {
    if ((row.forbiddenMatches ?? []).length > 0 || row.keydownListeners !== 0) {
      add('VAL-TEXTEXP-001', `unsafe capture scan failed for ${row.file}`);
    }
  }
}

function checkPerf() {
  const perf = readJson('perf-budget.json', 'VAL-PERF-001');
  const trend = readJson('perf-threshold-enforcement.json', 'VAL-PERF-001');
  const matched = readJson('matched-performance-comparison.json', 'VAL-PERF-001');
  if (!perf || !trend || !matched) return;
  if (perf.allPass !== true) add('VAL-PERF-001', 'perf-budget.json allPass is not true');
  if (perf.measurements?.desktopSessionPresent !== true) {
    add('VAL-PERF-001', 'perf budget is not tied to a packaged desktop session');
  }
  if ((perf.measurements?.runtimeSampleCount ?? 0) < 19) {
    add('VAL-PERF-001', 'runtime sample count is too low for post-paint route evidence');
  }
  const verdicts = new Map((perf.verdicts ?? []).map((row) => [row.name, row]));
  for (const rowName of requiredPerfRows) {
    const row = verdicts.get(rowName);
    if (!row) {
      add('VAL-PERF-001', `missing perf verdict ${rowName}`);
      continue;
    }
    if (row.measured !== true || typeof row.stats?.p95 !== 'number' || !Number.isFinite(row.stats.p95)) {
      add('VAL-PERF-001', `perf verdict ${rowName} is not measured`);
    }
    if ((row.sampleCount ?? 0) < (row.minimumSamples ?? Number.POSITIVE_INFINITY)) {
      add('VAL-PERF-001', `perf verdict ${rowName} has insufficient samples`);
    }
    if (row.pass !== true) add('VAL-PERF-001', `perf verdict ${rowName} did not pass threshold`);
    if (forbiddenPerfSources.some((fragment) => String(row.source ?? '').includes(fragment))) {
      add('VAL-PERF-001', `perf verdict ${rowName} uses forbidden placeholder source ${row.source}`);
    }
  }
  if (matched.pass !== true) add('VAL-PERF-001', 'matched macOS/Linux performance did not pass');
  if (matched.profile !== 'pr' && matched.profile !== 'nightly') {
    add('VAL-PERF-001', `matched performance profile must be pr or nightly, got ${matched.profile ?? 'missing'}`);
  }
  if ((matched.workloads ?? []).length !== 4) {
    add('VAL-PERF-001', `matched performance must contain four workloads, got ${(matched.workloads ?? []).length}`);
  }
  if (!(matched.workloads ?? []).every((row) => row.pass === true && row.checks?.checksumMatch === true)) {
    add('VAL-PERF-001', 'matched workload correctness or tail checks failed');
  }
  if (matched.resources?.macos?.pass !== true || matched.resources?.linux?.pass !== true) {
    add('VAL-PERF-001', 'matched resource soak checks failed');
  }
  if (trend.pass !== true) add('VAL-PERF-001', 'trend/threshold enforcement did not pass');
}

if (!evidenceDirectoryPresent) {
  common(`evidence directory missing: ${evidenceDir}`);
} else {
  checkPackagedRoutes();
  checkDaemonOracle();
  checkAxeRouteMatrix();
  checkPackagedAccessibility();
  if (mode === 'json' || mode === 'full') {
    checkShell005();
    checkOnboarding();
    checkPet();
    checkTextExpansion();
  }
  if (mode === 'full') checkPerf();
}

const targetStatus = Object.fromEntries(
  [...targetErrors.entries()].map(([target, errors]) => {
    const evidenceUnavailable = errors.some((error) => (
      /missing artifact|invalid JSON in|artifact .* empty or below/u.test(error)
    ));
    const failureClass = errors.length === 0 ? null : evidenceUnavailable ? 'infra' : 'product';
    return [target, {
      pass: errors.length === 0,
      status: errors.length === 0 ? 'passed' : failureClass === 'infra' ? 'infra-failed' : 'failed',
      failureClass,
      reasonCode: errors.length === 0
        ? null
        : evidenceUnavailable ? 'linux-evidence-environment-failed' : 'linux-evidence-contract-failed',
      errors
    }];
  })
);
const allErrors = [
  ...commonErrors,
  ...[...targetErrors.values()].flat()
];
const failureClass = allErrors.length === 0
  ? null
  : commonErrors.length > 0 || Object.values(targetStatus).some((target) => target.failureClass === 'infra')
    ? 'infra'
    : 'product';
const report = {
  generatedAt: new Date().toISOString(),
  mode,
  evidenceDir,
  targetStatus,
  status: allErrors.length === 0 ? 'ok' : failureClass === 'infra' ? 'infra-failed' : 'failed',
  failureClass,
  reasonCode: allErrors.length === 0
    ? null
    : failureClass === 'infra' ? 'linux-evidence-environment-failed' : 'linux-evidence-contract-failed',
  errors: allErrors
};

fs.writeFileSync(path.join(evidenceDir, 'shell-evidence-verify.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
process.exit(allErrors.length === 0 ? 0 : 1);
