#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {
  manifestPath,
  readJson,
  relative,
  releaseEvidenceDir,
  repoRoot,
  runStep,
  sha256,
  writeJson
} from './lib/linux-release-common.mjs';

const args = new Set(process.argv.slice(2));
const allowBlocked = args.has('--allow-blocked');
const outDir = path.resolve(process.env.OPENBURNBAR_LINUX_RELEASE_OUT ?? releaseEvidenceDir);
const manifest = readJson(manifestPath);
const failures = [];
const warnings = [];

function fail(message, detail = {}) {
  failures.push({ message, ...detail });
}

function warn(message, detail = {}) {
  warnings.push({ message, ...detail });
}

function requireFile(relPath, label) {
  const full = path.join(repoRoot, relPath);
  if (!fs.existsSync(full)) {
    fail(`${label} is missing`, { file: relPath });
    return false;
  }
  return true;
}

const closurePath = path.join(outDir, 'package-closure.json');
const latestPath = path.join(outDir, manifest.updateMetadata.draftName);
if (!fs.existsSync(closurePath)) fail('package-closure.json is missing; run build-linux-release first.');
if (!fs.existsSync(latestPath)) fail(`${manifest.updateMetadata.draftName} is missing; run build-linux-release first.`);

const closure = fs.existsSync(closurePath) ? readJson(closurePath) : { artifacts: [], blockers: [] };
const latest = fs.existsSync(latestPath) ? readJson(latestPath) : { blockers: [] };

for (const required of manifest.requiredArtifacts) {
  const artifact = closure.artifacts?.find((row) => row.type === required);
  if (!artifact) {
    fail(`Required ${required} artifact is absent from package closure.`);
    continue;
  }
  if (!requireFile(artifact.file, `${required} artifact`)) continue;
  const actual = sha256(path.join(repoRoot, artifact.file));
  if (actual !== artifact.sha256) {
    fail(`${required} artifact checksum drifted`, { file: artifact.file, expected: artifact.sha256, actual });
  }
}

for (const [kind, relPath] of Object.entries(manifest.tailMetadata)) {
  if (!requireFile(relPath, `${kind} metadata`)) continue;
  if (kind === 'desktopEntry') {
    const desktopFile = fs.readFileSync(path.join(repoRoot, relPath), 'utf8');
    if (!desktopFile.includes('Type=Application') || !desktopFile.includes('Exec=')) {
      fail('desktop entry lacks Type=Application or Exec=', { file: relPath });
    }
  }
}

const checksumRel = closure.sidecars?.checksums;
if (checksumRel && requireFile(checksumRel, 'checksums sidecar')) {
  const lines = fs.readFileSync(path.join(repoRoot, checksumRel), 'utf8').split('\n').filter(Boolean);
  for (const line of lines) {
    const match = line.match(/^([a-f0-9]{64})  (.+)$/);
    if (!match) {
      fail('checksum sidecar contains an invalid line', { line });
      continue;
    }
    const [, expected, file] = match;
    if (!requireFile(file, 'checksum target')) continue;
    const actual = sha256(path.join(repoRoot, file));
    if (actual !== expected) fail('checksum sidecar mismatch', { file, expected, actual });
  }
} else {
  fail('checksums sidecar is missing from package closure.');
}

for (const sidecar of ['sbom', 'vex', 'provenancePredicate']) {
  const relPath = closure.sidecars?.[sidecar];
  if (!relPath) {
    fail(`${sidecar} sidecar is missing from package closure.`);
  } else {
    requireFile(relPath, `${sidecar} sidecar`);
  }
}

const signatures = readJsonOrNull(path.join(repoRoot, closure.sidecars?.provenancePredicate ?? ''));
if (!signatures?.signatures?.length) {
  fail('No Ed25519/minisign-compatible detached signatures are recorded.');
}

if (!latest.primaryArtifact || latest.promotionState !== 'candidate') {
  fail('latest-linux draft is not promotable.', {
    promotionState: latest.promotionState ?? null,
    primaryArtifact: latest.primaryArtifact ?? null
  });
}

const publicLatest = path.join(repoRoot, 'website/public/downloads/latest-linux.json');
if (fs.existsSync(publicLatest)) {
  if (failures.length > 0 || latest.promotionState !== 'candidate') {
    fail('public latest-linux.json exists while release verification is not green.', {
      file: relative(publicLatest)
    });
  }
} else {
  warn('public latest-linux.json is absent, as expected until promotion is green.');
}

