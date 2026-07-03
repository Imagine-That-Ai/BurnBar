#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  REQUIRED_PERF_ROWS,
  SHELL_EVIDENCE_DIR
} from './shell-evidence-manifest.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const budgetPath = path.join(root, 'budgets/linux-desktop.perf.json');
const outDir = SHELL_EVIDENCE_DIR;
fs.mkdirSync(outDir, { recursive: true });

const budget = JSON.parse(fs.readFileSync(budgetPath, 'utf8'));
const desktopSessionPath = path.join(outDir, 'linux-desktop-session-report.json');
const runtimeSamplesPath = path.join(outDir, 'runtime-perf-samples.jsonl');
const routeTranscriptPath = path.join(outDir, 'packaged-route-session-transcript.json');
const errors = [];

function readJsonIfPresent(file) {
  if (!fs.existsSync(file)) return null;
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function readRuntimeSamples() {
  if (!fs.existsSync(runtimeSamplesPath)) return [];
  return fs.readFileSync(runtimeSamplesPath, 'utf8')
    .trim()
    .split(/\n+/)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

const desktopSession = readJsonIfPresent(desktopSessionPath);
const routeTranscript = readJsonIfPresent(routeTranscriptPath);
const runtimeSamples = readRuntimeSamples();

if (!desktopSession) errors.push('missing linux-desktop-session-report.json');
if (!routeTranscript) errors.push('missing packaged-route-session-transcript.json');
if (!runtimeSamples.length) errors.push('missing runtime-perf-samples.jsonl rows');

function runtimeVerdict(name) {
  const rows = runtimeSamples.filter((row) => row.name === name && typeof row.ms === 'number');
  if (!rows.length) {
    return {
      name,
      ms: null,
      limit: budget.thresholdsMs[name],
      source: 'missing-packaged-runtime-sample',
      sampleCount: 0,
      pass: false
    };
  }
  const maxMs = Math.max(...rows.map((row) => row.ms));
  const sources = [...new Set(rows.map((row) => row.source).filter(Boolean))].sort();
  return {
    name,
    ms: maxMs,
    limit: budget.thresholdsMs[name],
    source: `packaged-tauri-runtime-samples:${sources.join(',')}`,
    sampleCount: rows.length,
    pass: typeof budget.thresholdsMs[name] === 'number' ? maxMs <= budget.thresholdsMs[name] : false
  };
}

function desktopVerdict(name, ms, source) {
  return {
    name,
    ms: typeof ms === 'number' ? ms : null,
    limit: budget.thresholdsMs[name],
    source,
    sampleCount: 1,
    pass: typeof budget.thresholdsMs[name] === 'number' && typeof ms === 'number'
      ? ms <= budget.thresholdsMs[name]
      : false
  };
}

const verdicts = [
  desktopVerdict(
    'app.start',
    desktopSession?.performance?.appStartMs,
    'packaged-tauri-deb-xvfb-window-visible'
  ),
  runtimeVerdict('route.navigation'),
  desktopVerdict(
    'ipc.health.roundtrip',
    desktopSession?.performance?.ipcHealthRoundTripMs,
    'packaged-tray-reconnect-to-openburnbar-daemon-af-unix'
  ),
  desktopVerdict(
    'tray.open',
    desktopSession?.performance?.trayClickOpenMs,
    'appindicator-dbusmenu-open-to-visible-window'
  ),
  runtimeVerdict('chat.firstToken.progress'),
  runtimeVerdict('db.migration.open.query'),
  runtimeVerdict('parser.incremental.run'),
  runtimeVerdict('memory.search'),
  runtimeVerdict('media.control.stage')
];

const thresholdNames = Object.keys(budget.thresholdsMs ?? {});
for (const rowName of REQUIRED_PERF_ROWS) {
  if (!thresholdNames.includes(rowName)) errors.push(`budget missing threshold for ${rowName}`);
}

const missingMetrics = REQUIRED_PERF_ROWS.filter((name) => !verdicts.some((sample) => sample.name === name));
const allPass = errors.length === 0 &&
  missingMetrics.length === 0 &&
  verdicts.every((verdict) => verdict.pass === true);

const report = {
  generatedAt: new Date().toISOString(),
  missionWorktree: root,
  note: 'Budget rows are derived from the same packaged Linux desktop smoke run: Xvfb/XFCE .deb session report plus runtime samples emitted by the installed Tauri app through OPENBURNBAR_EVIDENCE_OUT.',
  host: { platform: process.platform, arch: process.arch },
  measurements: {
    desktopSessionReport: desktopSessionPath,
    desktopSessionPresent: Boolean(desktopSession),
    desktopSessionGeneratedAt: desktopSession?.generatedAt ?? null,
    runtimeSamples: runtimeSamplesPath,
    runtimeSampleCount: runtimeSamples.length,
    packagedRouteTranscript: routeTranscriptPath,
    packagedRouteCount: routeTranscript?.routeCount ?? null
  },
  budget,
  verdicts,
  missingMetrics,
  errors,
  allPass
};

const outFile = path.join(outDir, 'perf-budget.json');
fs.writeFileSync(outFile, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
process.exit(allPass ? 0 : 1);
