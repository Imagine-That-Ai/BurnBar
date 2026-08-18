#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { isMainModule, readJson } from './lib/check-support.mjs';
import {
  LEDGER_MARKDOWN_PATH,
  LEDGER_PATH,
  REGISTRY_PATH
} from './lib/mobile-parity-constants.mjs';
import { renderMobileParityLedger } from './lib/mobile-parity-validate.mjs';
import { resolveConfinedPath } from './lib/path-confine.mjs';
import { repoRoot } from './lib/repo-root.mjs';

function readRepoJson(relativePath) {
  const document = readJson(repoRoot, relativePath, 'cannot read');
  if (document.error) throw new Error(document.error);
  return document.value;
}

function main() {
  const ledger = readRepoJson(LEDGER_PATH);
  const registry = readRepoJson(REGISTRY_PATH);
  const rendered = renderMobileParityLedger(ledger, registry);
  const output = resolveConfinedPath(repoRoot, LEDGER_MARKDOWN_PATH);
  if (output.error) throw new Error(output.error);
  if (process.argv.includes('--check')) {
    const current = output.exists ? fs.readFileSync(output.path, 'utf8') : '';
    if (current !== rendered) {
      console.error(`${LEDGER_MARKDOWN_PATH} is stale; run render-mobile-parity-ledger.mjs.`);
      process.exit(1);
    }
    return;
  }
  fs.mkdirSync(path.dirname(output.path), { recursive: true });
  fs.writeFileSync(output.path, rendered, 'utf8');
}

if (isMainModule(import.meta.url)) main();
