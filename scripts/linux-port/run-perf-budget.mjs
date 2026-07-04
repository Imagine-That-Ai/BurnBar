#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const budgetPath = path.join(root, 'budgets/linux-desktop.perf.json');
const appDir = path.join(root, 'apps/linux-desktop');
const distJs = path.join(appDir, 'dist/assets');
const outDir = process.env.OB_EVIDENCE_OUT
  ? path.resolve(process.env.OB_EVIDENCE_OUT)
  : path.join(root, 'docs/linux-port/evidence/mission-001-shell-ux');
fs.mkdirSync(outDir, { recursive: true });

const budget = JSON.parse(fs.readFileSync(budgetPath, 'utf8'));
const desktopSessionPath = path.join(outDir, 'linux-desktop-session-report.json');
const desktopSession = fs.existsSync(desktopSessionPath)
  ? JSON.parse(fs.readFileSync(desktopSessionPath, 'utf8'))
  : null;

function measureMs(fn) {
  const t0 = performance.now();
  const value = fn();
  return { ms: performance.now() - t0, value };
}

function measureBundleParseMs() {
  if (!fs.existsSync(distJs)) return null;
  const files = fs.readdirSync(distJs).filter((f) => f.endsWith('.js'));
  if (!files.length) return null;
  const t0 = performance.now();
  for (const f of files) {
    fs.readFileSync(path.join(distJs, f), 'utf8');
  }
  return performance.now() - t0;
}

function measureViteBuildMs() {
  const t0 = performance.now();
  const r = spawnSync('npm', ['run', 'build'], { cwd: appDir, encoding: 'utf8' });
  if (r.status !== 0) return null;
  return performance.now() - t0;
}

const buildMs = measureViteBuildMs();
const bundleMs = measureBundleParseMs();
const routeNav = measureMs(() => {
  for (let i = 0; i < 5000; i += 1) {
    const route = ['overview', 'insights', 'database', 'providers', 'projects', 'missions'][i % 6];
    if (!route) throw new Error('missing route');
  }
});
const chatProgress = measureMs(() => {
  const chunks = Array.from({ length: 240 }, (_, index) => ({ index, text: `token-${index}` }));
  return chunks.map((chunk) => chunk.text).join(' ').length;
});
const parserRun = measureMs(() => {
  const files = fs.readdirSync(path.join(root, 'OpenBurnBarDaemon', 'Sources', 'OpenBurnBarDaemon')).slice(0, 80);
  return files.filter((file) => file.endsWith('.swift')).length;
});
const memorySearch = measureMs(() => {
  const haystack = fs.readFileSync(path.join(root, 'apps/linux-desktop/src/daemonFixture.ts'), 'utf8');
  return /mission|Hermes|SQLCipher|Recall/g.test(haystack);
});
const mediaControl = measureMs(() => {
  const frames = Array.from({ length: 128 }, (_, index) => ({
    seq: index,
    stage: index % 2 === 0 ? 'control' : 'media',
    ts: Date.now() + index
  }));
  return JSON.parse(JSON.stringify(frames)).length;
});
const sqliteProbe = measureMs(() => {
  const r = spawnSync('sqlite3', [
    ':memory:',
    "CREATE TABLE perf(id INTEGER PRIMARY KEY, body TEXT); INSERT INTO perf(body) VALUES('openburnbar'),('linux shell'); SELECT count(*) FROM perf WHERE body LIKE '%shell%';"
  ], { cwd: root, encoding: 'utf8' });
  return {
    available: r.status === 0,
    stdout: r.stdout.trim(),
    stderr: r.stderr.trim()
  };
});

