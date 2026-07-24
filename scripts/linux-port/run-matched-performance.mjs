#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  compareMatchedPerformance,
  dockerHostIdentityArguments,
  attachMatchedPerformanceProvenance,
  matchedPerformanceSourceDigest
} from './lib/matched-performance.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const packagePath = path.join(root, 'tools/matched-performance');
const budgetPath = path.join(root, 'budgets/linux-desktop.perf.json');
const evidenceOutput = process.env.OB_EVIDENCE_OUT ?? process.env.OPENBURNBAR_LINUX_EVIDENCE_OUT;
const outDir = evidenceOutput
  ? path.resolve(evidenceOutput)
  : path.join(root, 'docs/linux-port/evidence/mission-001-shell-ux');

function parseArguments(values) {
  const result = { mode: 'auto', profile: process.env.OB_MATCHED_PERF_PROFILE || 'pr' };
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (value === '--macos-only') result.mode = 'macos';
    else if (value === '--linux-only') result.mode = 'linux';
    else if (value === '--compare-only') result.mode = 'compare';
    else if (['--profile', '--macos-input', '--linux-input', '--target-head', '--package-version', '--candidate-run-id', '--candidate-artifact-digest'].includes(value)) {
      const next = values[index + 1];
      if (!next) throw new Error(`Missing value for ${value}`);
      const keys = {
        '--profile': 'profile', '--macos-input': 'macosInput', '--linux-input': 'linuxInput',
        '--target-head': 'targetHead', '--package-version': 'packageVersion',
        '--candidate-run-id': 'candidateRunId', '--candidate-artifact-digest': 'candidateArtifactDigest'
      };
      result[keys[value]] = next;
      index += 1;
    } else {
      throw new Error(`Unknown argument ${value}`);
    }
  }
  return result;
}

function gitHead() {
  const result = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`Cannot resolve matched-performance HEAD: ${result.stderr.trim()}`);
  return result.stdout.trim();
}

function packageVersion() {
  return readJSON(path.join(root, 'apps/linux-desktop/package.json')).version;
}

function provenanceIdentity(options) {
  const head = gitHead();
  if (options.targetHead && options.targetHead !== head) throw new Error('Matched-performance target HEAD does not match checkout HEAD');
  const runId = options.candidateRunId ?? null;
  const digest = options.candidateArtifactDigest ?? null;
  if ((runId === null) !== (digest === null)
      || (runId !== null && (!/^[1-9][0-9]*$/u.test(runId) || !/^sha256:[a-f0-9]{64}$/u.test(digest)))) {
    throw new Error('Matched-performance candidate binding must provide a valid run ID and artifact digest together');
  }
  const version = options.packageVersion ?? packageVersion();
  if (!/^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$/u.test(version)) {
    throw new Error('Matched-performance package version is invalid');
  }
  return {
    gitCommit: head,
    packageVersion: version,
    sourceDigest: matchedPerformanceSourceDigest(root),
    candidate: { runId, artifactDigest: digest }
  };
}

function stampReport(file, platform, profile, identity, startedAt) {
  const endedAt = new Date().toISOString();
  const report = attachMatchedPerformanceProvenance(readJSON(file), {
    platform, profile, ...identity,
    candidateRunId: identity.candidate.runId,
    candidateArtifactDigest: identity.candidate.artifactDigest,
    startedAt, endedAt
  });
  fs.writeFileSync(file, JSON.stringify(report, null, 2) + '\n');
}

function readJSON(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function run(command, args, transcriptName, timeoutMs, environment = process.env) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: 'utf8',
    env: environment,
    timeout: timeoutMs,
    maxBuffer: 64 * 1024 * 1024
  });
  const transcript = [
    `command=${[command, ...args].join(' ')}`,
    `exit_code=${result.status ?? 1}`,
    `timed_out=${result.error?.code === 'ETIMEDOUT'}`,
    result.stdout ?? '',
    result.stderr ?? ''
  ].join('\n');
  fs.writeFileSync(path.join(outDir, transcriptName), transcript);
  if (result.error || result.status !== 0) {
    throw new Error(`${command} failed (${result.error?.message ?? `exit ${result.status}`}); see ${transcriptName}`);
  }
}

function probeArguments(configuration, output) {
  return [
    '--rows', String(configuration.rows),
    '--samples', String(configuration.samples),
    '--warmups', String(configuration.warmups),
    '--soak-seconds', String(configuration.soakSeconds),
    '--seed', String(configuration.seed),
    '--output', output
  ];
}

function mergeStreamResult(reportPath, streamPath) {
  const report = readJSON(reportPath);
  const stream = readJSON(streamPath);
  report.workloads = [
    ...(report.workloads ?? []).filter((row) => row.id !== stream.id),
    stream
  ];
  report.pass = report.pass === true &&
    stream.id === 'stream.first-visible-delta-decode' &&
    stream.sampleCount === report.configuration.samples &&
    Number.isSafeInteger(stream.checksum) && stream.checksum !== 0;
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n');
}

function runMacOS(configuration, output) {
  if (process.platform !== 'darwin') throw new Error('macOS probe requires a macOS runner');
  const timeoutMs = (configuration.soakSeconds + 900) * 1_000;
  const environment = {
    ...process.env,
    OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD: '1'
  };
  const streamOutput = path.join(outDir, 'matched-performance-macos-stream.json');
  run('swift', [
    'run',
    '--package-path', packagePath,
    '--disable-automatic-resolution',
    'OpenBurnBarPerfProbe',
    ...probeArguments(configuration, output)
  ], 'matched-performance-macos-transcript.txt', timeoutMs, environment);
  run('swift', [
    'run',
    '--package-path', packagePath,
    '--disable-automatic-resolution',
    'OpenBurnBarStreamPerfProbe',
    '--samples', String(configuration.samples),
    '--warmups', String(configuration.warmups),
    '--output', streamOutput
  ], 'matched-performance-macos-stream-transcript.txt', timeoutMs, environment);
  mergeStreamResult(output, streamOutput);
}

