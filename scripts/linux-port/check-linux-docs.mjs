#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { reanchorEvidenceDir, repoRoot, writeJson } from './lib/linux-release-common.mjs';

const files = [
  'docs/linux-port/README.md',
  'docs/linux-port/release-runbook.md',
  'docs/linux-port/parity-ledger.md',
  'docs/linux-port/factory-pr-handoff.md',
  'docs/linux-port/runtime-capabilities.md',
  'docs/linux-port/accessibility-validation.md',
  'docs/linux-port/performance-reliability-validation.md',
  'docs/RELEASE_MACOS.md',
  'docs/security/SUPPLY_CHAIN_PROVENANCE.md',
  'README.md',
  'CHANGELOG.md'
];
const forbiddenClaims = [
  /Linux\s+release\s+is\s+published/i,
  /latest-linux\.json\s+is\s+live/i,
  /AppImage\s+is\s+release-ready/i,
  /Flatpak\s+is\s+published/i,
  /AUR\s+package\s+is\s+published/i
];
const failures = [];

const parityAuditArtifacts = [
  'docs/linux-port/LINUX_MACOS_PARITY_INDEPENDENT_AUDIT_2026-07-09.md',
  'docs/linux-port/LINUX_MACOS_PARITY_INDEPENDENT_AUDIT_2026-07-09.html'
];
const requiredParityAuditSignals = [
  { pattern: /0\/40/u, label: 'strict 0/40 product status' },
  { pattern: /0\/7/u, label: 'strict 0/7 environment status' },
  { pattern: /parity claim is false|productParityClaim(?:=|[^a-z])false/iu, label: 'false parity claim' }
];
const staleParityAuditClaims = [
  /verify-linux-release\.mjs(?:<\/code>)?\s*(?:checks only recorded signature entries|still\s*reports green)/iu,
  /accepts blocked update\/?rollback evidence/iu,
  /JSON ledger says parity is true/iu
];

for (const rel of files) {
  const full = path.join(repoRoot, rel);
  if (!fs.existsSync(full)) {
    failures.push({ file: rel, message: 'file missing' });
    continue;
  }
  const text = fs.readFileSync(full, 'utf8');
  for (const pattern of forbiddenClaims) {
    if (pattern.test(text)) failures.push({ file: rel, message: `forbidden stale claim: ${pattern}` });
  }
  const shouldCheckLinks = rel.startsWith('docs/linux-port/') || rel === 'docs/RELEASE_MACOS.md';
  if (shouldCheckLinks) {
    const linkPattern = /\[[^\]]+\]\(([^)]+)\)/g;
    for (const match of text.matchAll(linkPattern)) {
      const href = match[1];
      if (/^(https?:|mailto:|#|[a-z]+:\/\/)/.test(href)) continue;
      const target = href.split('#')[0];
      if (!target) continue;
      const resolved = path.resolve(path.dirname(full), target);
      if (!fs.existsSync(resolved)) {
        failures.push({ file: rel, message: `broken local link: ${href}` });
      }
    }
  }
}

for (const rel of parityAuditArtifacts) {
  const full = path.join(repoRoot, rel);
  if (!fs.existsSync(full)) {
    failures.push({ file: rel, message: 'parity audit artifact is missing' });
    continue;
  }
  const text = fs.readFileSync(full, 'utf8');
  for (const { pattern, label } of requiredParityAuditSignals) {
    if (!pattern.test(text)) failures.push({ file: rel, message: `missing ${label}` });
  }
  for (const pattern of staleParityAuditClaims) {
    if (pattern.test(text)) failures.push({ file: rel, message: `stale parity-audit claim: ${pattern}` });
  }
}

const implementationPlan = path.join(repoRoot, 'docs/linux-port/FULL_PARITY_IMPLEMENTATION_PLAN_2026-07-09.md');
if (!fs.existsSync(implementationPlan)) {
  failures.push({ file: 'docs/linux-port/FULL_PARITY_IMPLEMENTATION_PLAN_2026-07-09.md', message: 'implementation plan is missing' });
} else {
  const planText = fs.readFileSync(implementationPlan, 'utf8');
  if (!planText.includes('## Current-head reconciliation')) {
    failures.push({ file: 'docs/linux-port/FULL_PARITY_IMPLEMENTATION_PLAN_2026-07-09.md', message: 'current-head reconciliation is missing' });
  }
  if (!planText.includes('Loop 1 - factual source verification (historical snapshot)')) {
    failures.push({ file: 'docs/linux-port/FULL_PARITY_IMPLEMENTATION_PLAN_2026-07-09.md', message: 'historical baseline marker is missing' });
  }
}

const schema = fs.readFileSync(path.join(repoRoot, 'docs/SCHEMA_SQLITE.sql'), 'utf8');
if (!schema.includes('search_documents') || !schema.includes('provider')) {
  failures.push({ file: 'docs/SCHEMA_SQLITE.sql', message: 'schema mirror is missing expected Linux data-store terms' });
}

const report = {
  generatedAt: new Date().toISOString(),
  files,
  passed: failures.length === 0,
  failures
};
// Never rewrite sealed mission-001-release evidence. Local gates archive under mission-002.
writeJson(path.join(reanchorEvidenceDir, 'docs-check.json'), report);
console.log(JSON.stringify(report, null, 2));
process.exit(failures.length === 0 ? 0 : 1);
