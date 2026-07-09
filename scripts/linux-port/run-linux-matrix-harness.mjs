#!/usr/bin/env node
/**
 * Phase 6 matrix harness scaffold (VAL-MATRIX-001).
 * Records environment capabilities and blocked.json reasons without claiming live DE proof.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { reanchorEvidenceDir, repoRoot, runStep, writeJson } from './lib/linux-release-common.mjs';

const outDir = path.join(
  reanchorEvidenceDir,
  'matrix',
  process.env.OPENBURNBAR_LINUX_MATRIX_ID || `${os.platform()}-${os.arch()}-${Date.now()}`
);

const envProbe = {
  platform: os.platform(),
  arch: os.arch(),
  release: os.release(),
  sessionType: process.env.XDG_SESSION_TYPE || null,
  desktop: process.env.XDG_CURRENT_DESKTOP || process.env.DESKTOP_SESSION || null,
  waylandDisplay: process.env.WAYLAND_DISPLAY || null,
  display: process.env.DISPLAY || null,
  dbusSession: Boolean(process.env.DBUS_SESSION_BUS_ADDRESS),
  runtimeDir: process.env.XDG_RUNTIME_DIR || null
};

const checks = [];
function addCheck(id, ok, detail) {
  checks.push({ id, ok, detail });
}

addCheck('os-linux', envProbe.platform === 'linux', `platform=${envProbe.platform}`);
addCheck('session-desktop', Boolean(envProbe.desktop || envProbe.sessionType), `desktop=${envProbe.desktop}`);
addCheck('display-server', Boolean(envProbe.waylandDisplay || envProbe.display), 'need WAYLAND_DISPLAY or DISPLAY');
addCheck('dbus-session', envProbe.dbusSession, 'Secret Service / notifications need session bus');

const secretTool = runStep('bash', ['-lc', 'command -v secret-tool || true']);
addCheck('secret-tool', Boolean(secretTool.stdout.trim()), secretTool.stdout.trim() || 'secret-tool not on PATH');

const kwallet = runStep('bash', ['-lc', 'command -v kwallet-query || true']);
addCheck('kwallet-query', Boolean(kwallet.stdout.trim()), kwallet.stdout.trim() || 'kwallet-query not on PATH');

const blocked = checks
  .filter((c) => !c.ok)
  .map((c) => ({
    capability: c.id,
    status: 'blocked',
    platformReason: c.detail,
    recordedAt: new Date().toISOString()
  }));

const report = {
  generatedAt: new Date().toISOString(),
  environment: envProbe,
  checks,
  blocked,
  note:
    'Scaffold only: does not claim multi-DE screenshot proof. Run on target desktops and attach AT-SPI/screenshot artifacts under this directory.',
  val: ['VAL-MATRIX-001', 'VAL-MATRIX-002', 'VAL-SECURITY-001']
};

fs.mkdirSync(outDir, { recursive: true });
writeJson(path.join(outDir, 'matrix-probe.json'), report);
writeJson(path.join(outDir, 'blocked.json'), { blocked, generatedAt: report.generatedAt });

console.log(JSON.stringify({ outDir: path.relative(repoRoot, outDir), passed: blocked.length === 0, report }, null, 2));
process.exit(0);