function runLinux(configuration, output) {
  const containerOutput = `/evidence/${path.basename(output)}`;
  const streamOutput = path.join(outDir, 'matched-performance-linux-stream.json');
  const containerStreamOutput = `/evidence/${path.basename(streamOutput)}`;
  const script = `
set -euo pipefail
export OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1
export OPENBURNBAR_USE_SYSTEM_SQLCIPHER=1
mkdir -p "$HOME"
repo=/tmp/openburnbar-matched-performance-repo
rm -rf "$repo"
mkdir -p "$repo/tools" "$repo/Vendor"
cp -R /workspace/tools/matched-performance "$repo/tools/matched-performance"
rm -rf "$repo/tools/matched-performance/.build"
rm -f "$repo/tools/matched-performance/Package.resolved"
ln -s /workspace/OpenBurnBarCore "$repo/OpenBurnBarCore"
ln -s /workspace/Vendor/GRDB-SQLCipher "$repo/Vendor/GRDB-SQLCipher"
swift run --package-path "$repo/tools/matched-performance" OpenBurnBarPerfProbe \
  --rows "$1" --samples "$2" --warmups "$3" --soak-seconds "$4" \
  --seed "$5" --output "$6"
swift run --package-path "$repo/tools/matched-performance" OpenBurnBarStreamPerfProbe \
  --samples "$2" --warmups "$3" --output "$7"
`;
  const timeoutMs = (configuration.soakSeconds + 900) * 1_000;
  const identityArguments = dockerHostIdentityArguments(
    process.getuid?.(),
    process.getgid?.()
  );
  run('docker', [
    'run', '--rm',
    ...identityArguments,
    '-v', `${root}:/workspace:ro`,
    '-v', `${outDir}:/evidence`,
    'openburnbar-linux-toolchain:mission-001',
    'bash', '-lc', script, '--',
    String(configuration.rows),
    String(configuration.samples),
    String(configuration.warmups),
    String(configuration.soakSeconds),
    String(configuration.seed),
    containerOutput,
    containerStreamOutput
  ], 'matched-performance-linux-transcript.txt', timeoutMs);
  mergeStreamResult(output, streamOutput);
}

function copyInput(input, destination) {
  const source = path.resolve(input);
  if (source !== destination) fs.copyFileSync(source, destination);
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  const identity = provenanceIdentity(options);
  const budget = readJSON(budgetPath);
  const configuration = budget.matched?.profiles?.[options.profile];
  if (!configuration) throw new Error(`Unknown profile ${options.profile}`);
  fs.mkdirSync(outDir, { recursive: true });

  const macosPath = path.join(outDir, 'matched-performance-macos.json');
  const linuxPath = path.join(outDir, 'matched-performance-linux.json');
  if (options.macosInput) copyInput(options.macosInput, macosPath);
  if (options.linuxInput) copyInput(options.linuxInput, linuxPath);

  if (options.mode === 'macos') {
    const startedAt = new Date().toISOString();
    runMacOS(configuration, macosPath);
    stampReport(macosPath, 'macos', options.profile, identity, startedAt);
    console.log(JSON.stringify(readJSON(macosPath), null, 2));
    return;
  }
  if (options.mode === 'linux') {
    const startedAt = new Date().toISOString();
    runLinux(configuration, linuxPath);
    stampReport(linuxPath, 'linux', options.profile, identity, startedAt);
    console.log(JSON.stringify(readJSON(linuxPath), null, 2));
    return;
  }
  if (options.mode !== 'compare') {
    if (!options.macosInput) {
      const startedAt = new Date().toISOString();
      runMacOS(configuration, macosPath);
      stampReport(macosPath, 'macos', options.profile, identity, startedAt);
    }
    if (!options.linuxInput) {
      const startedAt = new Date().toISOString();
      runLinux(configuration, linuxPath);
      stampReport(linuxPath, 'linux', options.profile, identity, startedAt);
    }
  }
  if (!fs.existsSync(macosPath) || !fs.existsSync(linuxPath)) {
    throw new Error('Comparison requires both matched-performance-macos.json and matched-performance-linux.json');
  }

  const report = compareMatchedPerformance({
    macos: readJSON(macosPath),
    linux: readJSON(linuxPath),
    budget,
    profile: options.profile,
    expectedProvenance: {
      gitCommit: identity.gitCommit,
      packageVersion: identity.packageVersion,
      sourceDigest: identity.sourceDigest,
      candidateRunId: identity.candidate.runId,
      candidateArtifactDigest: identity.candidate.artifactDigest
    }
  });
  report.runner = 'openburnbar-matched-performance-v2';
  report.host = { platform: process.platform, architecture: os.arch() };
  report.inputs = {
    macos: path.relative(root, macosPath),
    linux: path.relative(root, linuxPath),
    budget: path.relative(root, budgetPath)
  };
  fs.writeFileSync(
    path.join(outDir, 'matched-performance-comparison.json'),
    JSON.stringify(report, null, 2) + '\n'
  );
  console.log(JSON.stringify(report, null, 2));
  process.exit(report.pass ? 0 : 1);
}

try {
  main();
} catch (error) {
  console.error(`run-matched-performance: ${error.message}`);
  process.exit(1);
}