const smokeDir = path.join(outDir, 'smoke');
for (const smoke of ['package-install-uninstall.log', 'package-update-rollback.log']) {
  if (!fs.existsSync(path.join(smokeDir, smoke))) {
    fail('required package smoke log is missing', { file: relative(path.join(smokeDir, smoke)) });
  }
}
// Fail closed on package content asserts — log existence alone is not green.
const smokeSummaryPath = path.join(smokeDir, 'package-smoke-summary.json');
const smokeInstallLog = path.join(smokeDir, 'package-install-uninstall.log');
if (fs.existsSync(smokeSummaryPath)) {
  const smokeSummary = readJson(smokeSummaryPath);
  if (smokeSummary.passed !== true || (smokeSummary.failedCount ?? 0) > 0) {
    fail('package smoke summary is not green (content/install asserts failed).', {
      file: relative(smokeSummaryPath),
      failedCount: smokeSummary.failedCount ?? null,
      failed: (smokeSummary.failed ?? []).slice(0, 10)
    });
  }
} else if (fs.existsSync(smokeInstallLog)) {
  const logBody = fs.readFileSync(smokeInstallLog, 'utf8');
  const assertFails = [...logBody.matchAll(/^## (assert [^\n]+)\n(?:cwd=.*\n)?exit_code=([1-9]\d*)/gm)];
  if (assertFails.length > 0) {
    fail('package-install-uninstall.log contains failing asserts; re-run smoke-linux-packages.mjs until exit 0.', {
      file: relative(smokeInstallLog),
      failingAsserts: assertFails.map((m) => ({ command: m[1], exitCode: Number(m[2]) })).slice(0, 20)
    });
  }
  // Also require rpm/deb launch script evidence in the log body when those artifacts exist.
  const needsRpm = (closure.artifacts ?? []).some((a) => a.type === 'rpm');
  const needsDeb = (closure.artifacts ?? []).some((a) => a.type === 'deb');
  if (needsDeb && !/assert deb contains openburnbar-daemon-launch[\s\S]*?exit_code=0/.test(logBody)) {
    fail('deb launch-script assert did not pass in smoke log.', { file: relative(smokeInstallLog) });
  }
  if (needsRpm && !/assert rpm contains openburnbar-daemon-launch[\s\S]*?exit_code=0/.test(logBody)) {
    fail('rpm launch-script assert did not pass in smoke log.', { file: relative(smokeInstallLog) });
  }
} else {
  fail('package smoke summary/log missing; cannot prove package content asserts.');
}

const gitStatus = runStep('git', ['status', '--porcelain=v1']).stdout.split('\n').filter(Boolean);
const unexpectedDirty = gitStatus.filter((entry) => {
  const path = entry.slice(3);
  return !path.startsWith(relative(outDir) + '/');
});
if (unexpectedDirty.length > 0) {
  fail('release checkout has unexpected dirty files outside generated Linux release evidence.', {
    dirtyEntries: unexpectedDirty.slice(0, 40)
  });
}

const ledger = runStep('node', ['scripts/linux-port/validate-parity-ledger.mjs'], { cwd: repoRoot });
if (ledger.exitCode !== 0) {
  fail('parity ledger is not green for release promotion.', {
    command: ledger.command,
    stdout: ledger.stdout,
    stderr: ledger.stderr
  });
}

const allBlockers = uniqueBlockers([...(closure.blockers ?? []), ...(latest.blockers ?? [])]);
if (allBlockers.length > 0) {
  const blocker = allowBlocked ? warn : fail;
  blocker('release blockers are recorded in package metadata.', { blockers: allBlockers });
}

const report = {
  generatedAt: new Date().toISOString(),
  outDir: relative(outDir),
  allowBlocked,
  passed: failures.length === 0 || (allowBlocked && failures.every((item) => item.message.includes('blocker'))),
  failures,
  warnings
};
writeJson(path.join(outDir, 'release-verification.json'), report);
console.log(JSON.stringify(report, null, 2));
process.exit(failures.length === 0 || allowBlocked ? 0 : 1);

function readJsonOrNull(file) {
  try {
    if (!file || !fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

function uniqueBlockers(blockers) {
  const seen = new Set();
  return blockers.filter((blocker) => {
    const key = `${blocker.kind ?? ''}\0${blocker.message ?? ''}\0${blocker.log ?? ''}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}
