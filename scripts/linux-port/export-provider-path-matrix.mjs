#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const manifestPath = path.join(root, 'tools/provider-capabilities/provider-capabilities.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const matrix = {
  generatedAt: new Date().toISOString(),
  source: 'tools/provider-capabilities/provider-capabilities.json',
  schemaVersion: manifest.schemaVersion,
  xdg_notes: 'XDG config/data rewrites are explicit per provider; OPENBURNBAR_PROVIDER_HOME and SNAP_REAL_HOME override only home-relative provider paths.',
  providers: Object.fromEntries(manifest.providers.map((row) => [row.providerCase, {
    providerId: row.providerId,
    displayName: row.displayName,
    logical: row.linuxLogicalPath,
    filePattern: row.filePattern,
    parserSource: row.parserSource,
    xdgBehavior: row.xdgBehavior,
    quota: row.quota,
    chatRuntimeId: row.chatRuntimeId,
    accountConnect: row.accountConnect
  }]))
};

const out = process.argv[2] ?? path.join(root, 'docs/linux-port/evidence/mission-002-reanchor/provider-path-matrix.generated.json');
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, `${JSON.stringify(matrix, null, 2)}\n`);
console.log(`wrote ${out} (${manifest.providers.length} providers)`);
