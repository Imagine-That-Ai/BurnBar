#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const defaultEvidenceDir = process.env.OB_EVIDENCE_OUT
  ? path.resolve(process.env.OB_EVIDENCE_OUT)
  : path.join(root, 'docs/linux-port/evidence/mission-001-shell-ux');

const arg = process.argv[2];
const evidenceDir = arg && !['json', 'desktop', 'full'].includes(arg)
  ? path.resolve(arg)
  : defaultEvidenceDir;
const mode = arg && ['json', 'desktop', 'full'].includes(arg)
  ? arg
  : process.argv[3] ?? 'full';

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
  'tray.click.open',
  'chat.firstToken.progress',
  'db.migration.open.query',
  'parser.incremental.run',
  'memory.search',
  'media.control.stage'
];

const targetRoutes = ['settings', 'account', 'updates', 'support', 'onboarding', 'pet', 'text-expansion'];
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

function checkPackagedRoutes() {
  if (mode === 'json') return null;
  const transcript = readJson('packaged-route-session-transcript.json', 'VAL-SHELL-005');
  if (!transcript) return null;
  if (transcript.mode !== 'packaged-desktop-route-navigation') {
    common(`packaged-route-session-transcript.json has unexpected mode ${transcript.mode}`);
  }
  const routes = new Set((transcript.routes ?? []).map((row) => row.route));
  for (const route of targetRoutes) {
    if (!routes.has(route)) common(`packaged route transcript missing ${route}`);
  }
  requirePackagedRoute('settings', 'VAL-SHELL-005');
  requirePackagedRoute('account', 'VAL-SHELL-005');
  requirePackagedRoute('updates', 'VAL-SHELL-005');
  requirePackagedRoute('support', 'VAL-SHELL-005');
  requirePackagedRoute('onboarding', 'VAL-ONBOARDING-001');
  requirePackagedRoute('pet', 'VAL-PET-001');
  requirePackagedRoute('text-expansion', 'VAL-TEXTEXP-001');
  return transcript;
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
  if (!evidence || !safety) return;
  if (evidence.deniedBeforeConsent !== true || evidence.permissionDeniedBehavior?.deniedBeforeConsent !== true) {
    add('VAL-TEXTEXP-001', 'permission-denied before consent is not proven');
  }
  if (evidence.crud?.persistenceSurvivesRestart !== true || evidence.crud?.persistedAfterRestartCount < 1) {
    add('VAL-TEXTEXP-001', 'snippet persistence across restart is not proven');
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
  if (!perf || !trend) return;
  if (perf.allPass !== true) add('VAL-PERF-001', 'perf-budget.json allPass is not true');
  if (perf.measurements?.desktopSessionPresent !== true) {
    add('VAL-PERF-001', 'perf budget is not tied to a packaged desktop session');
  }
  if ((perf.measurements?.runtimeSampleCount ?? 0) < 5) {
    add('VAL-PERF-001', 'runtime sample count is too low for subsystem evidence');
  }
  const verdicts = new Map((perf.verdicts ?? []).map((row) => [row.name, row]));
  for (const rowName of requiredPerfRows) {
    const row = verdicts.get(rowName);
    if (!row) {
      add('VAL-PERF-001', `missing perf verdict ${rowName}`);
      continue;
    }
    if (row.measured !== true || typeof row.ms !== 'number' || !Number.isFinite(row.ms)) {
      add('VAL-PERF-001', `perf verdict ${rowName} is not measured`);
    }
    if (row.pass !== true) add('VAL-PERF-001', `perf verdict ${rowName} did not pass threshold`);
    if (forbiddenPerfSources.some((fragment) => String(row.source ?? '').includes(fragment))) {
      add('VAL-PERF-001', `perf verdict ${rowName} uses forbidden placeholder source ${row.source}`);
    }
  }
  if (trend.pass !== true) add('VAL-PERF-001', 'trend/threshold enforcement did not pass');
}

if (!fs.existsSync(evidenceDir)) {
  common(`evidence directory missing: ${evidenceDir}`);
} else {
  checkPackagedRoutes();
  checkDaemonOracle();
  if (mode === 'json' || mode === 'full') {
    checkShell005();
    checkOnboarding();
    checkPet();
    checkTextExpansion();
  }
  if (mode === 'full') checkPerf();
}

const targetStatus = Object.fromEntries(
  [...targetErrors.entries()].map(([target, errors]) => [target, { pass: errors.length === 0, errors }])
);
const allErrors = [
  ...commonErrors,
  ...[...targetErrors.values()].flat()
];
const report = {
  generatedAt: new Date().toISOString(),
  mode,
  evidenceDir,
  targetStatus,
  status: allErrors.length === 0 ? 'ok' : 'failed',
  errors: allErrors
};

fs.writeFileSync(path.join(evidenceDir, 'shell-evidence-verify.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
process.exit(allErrors.length === 0 ? 0 : 1);
