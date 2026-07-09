#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { repoRoot, writeJson } from './lib/linux-release-common.mjs';

const files = [
  'docs/linux-port/README.md',
  'docs/linux-port/release-runbook.md',
  'docs/linux-port/parity-ledger.md',
  'docs/linux-port/factory-pr-handoff.md',
  'docs/linux-port/runtime-capabilities.md',
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
writeJson(path.join(repoRoot, 'docs/linux-port/evidence/mission-001-release/docs-check.json'), report);
console.log(JSON.stringify(report, null, 2));
process.exit(failures.length === 0 ? 0 : 1);
