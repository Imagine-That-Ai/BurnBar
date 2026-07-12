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
const requiredMetrics = budget.nativeShell?.requiredMetrics ?? [];
const errors = [];

function readJSON(file) {
  if (!fs.existsSync(file)) return null;
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (error) {
    errors.push(`invalid JSON in ${path.basename(file)}: ${error.message}`);
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
        errors.push(`invalid runtime sample line ${index + 1}: ${error.message}`);
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
if (!desktopSession) errors.push('missing linux-desktop-session-report.json');
if (!routeTranscript) errors.push('missing packaged-route-session-transcript.json');
if (!matchedComparison) errors.push('missing matched-performance-comparison.json');

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
  const pass = measured &&
    typeof limit === 'number' &&
    Number.isSafeInteger(minimumSamples) &&
    sampleCount >= minimumSamples &&
    stats.p95 <= limit;
  if (!measured) errors.push(`missing measured samples for ${name}`);
  if (sampleCount < (minimumSamples ?? Number.POSITIVE_INFINITY)) {
    errors.push(`${name} has ${sampleCount} samples; requires ${minimumSamples ?? 'a configured minimum'}`);
  }
  if (stats && typeof limit === 'number' && stats.p95 > limit) {
    errors.push(`${name} p95 ${stats.p95}ms exceeds ${limit}ms`);
  }
  return { name, unit: 'milliseconds', source: input.source, sampleCount, minimumSamples, limitP95Ms: limit, stats, measured, pass };
});

const routeSources = runtimeSamples
  .filter((row) => row.name === 'route.navigation')
  .map((row) => String(row.source ?? ''));
if (routeSources.some((source) => source.includes('route-render') || source.includes('route-state-loop'))) {
  errors.push('route.navigation contains a pre-paint or placeholder source');
}
if (matchedComparison?.pass !== true) errors.push('matched macOS/Linux performance comparison did not pass');
if (matchedComparison && matchedComparison.protocolVersion !== budget.matched?.protocolVersion) {
  errors.push('matched comparison protocol does not match the budget');
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
  errors
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
  pass: matchedComparison?.pass === true
};
fs.writeFileSync(path.join(outDir, 'macos-perf-comparison.json'), JSON.stringify(macosComparison, null, 2) + '\n');

console.log(JSON.stringify(report, null, 2));
process.exit(allPass ? 0 : 1);
