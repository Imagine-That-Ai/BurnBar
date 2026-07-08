#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const budgetPath = path.join(root, 'budgets/linux-desktop.perf.json');
const outDir = process.env.OB_EVIDENCE_OUT
  ? path.resolve(process.env.OB_EVIDENCE_OUT)
  : path.join(root, 'docs/linux-port/evidence/mission-001-shell-ux');
const desktopSessionPath = path.join(outDir, 'linux-desktop-session-report.json');
const runtimeSamplesPath = path.join(outDir, 'runtime-perf-samples.jsonl');
const routeTranscriptPath = path.join(outDir, 'packaged-route-session-transcript.json');

const requiredRows = [
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

fs.mkdirSync(outDir, { recursive: true });
const budget = JSON.parse(fs.readFileSync(budgetPath, 'utf8'));
const errors = [];

function readJsonIfPresent(file) {
  if (!fs.existsSync(file)) return null;
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function readRuntimeSamples() {
  if (!fs.existsSync(runtimeSamplesPath)) return [];
  const text = fs.readFileSync(runtimeSamplesPath, 'utf8').trim();
  if (!text) return [];
  return text.split(/\n+/).map((line) => JSON.parse(line));
}

const desktopSession = readJsonIfPresent(desktopSessionPath);
const routeTranscript = readJsonIfPresent(routeTranscriptPath);
const runtimeSamples = readRuntimeSamples();

if (!desktopSession) errors.push('missing linux-desktop-session-report.json');
if (!routeTranscript) errors.push('missing packaged-route-session-transcript.json');
if (!runtimeSamples.length) errors.push('missing runtime-perf-samples.jsonl rows from packaged Tauri app');

function desktopVerdict(name, ms, source) {
  const limit = budget.thresholdsMs?.[name];
  return {
    name,
    ms: typeof ms === 'number' ? ms : null,
    limit,
    source,
    sampleCount: typeof ms === 'number' ? 1 : 0,
    measured: typeof ms === 'number',
    pass: typeof limit === 'number' && typeof ms === 'number' ? ms <= limit : false
  };
}

function runtimeVerdict(name) {
  const rows = runtimeSamples.filter((row) => row.name === name && typeof row.ms === 'number');
  const limit = budget.thresholdsMs?.[name];
  if (!rows.length) {
    return {
      name,
      ms: null,
      limit,
      source: 'missing-packaged-runtime-sample',
      sampleCount: 0,
      measured: false,
      pass: false
    };
  }
  const maxMs = Math.max(...rows.map((row) => row.ms));
  const sources = [...new Set(rows.map((row) => String(row.source ?? 'unknown')).filter(Boolean))].sort();
  return {
    name,
    ms: maxMs,
    limit,
    source: `packaged-tauri-runtime-samples:${sources.join(',')}`,
    sampleCount: rows.length,
    measured: true,
    pass: typeof limit === 'number' ? maxMs <= limit : false
  };
}

for (const row of requiredRows) {
  if (typeof budget.thresholdsMs?.[row] !== 'number') {
    errors.push(`budget missing threshold for ${row}`);
  }
}

const verdicts = [
  desktopVerdict('app.start', desktopSession?.performance?.appStartMs, 'packaged-tauri-deb-xvfb-window-visible'),
  runtimeVerdict('route.navigation'),
  desktopVerdict(
    'ipc.health.roundtrip',
    desktopSession?.performance?.ipcHealthRoundTripMs,
    'packaged-tray-reconnect-to-af-unix-daemon-log'
  ),
  desktopVerdict(
    'tray.click.open',
    desktopSession?.performance?.trayClickOpenMs,
    'appindicator-dbusmenu-open-to-visible-window'
  ),
  runtimeVerdict('chat.firstToken.progress'),
  runtimeVerdict('db.migration.open.query'),
  runtimeVerdict('parser.incremental.run'),
  runtimeVerdict('memory.search'),
  runtimeVerdict('media.control.stage')
];

const forbiddenSourceFragments = [
  'route-state-loop',
  'progress-chunk-reducer',
  'sqlite-memory-query',
  'swift-source-incremental-file-scan',
  'fixture-index-regex-search',
  'control-frame-json-stage'
];

for (const verdict of verdicts) {
  if (!verdict.measured) errors.push(`missing measured row for ${verdict.name}`);
  if (forbiddenSourceFragments.some((fragment) => verdict.source.includes(fragment))) {
    errors.push(`forbidden placeholder source for ${verdict.name}: ${verdict.source}`);
  }
}

const missingMetrics = requiredRows.filter((name) => !verdicts.some((verdict) => verdict.name === name));
const allPass = errors.length === 0 &&
  missingMetrics.length === 0 &&
  verdicts.every((verdict) => verdict.measured && verdict.pass === true);

const generatedAt = new Date().toISOString();
const report = {
  generatedAt,
  runner: 'linux-desktop-packaged-runtime-perf-v3',
  note: 'Budget rows are derived from the same packaged Linux desktop smoke run: Xvfb/XFCE .deb session report plus runtime samples emitted by the installed Tauri app through OPENBURNBAR_EVIDENCE_OUT.',
  host: { platform: process.platform, arch: process.arch },
  command: 'node scripts/linux-port/run-perf-budget.mjs',
  budgetFile: path.relative(root, budgetPath),
  measurements: {
    desktopSessionReport: path.relative(root, desktopSessionPath),
    desktopSessionPresent: Boolean(desktopSession),
    desktopSessionGeneratedAt: desktopSession?.generatedAt ?? null,
    runtimeSamples: path.relative(root, runtimeSamplesPath),
    runtimeSampleCount: runtimeSamples.length,
    packagedRouteTranscript: path.relative(root, routeTranscriptPath),
    packagedRouteCount: routeTranscript?.routeCount ?? null
  },
  budget,
  verdicts,
  missingMetrics,
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
    currentMs: verdict.ms,
    thresholdMs: verdict.limit,
    sampleCount: verdict.sampleCount,
    source: verdict.source,
    thresholdPass: verdict.pass,
    trendPass: verdict.pass
  })),
  pass: allPass,
  errors,
  note: 'Mission-001 has no durable multi-run Linux history yet; trend enforcement is fail-closed to current threshold rows.'
};
fs.writeFileSync(path.join(outDir, 'perf-threshold-enforcement.json'), JSON.stringify(trend, null, 2) + '\n');

const macosComparison = {
  generatedAt,
  status: budget.macosComparison?.status ?? 'blocked',
  reason: budget.macosComparison?.reason ?? 'No macOS source shell perf runner exists for this Linux desktop lane.',
  acceptedBlocker: budget.macosComparison?.acceptedBlocker ?? 'VAL-PERF-001-macos-source-comparison-unavailable',
  linuxRunner: report.runner
};
fs.writeFileSync(path.join(outDir, 'macos-perf-comparison.json'), JSON.stringify(macosComparison, null, 2) + '\n');

console.log(JSON.stringify(report, null, 2));
process.exit(allPass ? 0 : 1);
