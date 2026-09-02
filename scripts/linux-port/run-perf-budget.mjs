#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const budgetPath = path.join(root, 'budgets/linux-desktop.perf.json');
const evidenceOutput = process.env.OB_EVIDENCE_OUT ?? process.env.OPENBURNBAR_LINUX_EVIDENCE_OUT;
const outDir = evidenceOutput
  ? path.resolve(evidenceOutput)
  : path.join(root, 'docs/linux-port/evidence/mission-001-shell-ux');
const desktopSessionPath = path.join(outDir, 'linux-desktop-session-report.json');
const runtimeSamplesPath = path.join(outDir, 'runtime-perf-samples.jsonl');
const routeTranscriptPath = path.join(outDir, 'packaged-route-session-transcript.json');
const matchedComparisonPath = path.join(outDir, 'matched-performance-comparison.json');

fs.mkdirSync(outDir, { recursive: true });
const budget = JSON.parse(fs.readFileSync(budgetPath, 'utf8'));
const requiredMetrics = Array.isArray(budget.nativeShell?.requiredMetrics)
  ? budget.nativeShell.requiredMetrics
  : [];
const errors = [];
const infraErrors = [];
const budgetErrors = [];

function addInfraError(message) {
  errors.push(message);
  infraErrors.push(message);
}

function addBudgetError(message) {
  errors.push(message);
  budgetErrors.push(message);
}

function readJSON(file) {
  if (!fs.existsSync(file)) return null;
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (error) {
    addInfraError(`invalid JSON in ${path.basename(file)}: ${error.message}`);
    return null;
  }
}

function readRuntimeSamples() {
  if (!fs.existsSync(runtimeSamplesPath)) return [];
  return fs.readFileSync(runtimeSamplesPath, 'utf8')
    .split(/\n+/)
    .filter(Boolean)
    .map((line, index) => {
      try { return JSON.parse(line); }
      catch (error) {
        addInfraError(`invalid runtime sample line ${index + 1}: ${error.message}`);
        return null;
      }
    })
    .filter(Boolean);
}

function percentile(sorted, quantile) {
  const position = quantile * (sorted.length - 1);
  const lower = Math.floor(position);
  const upper = Math.ceil(position);
  if (lower === upper) return sorted[lower];
  return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - lower);
}

function summarize(values) {
  const sorted = values.filter((value) => typeof value === 'number' && Number.isFinite(value)).sort((a, b) => a - b);
  if (!sorted.length) return null;
  return {
    minimum: sorted[0],
    p50: percentile(sorted, 0.50),
    p95: percentile(sorted, 0.95),
    p99: percentile(sorted, 0.99),
    maximum: sorted[sorted.length - 1]
  };
}

const desktopSession = readJSON(desktopSessionPath);
const routeTranscript = readJSON(routeTranscriptPath);
const matchedComparison = readJSON(matchedComparisonPath);
const runtimeSamples = readRuntimeSamples();
if (requiredMetrics.length === 0) addInfraError('missing native shell required metrics');
if (!desktopSession) addInfraError('missing linux-desktop-session-report.json');
if (!routeTranscript) addInfraError('missing packaged-route-session-transcript.json');
if (!matchedComparison) addInfraError('missing matched-performance-comparison.json');

const metricInputs = {
  'app.start': {
    samples: desktopSession?.performance?.appStartSamples ?? [],
    source: 'packaged-tauri-deb-process-launch-to-x11-window-visible'
  },
  'route.navigation': {
    samples: runtimeSamples
      .filter((row) => row.name === 'route.navigation' && typeof row.ms === 'number')
      .map((row) => row.ms),
    source: 'packaged-tauri-command-palette-route-to-two-animation-frames'
  },
  'ipc.health.roundtrip': {
    samples: desktopSession?.performance?.ipcHealthRoundTripSamples ?? [],
    source: 'packaged-tray-reconnect-to-af-unix-daemon-activity'
  },
  'tray.click.open': {
    samples: desktopSession?.performance?.trayClickOpenSamples ?? [],
    source: 'appindicator-dbusmenu-open-to-visible-x11-window'
  }
};

const verdicts = requiredMetrics.map((name) => {
  const input = metricInputs[name] ?? { samples: [], source: 'missing' };
  const stats = summarize(input.samples);
  const limit = budget.nativeShell.thresholdsP95Ms?.[name];
  const minimumSamples = budget.nativeShell.minimumSamples?.[name];
  const sampleCount = input.samples.length;
  const measured = stats !== null;
  const validLimit = typeof limit === 'number' && Number.isFinite(limit) && limit >= 0;
  const validMinimum = Number.isSafeInteger(minimumSamples) && minimumSamples > 0;
  const pass = measured &&
    validLimit &&
    validMinimum &&
    sampleCount >= minimumSamples &&
    stats.p95 <= limit;
  if (!measured) addInfraError(`missing measured samples for ${name}`);
  if (!validLimit) addInfraError(`missing or invalid p95 threshold for ${name}`);
  if (!validMinimum) addInfraError(`missing or invalid minimum sample count for ${name}`);
  if (sampleCount < (minimumSamples ?? Number.POSITIVE_INFINITY)) {
    addInfraError(`${name} has ${sampleCount} samples; requires ${minimumSamples ?? 'a configured minimum'}`);
  }
  if (stats && validLimit && stats.p95 > limit) {
    addBudgetError(`${name} p95 ${stats.p95}ms exceeds ${limit}ms`);
  }
  return { name, unit: 'milliseconds', source: input.source, sampleCount, minimumSamples, limitP95Ms: limit, stats, measured, pass };
});

