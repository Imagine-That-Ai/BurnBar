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
const failureSummaryName = 'shell-smoke-failure-summary.json';

function normalizeTranscript(text) {
  return text
    .replace(/\r/g, '')
    .split('\n')
    .map((line) => line.replace(/[ \t]+$/u, ''))
    .join('\n');
}

function envPresent(name) {
  return typeof process.env[name] === 'string' && process.env[name].trim().length > 0;
}

function safeEnvironmentValue(name, allowedValues) {
  const value = process.env[name]?.trim().toLowerCase();
  if (!value) return 'unset';
  return allowedValues.includes(value) ? value : 'other';
}

function runtimeMetadata() {
  return {
    nodeVersion: process.version,
    platform: process.platform,
    arch: process.arch,
    evidenceDirectory: path.relative(root, outDir) || '.',
    environment: {
      ci: envPresent('CI'),
      githubActions: envPresent('GITHUB_ACTIONS'),
      runnerOs: safeEnvironmentValue('RUNNER_OS', ['linux', 'macos', 'windows']),
      runnerArch: safeEnvironmentValue('RUNNER_ARCH', ['x64', 'arm64']),
      sessionType: safeEnvironmentValue('XDG_SESSION_TYPE', ['x11', 'wayland', 'tty']),
      desktop: safeEnvironmentValue('XDG_CURRENT_DESKTOP', ['gnome', 'kde', 'xfce', 'sway']),
      displayAvailable: envPresent('DISPLAY'),
      waylandDisplayAvailable: envPresent('WAYLAND_DISPLAY'),
      dbusSessionAvailable: envPresent('DBUS_SESSION_BUS_ADDRESS')
    }
  };
}

