#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {
  MISSION_ROOT,
  SHELL_EVIDENCE_DIR,
  REQUIRED_JSON_ARTIFACTS,
  REQUIRED_DESKTOP_SESSION_ARTIFACTS,
  PACKAGED_ROUTE_IDS,
  REQUIRED_PERF_ROWS,
  FORBIDDEN_TRANSCRIPT_PATHS,
  assertMissionPathsInText
} from './shell-evidence-manifest.mjs';

const mode = process.argv[2] ?? 'full';
const errors = [];

function fail(message) {
  errors.push(message);
}

function checkFile(relativePath, { minBytes = 1, label = relativePath } = {}) {
  const full = path.join(SHELL_EVIDENCE_DIR, relativePath);
  if (!fs.existsSync(full)) {
    fail(`missing artifact: ${label}`);
    return;
  }
  const stat = fs.statSync(full);
  if (!stat.isFile() || stat.size < minBytes) {
    fail(`empty or invalid artifact: ${label}`);
  }
}

function scanTranscripts() {
  const names = [
    'smoke-transcript.txt',
    'shell-evidence-harness-transcript.txt',
    'linux-deb-install-run-transcript.txt',
    'linux-tauri-build-transcript.txt'
  ];
  for (const name of names) {
    const full = path.join(SHELL_EVIDENCE_DIR, name);
    if (!fs.existsSync(full)) continue;
    try {
      assertMissionPathsInText(fs.readFileSync(full, 'utf8'), name);
    } catch (error) {
      fail(error.message);
    }
  }
}

function checkManifest() {
  const manifestPath = path.join(SHELL_EVIDENCE_DIR, 'shell-evidence-run-manifest.json');
  if (!fs.existsSync(manifestPath)) {
    fail('missing shell-evidence-run-manifest.json');
    return;
  }
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  if (manifest.missionWorktree !== MISSION_ROOT) {
    fail(`manifest missionWorktree must be ${MISSION_ROOT}`);
  }
}

function checkDaemonOracle() {
  const oraclePath = path.join(SHELL_EVIDENCE_DIR, 'daemon-session-oracle.json');
  if (!fs.existsSync(oraclePath)) {
    if (mode === 'full' || mode === 'desktop') {
      fail('missing daemon-session-oracle.json (desktop session must declare real daemon or honest blocker)');
    }
    return;
  }
  const oracle = JSON.parse(fs.readFileSync(oraclePath, 'utf8'));
  const allowedRoots = new Set([MISSION_ROOT, '/workspace']);
  if (oracle.missionWorktree && !allowedRoots.has(oracle.missionWorktree)) {
    fail(`daemon-session-oracle.json references unexpected mission worktree: ${oracle.missionWorktree}`);
  }
  if (oracle.missionWorktree === '/workspace' && oracle.missionWorktreeHost && oracle.missionWorktreeHost !== MISSION_ROOT) {
    fail('daemon-session-oracle.json missionWorktreeHost does not match mission worktree');
  }
  if (oracle.mode === 'accepted-fixture-af-unix' && oracle.status !== 'accepted-fixture') {
    fail('accepted fixture oracle must use status=accepted-fixture');
  }
  if (oracle.mode === 'accepted-fixture-af-unix' && process.env.OB_ACCEPT_SHELL_DAEMON_FIXTURE !== '1') {
    fail('accepted fixture oracle requires OB_ACCEPT_SHELL_DAEMON_FIXTURE=1 in the verifier environment');
  }
  if (oracle.mode === 'blocked') {
    fail(`daemon session blocked: ${oracle.detail ?? 'unknown'}`);
  }
}

function readJson(relativePath) {
  return JSON.parse(fs.readFileSync(path.join(SHELL_EVIDENCE_DIR, relativePath), 'utf8'));
}

function checkPackagedRoutes() {
  const transcriptPath = path.join(SHELL_EVIDENCE_DIR, 'packaged-route-session-transcript.json');
  if (!fs.existsSync(transcriptPath)) {
    fail('missing packaged-route-session-transcript.json');
    return;
  }
  const transcript = readJson('packaged-route-session-transcript.json');
  if (transcript.mode !== 'packaged-desktop-route-navigation') {
    fail(`packaged route transcript has unexpected mode: ${transcript.mode}`);
  }
  const routeMap = new Map((transcript.routes ?? []).map((route) => [route.route, route]));
  for (const routeId of PACKAGED_ROUTE_IDS) {
    const route = routeMap.get(routeId);
    if (!route) {
      fail(`packaged route transcript missing route: ${routeId}`);
      continue;
    }
    checkFile(route.screenshot, { minBytes: 32, label: `packaged route screenshot ${routeId}` });
    checkFile(route.xwininfo, { label: `packaged route xwininfo ${routeId}` });
  }
  const daemonRoutePath = path.join(SHELL_EVIDENCE_DIR, 'daemon-route-transcript.json');
  if (fs.existsSync(daemonRoutePath)) {
    const daemonRoutes = readJson('daemon-route-transcript.json');
    if (daemonRoutes.mode === 'fixture' && mode !== 'json') {
      fail('daemon-route-transcript.json is still fixture-mode after desktop evidence run');
    }
  }
}