const routeSources = runtimeSamples
  .filter((row) => row.name === 'route.navigation')
  .map((row) => String(row.source ?? ''));
if (routeSources.some((source) => source.includes('route-render') || source.includes('route-state-loop'))) {
  addInfraError('route.navigation contains a pre-paint or placeholder source');
}
if (matchedComparison && matchedComparison.pass !== true) {
  addBudgetError('matched macOS/Linux performance comparison did not pass');
}
if (matchedComparison && matchedComparison.protocolVersion !== budget.matched?.protocolVersion) {
  addInfraError('matched comparison protocol does not match the budget');
}

const allPass = errors.length === 0 &&
  verdicts.length === requiredMetrics.length &&
  verdicts.every((verdict) => verdict.pass) &&
  matchedComparison?.pass === true;
const generatedAt = new Date().toISOString();
const report = {
  generatedAt,
  runner: 'linux-desktop-packaged-runtime-perf-v4',
  note: 'Native packaged-shell p50/p95/p99 metrics are combined with identical production-linked macOS/Linux workloads. Boot-time synthetic subsystem operations are forbidden.',
  host: { platform: process.platform, arch: process.arch },
  command: 'node scripts/linux-port/run-perf-budget.mjs',
  budgetFile: path.relative(root, budgetPath),
  measurements: {
    desktopSessionReport: path.relative(root, desktopSessionPath),
    desktopSessionPresent: Boolean(desktopSession),
    runtimeSamples: path.relative(root, runtimeSamplesPath),
    runtimeSampleCount: runtimeSamples.length,
    packagedRouteTranscript: path.relative(root, routeTranscriptPath),
    packagedRouteCount: routeTranscript?.routeCount ?? null,
    matchedComparison: path.relative(root, matchedComparisonPath),
    matchedComparisonPresent: Boolean(matchedComparison),
    matchedProfile: matchedComparison?.profile ?? null
  },
  nativeShellBudget: budget.nativeShell,
  matchedPerformance: matchedComparison,
  verdicts,
  errors,
  infraErrors,
  budgetErrors,
  status: errors.length === 0 ? 'passed' : infraErrors.length > 0 ? 'infra-failed' : 'failed',
  failureClass: errors.length === 0 ? null : infraErrors.length > 0 ? 'infra' : 'budget',
  reasonCode: errors.length === 0
    ? null
    : infraErrors.length > 0 ? 'linux-performance-evidence-unavailable' : 'linux-performance-budget-failed',
  allPass
};
fs.writeFileSync(path.join(outDir, 'perf-budget.json'), JSON.stringify(report, null, 2) + '\n');

const trend = {
  generatedAt,
  runner: report.runner,
  baselinePolicy: budget.trendPolicy,
  rows: verdicts.map((verdict) => ({
    name: verdict.name,
    currentP50Ms: verdict.stats?.p50 ?? null,
    currentP95Ms: verdict.stats?.p95 ?? null,
    currentP99Ms: verdict.stats?.p99 ?? null,
    thresholdP95Ms: verdict.limitP95Ms,
    sampleCount: verdict.sampleCount,
    source: verdict.source,
    pass: verdict.pass
  })),
  matchedProfile: matchedComparison?.profile ?? null,
  matchedPass: matchedComparison?.pass === true,
  pass: allPass,
  errors,
  status: report.status,
  failureClass: report.failureClass,
  reasonCode: report.reasonCode
};
fs.writeFileSync(path.join(outDir, 'perf-threshold-enforcement.json'), JSON.stringify(trend, null, 2) + '\n');

const macosComparison = {
  generatedAt,
  status: matchedComparison?.pass === true ? 'measured-pass' : 'measured-fail',
  protocolVersion: matchedComparison?.protocolVersion ?? null,
  profile: matchedComparison?.profile ?? null,
  workloads: matchedComparison?.workloads ?? [],
  resources: matchedComparison?.resources ?? null,
  errors: matchedComparison?.errors ?? ['matched comparison missing'],
  failureClass: matchedComparison?.pass === true ? null : matchedComparison ? 'budget' : 'infra',
  reasonCode: matchedComparison?.pass === true
    ? null
    : matchedComparison ? 'linux-matched-performance-failed' : 'linux-matched-performance-evidence-unavailable',
  pass: matchedComparison?.pass === true
};
fs.writeFileSync(path.join(outDir, 'macos-perf-comparison.json'), JSON.stringify(macosComparison, null, 2) + '\n');

console.log(JSON.stringify(report, null, 2));
// Linux evidence keeps the existing non-zero failure contract for workflow
// compatibility; the machine-readable status/failureClass/reasonCode fields
// distinguish infrastructure evidence gaps from budget/product failures.
process.exit(allPass ? 0 : 1);