function existingArtifacts(directory, relativeDirectory = '') {
  let entries;
  try {
    entries = fs.readdirSync(directory, { withFileTypes: true });
  } catch {
    return [];
  }
  return entries.flatMap((entry) => {
    const relativeName = path.join(relativeDirectory, entry.name).split(path.sep).join('/');
    const filePath = path.join(directory, entry.name);
    if (entry.isDirectory()) return existingArtifacts(filePath, relativeName);
    if (!entry.isFile() || relativeName === failureSummaryName) return [];
    try {
      return [{ name: relativeName, sizeBytes: fs.statSync(filePath).size }];
    } catch {
      return [{ name: relativeName, sizeBytes: null }];
    }
  }).sort((a, b) => a.name.localeCompare(b.name));
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
  const artifactAgeMs = Date.now() - generatedAt;
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
    artifactAgeMs >= 0 &&
    artifactAgeMs <= maxAgeMs &&
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
const steps = [];
const transcriptPath = path.join(outDir, 'smoke-transcript.txt');

try {
  fs.unlinkSync(path.join(outDir, failureSummaryName));
} catch (error) {
  if (error.code !== 'ENOENT') {
    console.error(`unable to clear stale shell smoke failure summary: ${error.message}`);
    process.exit(1);
  }
}

function persistTranscript() {
  const transcript = steps
    .map((s, i) => `### step ${i + 1}\n${s.cmd}\nexit_code=${s.code}\ntimed_out=${s.timedOut ? 'true' : 'false'}\n${s.stdout}\n${s.stderr}`)
    .join('\n\n');
  fs.writeFileSync(transcriptPath, normalizeTranscript(transcript) + '\n');
}

function serializeStep(step, index) {
  const failure = classifyStep(step);
  return {
    index: index + 1,
    command: step.cmd,
    status: step.code === 0 ? 'passed' : 'failed',
    exitCode: step.code,
    timed_out: step.timedOut,
    failureClass: failure.failureClass,
    reasonCode: failure.reasonCode
  };
}

function classifyStep(step) {
  if (step.code === 0) return { failureClass: null, reasonCode: null };
  if (step.timedOut) return { failureClass: 'infra', reasonCode: 'linux-step-timeout' };
  if (step.cmd.includes('npm install')) {
    return { failureClass: 'infra', reasonCode: 'linux-dependency-install-failed' };
  }
  if (step.cmd.includes("npm test")) {
    return { failureClass: 'product', reasonCode: 'linux-shell-tests-failed' };
  }
  if (step.cmd.includes("npm run build")) {
    return { failureClass: 'product', reasonCode: 'linux-shell-build-failed' };
  }
  if (step.cmd.includes('run-shell-desktop-session')) {
    const desktopResult = readJSON('linux-desktop-session-wrapper-result.json');
    if (desktopResult?.failureClass && desktopResult?.reasonCode) {
      return {
        failureClass: desktopResult.failureClass,
        reasonCode: desktopResult.reasonCode
      };
    }
    return { failureClass: 'infra', reasonCode: 'linux-desktop-session-failed' };
  }
  if (step.cmd.includes('run-shell-evidence')) {
    const evidenceResult = readJSON('shell-evidence-result.json');
    if (evidenceResult?.failureClass && evidenceResult?.reasonCode) {
      return {
        failureClass: evidenceResult.failureClass,
        reasonCode: evidenceResult.reasonCode
      };
    }
    return { failureClass: 'infra', reasonCode: 'linux-shell-evidence-failed' };
  }
  if (step.cmd.includes('run-matched-performance')) {
    const comparison = readJSON('matched-performance-comparison.json');
    if (!comparison) {
      return { failureClass: 'infra', reasonCode: 'linux-matched-performance-evidence-unavailable' };
    }
    return { failureClass: 'product', reasonCode: 'linux-matched-performance-failed' };
  }
  if (step.cmd.includes('run-perf-budget')) {
    const perfReport = readJSON('perf-budget.json');
    if (perfReport?.failureClass === 'infra' && perfReport.reasonCode) {
      return {
        failureClass: 'infra',
        reasonCode: perfReport.reasonCode
      };
    }
    if (!perfReport) {
      return { failureClass: 'infra', reasonCode: 'linux-performance-evidence-unavailable' };
    }
    return { failureClass: 'product', reasonCode: 'linux-performance-budget-failed' };
  }
  if (step.cmd.includes('verify-shell-evidence')) {
    const verification = readJSON('shell-evidence-verify.json');
    if (verification?.failureClass && verification?.reasonCode) {
      return {
        failureClass: verification.failureClass,
        reasonCode: verification.reasonCode
      };
    }
    return { failureClass: 'infra', reasonCode: 'linux-shell-evidence-failed' };
  }
  return { failureClass: 'infra', reasonCode: 'linux-shell-step-failed' };
}

function persistFailureSummary() {
  const serializedSteps = steps.map(serializeStep);
  const failedSteps = serializedSteps.filter((step) => step.status === 'failed');
  const firstFailure = failedSteps.find((step) => step.failureClass === 'infra')
    ?? failedSteps[0]
    ?? null;
  const summary = {
    schemaVersion: 1,
    type: 'openburnbar.shell-smoke-failure',
    generatedAt: new Date().toISOString(),
    status: firstFailure?.failureClass === 'infra' ? 'infra-failed' : 'failed',
    failureClass: firstFailure?.failureClass ?? null,
    reasonCode: firstFailure?.reasonCode ?? null,
    failedSteps,
    steps: serializedSteps,
    artifacts: existingArtifacts(outDir),
    runtime: runtimeMetadata()
  };
  try {
    fs.writeFileSync(
      path.join(outDir, failureSummaryName),
      JSON.stringify(summary, null, 2) + '\n'
    );
  } catch (error) {
    console.error(`unable to write shell smoke failure summary: ${error.message}`);
  }
}

function recordStep(step) {
  steps.push(step);
  persistTranscript();
  if (step.code !== 0) {
    console.error(`shell smoke step failed: ${step.cmd} (exit ${step.code})`);
    persistFailureSummary();
  }
  return step;
}

recordStep(run('npm', ['install', '--no-audit', '--no-fund'], appDir, evidenceEnv, 240000));
recordStep(run('npm', ['test'], appDir, unitEnv, 180000));
recordStep(run('npm', ['run', 'build'], appDir, evidenceEnv, 180000));
// Fresh arm64 packaging can spend more than 25 minutes compiling the native
// daemon/CLI before the desktop evidence matrix begins. Match the wrapper's
// 60-minute default while keeping the workflow's 75-minute job cap intact.
const requestedDesktopTimeoutMs = Number.parseInt(process.env.OB_SHELL_DESKTOP_TIMEOUT_MS || '3600000', 10);
const desktopSessionTimeoutMs = Number.isSafeInteger(requestedDesktopTimeoutMs) && requestedDesktopTimeoutMs > 0
  ? requestedDesktopTimeoutMs
  : 3_600_000;
recordStep(currentDesktopArtifactsAreReusable()
  ? reusedDesktopStep()
  : run('node', [path.join(root, 'scripts/linux-port/run-shell-desktop-session.mjs')], root, evidenceEnv, desktopSessionTimeoutMs));
recordStep(run('node', [path.join(root, 'scripts/linux-port/run-shell-evidence.mjs')], root, evidenceEnv, 120000));
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
recordStep(run('node', matchedArguments, root, evidenceEnv, matchedTimeoutMs));
recordStep(run('node', [path.join(root, 'scripts/linux-port/run-perf-budget.mjs')], root, evidenceEnv, 120000));
recordStep(run('node', [path.join(root, 'scripts/linux-port/verify-shell-evidence.mjs'), outDir], root, evidenceEnv, 120000));
const failed = steps.find((s) => s.code !== 0);
if (failed) persistFailureSummary();
process.exit(failed ? failed.code : 0);