function checkRuntimePerfSamples() {
  const samplePath = path.join(SHELL_EVIDENCE_DIR, 'runtime-perf-samples.jsonl');
  if (!fs.existsSync(samplePath)) {
    fail('missing runtime-perf-samples.jsonl');
    return;
  }
  const rows = fs.readFileSync(samplePath, 'utf8')
    .trim()
    .split(/\n+/)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  const names = new Set(rows.map((row) => row.name));
  for (const rowName of REQUIRED_PERF_ROWS.filter((name) => !['tray.open'].includes(name))) {
    if (!names.has(rowName)) fail(`runtime perf samples missing ${rowName}`);
  }
}

function checkPerfBudget() {
  const perfPath = path.join(SHELL_EVIDENCE_DIR, 'perf-budget.json');
  if (!fs.existsSync(perfPath)) {
    if (mode === 'full') fail('missing perf-budget.json');
    return;
  }
  const perf = readJson('perf-budget.json');
  const budgetRows = Object.keys(perf.budget?.thresholdsMs ?? {});
  for (const rowName of REQUIRED_PERF_ROWS) {
    if (!budgetRows.includes(rowName)) fail(`budget missing threshold for ${rowName}`);
  }
  const verdictMap = new Map((perf.verdicts ?? []).map((verdict) => [verdict.name, verdict]));
  const forbiddenSources = [
    'route-state-loop',
    'progress-chunk-reducer',
    'sqlite-memory-query',
    'swift-source-incremental-file-scan',
    'fixture-index-regex-search',
    'control-frame-json-stage'
  ];
  for (const rowName of REQUIRED_PERF_ROWS) {
    const verdict = verdictMap.get(rowName);
    if (!verdict) {
      fail(`perf verdict missing ${rowName}`);
      continue;
    }
    if (typeof verdict.ms !== 'number' || !Number.isFinite(verdict.ms)) {
      fail(`perf verdict ${rowName} has invalid ms`);
    }
    if (verdict.pass !== true) {
      fail(`perf verdict ${rowName} did not pass`);
    }
    if (forbiddenSources.some((source) => String(verdict.source ?? '').includes(source))) {
      fail(`perf verdict ${rowName} uses forbidden weak-oracle source: ${verdict.source}`);
    }
  }
  if (perf.allPass !== true) {
    fail('perf-budget.json allPass must be true');
  }
  if (perf.measurements?.desktopSessionPresent !== true) {
    fail('perf-budget.json must be tied to a desktop session report');
  }
}

if (!fs.existsSync(SHELL_EVIDENCE_DIR)) {
  console.error('evidence directory missing:', SHELL_EVIDENCE_DIR);
  process.exit(1);
}

checkManifest();
scanTranscripts();

if (mode === 'json' || mode === 'full') {
  for (const artifact of REQUIRED_JSON_ARTIFACTS) {
    checkFile(artifact);
  }
}

if (mode === 'desktop' || mode === 'full') {
  for (const artifact of REQUIRED_DESKTOP_SESSION_ARTIFACTS) {
    checkFile(artifact, artifact.endsWith('.png') ? { minBytes: 32 } : {});
  }
  checkDaemonOracle();
  checkPackagedRoutes();
  checkRuntimePerfSamples();
}

if (mode === 'full') {
  checkPerfBudget();
}

if (errors.length) {
  const report = {
    generatedAt: new Date().toISOString(),
    mode,
    missionWorktree: MISSION_ROOT,
    evidenceDir: SHELL_EVIDENCE_DIR,
    forbiddenPaths: FORBIDDEN_TRANSCRIPT_PATHS,
    errors
  };
  fs.writeFileSync(path.join(SHELL_EVIDENCE_DIR, 'shell-evidence-verify.json'), JSON.stringify(report, null, 2) + '\n');
  console.error(JSON.stringify(report, null, 2));
  process.exit(1);
}

const ok = {
  generatedAt: new Date().toISOString(),
  mode,
  missionWorktree: MISSION_ROOT,
  evidenceDir: SHELL_EVIDENCE_DIR,
  status: 'ok'
};
fs.writeFileSync(path.join(SHELL_EVIDENCE_DIR, 'shell-evidence-verify.json'), JSON.stringify(ok, null, 2) + '\n');
console.log(JSON.stringify(ok, null, 2));
