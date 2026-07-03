#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const MISSION_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const SHELL_EVIDENCE_DIR = path.join(MISSION_ROOT, 'docs/linux-port/evidence/mission-001-shell-ux');

export const REQUIRED_JSON_ARTIFACTS = [
  'route-snapshot-plan.json',
  'route-a11y-user-flow-transcript.json',
  'automated-a11y-scan.json',
  'a11y-keyboard-transcript.json',
  'token-visual-diff.json',
  'failure-state-transcript.json',
  'onboarding-flow-transcript.json',
  'daemon-route-transcript.json',
  'pet-tier-matrix.json',
  'text-expansion-safety-proof.json'
];

export const REQUIRED_DESKTOP_SESSION_ARTIFACTS = [
  'linux-desktop-session-report.json',
  'screenshot-linux-desktop-first-run.png',
  'screenshot-linux-desktop-after-tray-open.png',
  'packaged-route-session-transcript.json',
  'runtime-perf-samples.jsonl',
  'tray-menu-actions.json',
  'tray-menu-layout.txt',
  'tray-quit-menu-event.txt',
  'accessibility-tree-linux-desktop.txt',
  'daemon-session-oracle.json'
];

export const PACKAGED_ROUTE_IDS = [
  'overview',
  'insights',
  'database',
  'providers',
  'projects',
  'missions',
  'activity',
  'chat',
  'memory',
  'computer-use',
  'settings',
  'account',
  'updates',
  'support',
  'onboarding',
  'pet',
  'text-expansion'
];

export const REQUIRED_PERF_ROWS = [
  'app.start',
  'route.navigation',
  'ipc.health.roundtrip',
  'tray.open',
  'chat.firstToken.progress',
  'db.migration.open.query',
  'parser.incremental.run',
  'memory.search',
  'media.control.stage'
];

export const FORBIDDEN_TRANSCRIPT_PATHS = [
  '/Users/albertonunez/Documents/Developer/BurnBar'
];

export function writeRunManifest(extra = {}) {
  fs.mkdirSync(SHELL_EVIDENCE_DIR, { recursive: true });
  const manifest = {
    generatedAt: new Date().toISOString(),
    missionWorktree: MISSION_ROOT,
    lane: 'W06ShellEvidenceRepair',
    ...extra
  };
  fs.writeFileSync(path.join(SHELL_EVIDENCE_DIR, 'shell-evidence-run-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  return manifest;
}

export function assertMissionPathsInText(text, label) {
  const hits = FORBIDDEN_TRANSCRIPT_PATHS.filter((needle) => text.includes(needle));
  if (hits.length) {
    throw new Error(`${label} references non-mission checkout path(s): ${hits.join(', ')}`);
  }
}
