#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDirectory, '../..');
const sourcePath = path.join(
  repoRoot,
  'docs/linux-port/LINUX_MACOS_PARITY_INDEPENDENT_AUDIT_2026-07-09.md'
);
const outputPath = path.join(
  repoRoot,
  'docs/linux-port/LINUX_MACOS_PARITY_INDEPENDENT_AUDIT_2026-07-09.html'
);
const checkOnly = process.argv.includes('--check');

const requireFromLinuxTools = createRequire(path.join(scriptDirectory, 'package.json'));
let marked;
try {
  ({ marked } = requireFromLinuxTools('marked'));
} catch {
  console.error('marked is unavailable; run npm ci --prefix scripts/linux-port first');
  process.exit(2);
}

const source = fs.readFileSync(sourcePath, 'utf8');
const current = fs.readFileSync(outputPath, 'utf8');
const mainOpen = '<main id="report">';
const mainClose = '</main>';
const start = current.indexOf(mainOpen);
const end = current.indexOf(mainClose, start);
if (start < 0 || end < 0) {
  console.error(`unable to locate report wrapper in ${path.relative(repoRoot, outputPath)}`);
  process.exit(2);
}

const rendered = marked.parse(source, { gfm: true });
const expected = `${current.slice(0, start + mainOpen.length)}\n${rendered}${current.slice(end)}`;
if (expected === current) {
  console.log('Linux parity audit HTML is current.');
  process.exit(0);
}

if (checkOnly) {
  console.error('Linux parity audit HTML is stale; run render-linux-parity-audit-html.mjs.');
  process.exit(1);
}

fs.writeFileSync(outputPath, expected);
console.log(`Updated ${path.relative(repoRoot, outputPath)}.`);
