#!/usr/bin/env node
/**
 * Generate provider path matrix JSON from the Linux TS registry (Issue 28).
 * Usage: node scripts/linux-port/export-provider-path-matrix.mjs [out.json]
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const registryPath = path.join(
  root,
  'apps/linux-desktop/src/providerPathRegistry.ts'
);
// Parse registry rows without a TS build step: extract logicalPath lines.
const src = fs.readFileSync(registryPath, 'utf8');
const rows = [];
const blockRe =
  /providerId:\s*'([^']+)'[\s\S]*?displayLabel:\s*'([^']+)'[\s\S]*?logicalPath:\s*'([^']+)'[\s\S]*?filePattern:\s*'([^']+)'[\s\S]*?parserSourceId:\s*'([^']+)'/g;
let m;
while ((m = blockRe.exec(src))) {
  rows.push({
    providerId: m[1],
    displayLabel: m[2],
    logical: m[3],
    filePattern: m[4],
    parserSourceId: m[5]
  });
}

const matrix = {
  generatedAt: new Date().toISOString(),
  source: 'apps/linux-desktop/src/providerPathRegistry.ts',
  xdg_notes:
    'Daemon support dir uses XDG_DATA_HOME/openburnbar (lowercase); runtime socket is XDG_RUNTIME_DIR/openburnbar/daemon.sock; VS Code globalStorage uses ~/.config or XDG_CONFIG_HOME on Linux.',
  providers: Object.fromEntries(
    rows.map((r) => [
      r.parserSourceId,
      { logical: r.logical, filePattern: r.filePattern, providerId: r.providerId }
    ])
  )
};

const out =
  process.argv[2] ??
  path.join(
    root,
    'docs/linux-port/evidence/mission-002-reanchor/provider-path-matrix.generated.json'
  );
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, `${JSON.stringify(matrix, null, 2)}\n`);
console.log(`wrote ${out} (${rows.length} providers)`);
