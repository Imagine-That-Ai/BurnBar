#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const appDir = path.join(root, 'apps/linux-desktop');
const evidenceOutput = process.env.OB_EVIDENCE_OUT ?? process.env.OPENBURNBAR_LINUX_EVIDENCE_OUT;
const outDir = evidenceOutput
  ? path.resolve(evidenceOutput)
  : path.join(root, 'docs/linux-port/evidence/mission-001-shell-ux');
fs.mkdirSync(outDir, { recursive: true });

function normalizeTranscript(text) {
  return text
    .replace(/\r/g, '')
    .split('\n')
    .map((line) => line.replace(/[ \t]+$/u, ''))
    .join('\n');
}

function run(cmd, args, cwd, env = process.env, timeoutMs = 180000) {
  const r = spawnSync(cmd, args, { cwd, encoding: 'utf8', env, timeout: timeoutMs });
  const timedOut = r.error?.code === 'ETIMEDOUT';
  return {
    cmd: [cmd, ...args].join(' '),
    code: timedOut ? 124 : r.status ?? 1,
    stdout: r.stdout ?? '',
    stderr: `${r.stderr ?? ''}${timedOut ? `\ncommand timed out after ${timeoutMs}ms\n` : ''}`,
    timedOut
  };
}

function readJSON(fileName) {
  try {
    return JSON.parse(fs.readFileSync(path.join(outDir, fileName), 'utf8'));
  } catch {
    return null;
  }
}

function currentDesktopArtifactsAreReusable() {
  if (process.env.OB_SHELL_FORCE_DESKTOP_SESSION === '1') return false;
  const required = [
    'linux-desktop-session-report.json',
    'packaged-route-session-transcript.json',
    'runtime-perf-samples.jsonl',
    'daemon-session-oracle.json',
    'atspi-tree-linux-desktop.json',
    'atspi-keyboard-focus-sequence.json',
    'atspi-zoom-200-requested.json',
    'orca-applications.txt',
    'orca-debug.log',
    'orca-process.txt',
    'orca-version.txt',
    'zoom-accessibility-evidence.json'
  ];
  for (const fileName of required) {
    const filePath = path.join(outDir, fileName);
    if (!fs.existsSync(filePath) || fs.statSync(filePath).size === 0) return false;
  }
  const report = readJSON('linux-desktop-session-report.json');
  const routes = readJSON('packaged-route-session-transcript.json');
  const oracle = readJSON('daemon-session-oracle.json');
  const generatedAt = report?.generatedAt ? Date.parse(report.generatedAt) : Number.NaN;
  const maxAgeMs = Number.parseInt(process.env.OB_SHELL_DESKTOP_ARTIFACT_MAX_AGE_MS || '86400000', 10);
  const runtimeRows = fs.readFileSync(path.join(outDir, 'runtime-perf-samples.jsonl'), 'utf8')
    .split('\n')
    .filter((line) => line.trim().length > 0);
  const routeEvidenceIsComplete = routes?.routes?.every((route) => {
    if (route?.navMethod !== 'atspi-command-palette-actions') return false;
    const routeSlug = route?.route;
    if (typeof routeSlug !== 'string' || routeSlug.length === 0) return false;
    const actionFiles = [
      `atspi-command-open-${routeSlug}.json`,
      `atspi-command-route-${routeSlug}.json`,
      `atspi-route-${routeSlug}.json`
    ];
    return actionFiles.every((fileName) => {
      const artifact = readJSON(fileName);
      return artifact?.pass === true;
    });
  });
  return Number.isFinite(generatedAt) &&
    Date.now() - generatedAt <= maxAgeMs &&
    report?.performance?.appStartMs > 0 &&
    report?.performance?.ipcHealthRoundTripMs > 0 &&
    report?.accessibility?.atspiTree?.pass === true &&
    report?.accessibility?.keyboardFocus?.pass === true &&
    report?.accessibility?.zoom?.pass === true &&
    report?.accessibility?.orcaProcessObserved === true &&
    routes?.mode === 'packaged-desktop-route-navigation' &&
    Array.isArray(routes?.routes) &&
    routes.routes.length === 19 &&
    routeEvidenceIsComplete === true &&
    oracle?.mode === 'openburnbar-daemon-af-unix' &&
    oracle?.status === 'ready' &&
    runtimeRows.length >= 5;
}

function reusedDesktopStep() {
  return {
    cmd: 'node scripts/linux-port/run-shell-desktop-session.mjs (reused current packaged desktop artifacts)',
    code: 0,
    stdout: [
      'reused_current_desktop_artifacts=true',
      `evidence_dir=${outDir}`,
      'artifacts=linux-desktop-session-report.json,packaged-route-session-transcript.json,runtime-perf-samples.jsonl,daemon-session-oracle.json'
    ].join('\n'),
    stderr: '',
    timedOut: false
  };
}

const evidenceEnv = { ...process.env, OB_EVIDENCE_OUT: outDir };
const unitEnv = { ...process.env };
delete unitEnv.OB_EVIDENCE_OUT;
fs.writeFileSync(path.join(outDir, 'smoke-transcript.txt'), '');
const steps = [];
steps.push(run('npm', ['install', '--no-audit', '--no-fund'], appDir, evidenceEnv, 240000));
steps.push(run('npm', ['test'], appDir, unitEnv, 180000));
steps.push(run('npm', ['run', 'build'], appDir, evidenceEnv, 180000));
const desktopSessionTimeoutMs = Number.parseInt(process.env.OB_SHELL_DESKTOP_TIMEOUT_MS || '1500000', 10);
steps.push(currentDesktopArtifactsAreReusable()
  ? reusedDesktopStep()
  : run('node', [path.join(root, 'scripts/linux-port/run-shell-desktop-session.mjs')], root, evidenceEnv, desktopSessionTimeoutMs));
steps.push(run('node', [path.join(root, 'scripts/linux-port/run-shell-evidence.mjs')], root, evidenceEnv, 120000));
const matchedProfile = process.env.OB_MATCHED_PERF_PROFILE || 'pr';
const matchedArguments = [
  path.join(root, 'scripts/linux-port/run-matched-performance.mjs'),
  '--profile', matchedProfile
];
if (process.env.OB_MATCHED_MACOS_INPUT) {
  matchedArguments.push('--macos-input', process.env.OB_MATCHED_MACOS_INPUT);
}
if (process.env.OB_MATCHED_LINUX_INPUT) {
  matchedArguments.push('--linux-input', process.env.OB_MATCHED_LINUX_INPUT);
}
const matchedTimeoutMs = matchedProfile === 'nightly' ? 2700000 : 900000;
steps.push(run('node', matchedArguments, root, evidenceEnv, matchedTimeoutMs));
steps.push(run('node', [path.join(root, 'scripts/linux-port/run-perf-budget.mjs')], root, evidenceEnv, 120000));
steps.push(run('node', [path.join(root, 'scripts/linux-port/verify-shell-evidence.mjs'), outDir], root, evidenceEnv, 120000));

const transcript = steps
  .map((s, i) => `### step ${i + 1}\n${s.cmd}\nexit_code=${s.code}\ntimed_out=${s.timedOut ? 'true' : 'false'}\n${s.stdout}\n${s.stderr}`)
  .join('\n\n');

fs.writeFileSync(path.join(outDir, 'smoke-transcript.txt'), normalizeTranscript(transcript) + '\n');
const failed = steps.find((s) => s.code !== 0);
process.exit(failed ? failed.code : 0);
