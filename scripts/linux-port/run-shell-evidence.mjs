#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  TEXT_EXPANSION_NATIVE_RECEIPT,
  writeTextExpansionNativeEvidence
} from './text-expansion-native-evidence.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const appDir = path.join(root, 'apps/linux-desktop');
const evidenceOutput = process.env.OB_EVIDENCE_OUT ?? process.env.OPENBURNBAR_LINUX_EVIDENCE_OUT;
const outDir = evidenceOutput
  ? path.resolve(evidenceOutput)
  : path.join(root, 'docs/linux-port/evidence/mission-001-shell-ux');
fs.mkdirSync(outDir, { recursive: true });

const env = { ...process.env, OB_EVIDENCE_OUT: outDir };

const r = spawnSync('npm', ['test'], { cwd: appDir, encoding: 'utf8', env });
const transcript = [
  `### shell evidence harness`,
  `OB_EVIDENCE_OUT=${outDir}`,
  `npm test`,
  `exit_code=${r.status ?? 1}`,
  r.stdout,
  r.stderr
].join('\n');
fs.appendFileSync(path.join(outDir, 'smoke-transcript.txt'), '\n' + transcript + '\n');
writeTextExpansionNativeEvidence(outDir);

const artifacts = [
  'route-snapshot-plan.json',
  'route-a11y-user-flow-transcript.json',
  'automated-a11y-scan.json',
  'axe-route-accessibility-scan.json',
  'a11y-keyboard-transcript.json',
  'token-visual-diff.json',
  'failure-state-transcript.json',
  'onboarding-flow-transcript.json',
  'daemon-route-transcript.json',
  'pet-tier-matrix.json',
  'text-expansion-safety-proof.json',
  'visual-ux-matrix.json',
  'reduced-motion-capture.json',
  'provider-glyph-logo-cases.json',
  'visual-review.md',
  'accessibility-surface-evidence.json',
  'settings-account-update-support-scenarios.json',
  'onboarding-linux-flow-evidence.json',
  'pet-runtime-behavior-evidence.json',
  'text-expansion-crud-safety-evidence.json',
  TEXT_EXPANSION_NATIVE_RECEIPT
];
const missing = artifacts.filter((a) => !fs.existsSync(path.join(outDir, a)));
if (missing.length) {
  console.error('Missing evidence artifacts:', missing.join(', '));
  process.exit(1);
}
process.exit(r.status ?? 1);