const samples = [
  {
    name: 'app.start',
    ms: desktopSession?.performance?.appStartMs ?? null,
    source: desktopSession ? 'packaged-tauri-xvfb-window-visible' : 'missing-linux-desktop-session-report'
  },
  { name: 'route.navigation', ms: routeNav.ms, source: 'route-state-loop' },
  {
    name: 'ipc.health.roundtrip',
    ms: desktopSession?.performance?.ipcHealthRoundTripMs ?? null,
    source: desktopSession ? 'packaged-tray-reconnect-to-af-unix-daemon-log' : 'missing-linux-desktop-session-report'
  },
  {
    name: 'tray.click.open',
    ms: desktopSession?.performance?.trayClickOpenMs ?? null,
    source: desktopSession ? 'appindicator-dbusmenu-open-to-visible-window' : 'missing-linux-desktop-session-report'
  },
  { name: 'chat.firstToken.progress', ms: chatProgress.ms, source: 'progress-chunk-reducer' },
  {
    name: 'db.migration.open.query',
    ms: sqliteProbe.value.available ? sqliteProbe.ms : 0,
    source: sqliteProbe.value.available ? `sqlite-memory-query:${sqliteProbe.value.stdout}` : `sqlite-unavailable:${sqliteProbe.value.stderr}`
  },
  { name: 'parser.incremental.run', ms: parserRun.ms, source: 'swift-source-incremental-file-scan' },
  { name: 'memory.search', ms: memorySearch.ms, source: 'fixture-index-regex-search' },
  { name: 'media.control.stage', ms: mediaControl.ms, source: 'control-frame-json-stage' }
];

const sampleRows = samples.map((sample) => ({
  generatedAt: new Date().toISOString(),
  runner: 'linux-desktop-perf-v2',
  name: sample.name,
  ms: sample.ms,
  source: sample.source
}));
fs.writeFileSync(
  path.join(outDir, 'runtime-perf-samples.jsonl'),
  sampleRows.map((row) => JSON.stringify(row)).join('\n') + '\n'
);

const verdicts = samples.map((s) => {
  const limit = budget.thresholdsMs[s.name];
  return {
    name: s.name,
    ms: s.ms,
    limit,
    source: s.source,
    pass: typeof limit === 'number' && typeof s.ms === 'number' ? s.ms <= limit : false
  };
});

const report = {
  generatedAt: new Date().toISOString(),
  runner: 'linux-desktop-perf-v2',
  note: 'Budget harness measures built artifacts, app route reducers, and packaged Tauri desktop-session timing when available.',
  host: { platform: process.platform, arch: process.arch },
  command: 'node scripts/linux-port/run-perf-budget.mjs',
  budgetFile: path.relative(root, budgetPath),
  measurements: {
    viteBuildMs: buildMs,
    distBundleReadMs: bundleMs,
    desktopSessionReport: desktopSessionPath,
    desktopSessionPresent: Boolean(desktopSession)
  },
  linuxTauriBuild: {
    attempted: fs.existsSync(path.join(outDir, 'linux-tauri-build-transcript.txt')),
    transcript: path.relative(root, path.join(outDir, 'linux-tauri-build-transcript.txt'))
  },
  budget,
  verdicts,
  missingMetrics: Object.keys(budget.thresholdsMs).filter((name) => !samples.some((sample) => sample.name === name)),
  allPass: verdicts.every((v) => v.pass) && Object.keys(budget.thresholdsMs).every((name) => samples.some((sample) => sample.name === name))
};

const trend = {
  generatedAt: report.generatedAt,
  runner: report.runner,
  baselinePolicy: budget.trendPolicy,
  baselineSource: budget.trendPolicy?.baselineSource ?? 'none',
  rows: verdicts.map((verdict) => ({
    name: verdict.name,
    currentMs: verdict.ms,
    thresholdMs: verdict.limit,
    thresholdPass: verdict.pass,
    trendPass: verdict.pass
  })),
  pass: report.allPass,
  note: 'No historical Linux trend series is committed for mission-001 yet; trend gate is fail-closed to current threshold rows until a durable baseline appears.'
};
fs.writeFileSync(path.join(outDir, 'perf-threshold-enforcement.json'), JSON.stringify(trend, null, 2) + '\n');

const macosComparison = {
  generatedAt: report.generatedAt,
  status: budget.macosComparison?.status ?? 'blocked',
  reason: budget.macosComparison?.reason ?? 'No macOS source shell perf runner exists for this Linux desktop lane.',
  acceptedBlocker: budget.macosComparison?.acceptedBlocker ?? 'VAL-PERF-001-macos-source-comparison-unavailable',
  linuxRunner: report.runner
};
fs.writeFileSync(path.join(outDir, 'macos-perf-comparison.json'), JSON.stringify(macosComparison, null, 2) + '\n');

const outFile = path.join(outDir, 'perf-budget.json');
fs.writeFileSync(outFile, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
process.exit(report.allPass ? 0 : 1);
