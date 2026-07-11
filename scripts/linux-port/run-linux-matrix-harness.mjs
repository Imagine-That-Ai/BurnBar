#!/usr/bin/env node
/**
 * Record one fail-closed Linux desktop matrix result (VAL-MATRIX-001).
 * A requested support row can become ready only when this exact checkout,
 * installed-package proof, accessibility proof, and native-shell proof all
 * agree with the live host.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  gitInfo,
  readJson,
  reanchorEvidenceDir,
  repoRoot,
  runStep,
  writeJson
} from './lib/linux-release-common.mjs';
import {
  evidenceCommit,
  evidenceEnvironmentId,
  nativeRequirementPasses,
  nativeShellEvidenceRequirements
} from './lib/native-shell-evidence.mjs';

function argumentValue(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1]?.trim() || null : null;
}

function normalizeArchitecture(value) {
  if (value === 'x64') return 'x86_64';
  if (value === 'arm64') return 'aarch64';
  return value;
}

function parseOSRelease() {
  const file = '/etc/os-release';
  if (!fs.existsSync(file)) return {};
  return Object.fromEntries(
    fs.readFileSync(file, 'utf8')
      .split('\n')
      .map((line) => line.match(/^([A-Z_]+)=(.*)$/))
      .filter(Boolean)
      .map((match) => [match[1], match[2].replace(/^"|"$/g, '')])
  );
}

function desktopMatches(expected, detected) {
  const value = detected.toLowerCase();
  if (expected === 'GNOME') return value.includes('gnome');
  if (expected === 'KDE Plasma') return value.includes('kde') || value.includes('plasma');
  if (expected === 'Sway/wlroots') return value.includes('sway');
  return false;
}

function osMatches(expected, release) {
  if (expected === 'Ubuntu 24.04') {
    return release.ID === 'ubuntu' && release.VERSION_ID === '24.04';
  }
  if (expected === 'Fedora') return release.ID === 'fedora';
  if (expected === 'Arch Linux') return release.ID === 'arch';
  return false;
}

const requestedEnvironment = argumentValue('--environment');
const requirements = readJson(path.join(repoRoot, 'docs/linux-port/product-parity-requirements.json'));
const expected = requestedEnvironment
  ? requirements.minimumSupportMatrix.find((row) => row.id === requestedEnvironment)
  : null;

if (requestedEnvironment && !expected) {
  console.error(`Unknown Linux support environment: ${requestedEnvironment}`);
  process.exit(2);
}

const release = parseOSRelease();
const detected = {
  platform: os.platform(),
  architecture: normalizeArchitecture(os.arch()),
  kernelRelease: os.release(),
  osId: release.ID ?? null,
  osVersion: release.VERSION_ID ?? null,
  session: (process.env.XDG_SESSION_TYPE ?? '').toLowerCase() || null,
  desktop: process.env.XDG_CURRENT_DESKTOP ?? process.env.DESKTOP_SESSION ?? null,
  waylandDisplay: process.env.WAYLAND_DISPLAY ?? null,
  display: process.env.DISPLAY ?? null,
  dbusSession: Boolean(process.env.DBUS_SESSION_BUS_ADDRESS),
  runtimeDirectory: process.env.XDG_RUNTIME_DIR ?? null
};
const git = gitInfo();
const checks = [];

function addCheck(id, passed, detail) {
  checks.push({ id, passed, detail });
}

addCheck('os-linux', detected.platform === 'linux', `platform=${detected.platform}`);
addCheck('checkout-clean', !git.dirty, git.dirty ? git.dirtyEntries.slice(0, 20).join(', ') : git.commit);
addCheck('session-bus', detected.dbusSession, 'DBUS_SESSION_BUS_ADDRESS must be present');
addCheck(
  'display-server',
  Boolean(detected.waylandDisplay || detected.display),
  `WAYLAND_DISPLAY=${detected.waylandDisplay ?? ''} DISPLAY=${detected.display ?? ''}`
);
addCheck('runtime-directory', Boolean(detected.runtimeDirectory), `XDG_RUNTIME_DIR=${detected.runtimeDirectory ?? ''}`);

if (expected) {
  addCheck('declared-os', osMatches(expected.os, release), `${release.ID ?? 'unknown'} ${release.VERSION_ID ?? ''}`.trim());
  addCheck('declared-architecture', detected.architecture === expected.architecture, detected.architecture);
  addCheck('declared-session', detected.session === expected.session.toLowerCase(), detected.session ?? 'missing');
  addCheck('declared-desktop', desktopMatches(expected.desktop, detected.desktop ?? ''), detected.desktop ?? 'missing');
}

const secretTool = runStep('bash', ['-lc', 'command -v secret-tool || true']).stdout.trim();
const kwalletQuery = runStep('bash', ['-lc', 'command -v kwallet-query || true']).stdout.trim();
if (expected?.desktop === 'KDE Plasma') {
  addCheck('kwallet-query', Boolean(kwalletQuery), kwalletQuery || 'kwallet-query not on PATH');
} else {
  addCheck('secret-tool', Boolean(secretTool), secretTool || 'secret-tool not on PATH');
}

function addEvidenceCheck(id, environmentName) {
  const suppliedPath = process.env[environmentName]?.trim();
  if (!suppliedPath) {
    addCheck(id, false, `${environmentName} is required`);
    return null;
  }
  const absolute = path.resolve(suppliedPath);
  if (!fs.existsSync(absolute)) {
    addCheck(id, false, `evidence file does not exist: ${absolute}`);
    return null;
  }
  try {
    const evidence = readJson(absolute);
    const commit = evidence.git?.commit ?? evidence.commit ?? null;
    const passed = evidence.passed === true && commit === git.commit;
    addCheck(id, passed, passed ? path.relative(repoRoot, absolute) : `passed=${evidence.passed} commit=${commit ?? 'missing'}`);
    return { path: path.relative(repoRoot, absolute), passed: evidence.passed === true, commit };
  } catch (error) {
    addCheck(id, false, `invalid JSON: ${error.message}`);
    return null;
  }
}

function addNativeShellEvidenceCheck() {
  const id = 'native-shell-evidence';
  const environmentName = 'OPENBURNBAR_LINUX_NATIVE_SHELL_EVIDENCE';
  const suppliedPath = process.env[environmentName]?.trim();
  if (!suppliedPath) {
    addCheck(id, false, `${environmentName} is required`);
    return null;
  }

  const absolute = path.resolve(suppliedPath);
  if (!fs.existsSync(absolute)) {
    addCheck(id, false, `evidence file does not exist: ${absolute}`);
    return null;
  }

  try {
    const evidence = readJson(absolute);
    const commit = evidenceCommit(evidence);
    const environmentId = evidenceEnvironmentId(evidence);
    const missing = nativeShellEvidenceRequirements
      .filter((requirement) => !nativeRequirementPasses(evidence, requirement))
      .map((requirement) => requirement.id);
    const environmentMatches = !requestedEnvironment || environmentId === requestedEnvironment;
    const passed = evidence.passed === true && commit === git.commit && environmentMatches && missing.length === 0;
    const detail = passed
      ? path.relative(repoRoot, absolute)
      : [
          `passed=${evidence.passed}`,
          `commit=${commit ?? 'missing'}`,
          `environment=${environmentId ?? 'missing'}`,
          `missing=${missing.length > 0 ? missing.join(',') : 'none'}`
        ].join(' ');

    addCheck(id, passed, detail);
    return {
      path: path.relative(repoRoot, absolute),
      passed: evidence.passed === true,
      commit,
      environmentId,
      missing
    };
  } catch (error) {
    addCheck(id, false, `invalid JSON: ${error.message}`);
    return null;
  }
}

const installedEvidence = addEvidenceCheck('installed-package-evidence', 'OPENBURNBAR_LINUX_INSTALLED_EVIDENCE');
const accessibilityEvidence = addEvidenceCheck('installed-accessibility-evidence', 'OPENBURNBAR_LINUX_ACCESSIBILITY_EVIDENCE');
const nativeShellEvidence = addNativeShellEvidenceCheck();
const blocked = checks
  .filter((check) => !check.passed)
  .map((check) => ({
    capability: check.id,
    status: 'blocked',
    platformReason: check.detail,
    recordedAt: new Date().toISOString()
  }));

const generatedAt = new Date().toISOString();
const report = {
  schemaVersion: 1,
  generatedAt,
  environmentId: requestedEnvironment,
  status: blocked.length === 0 ? 'ready' : 'blocked',
  git,
  declared: expected,
  detected,
  evidenceInputs: { installedEvidence, accessibilityEvidence, nativeShellEvidence },
  nativeShellEvidenceRequirements: nativeShellEvidenceRequirements.map(({ id, description }) => ({ id, description })),
  checks,
  blocked,
  note:
    'Ready means this exact clean checkout passed installed-package, accessibility, and native-shell P-26/P-27 evidence on the declared live desktop.'
};

const defaultOut = requestedEnvironment
  ? path.join(repoRoot, 'docs/linux-port/evidence/product-parity/environments', `${requestedEnvironment}.json`)
  : path.join(reanchorEvidenceDir, 'matrix', `${os.platform()}-${os.arch()}-${Date.now()}`, 'matrix-probe.json');
const outFile = path.resolve(process.env.OPENBURNBAR_LINUX_MATRIX_OUT ?? defaultOut);
fs.mkdirSync(path.dirname(outFile), { recursive: true });
writeJson(outFile, report);

console.log(JSON.stringify({ outFile: path.relative(repoRoot, outFile), passed: blocked.length === 0, report }, null, 2));
process.exit(requestedEnvironment && blocked.length > 0 ? 1 : 0);
