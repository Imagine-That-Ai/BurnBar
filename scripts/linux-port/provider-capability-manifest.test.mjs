import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const root = path.resolve(import.meta.dirname, '../..');
const generator = path.join(root, 'tools/provider-capabilities/generate-provider-capabilities.mjs');
const canonical = JSON.parse(readFileSync(path.join(root, 'tools/provider-capabilities/provider-capabilities.json'), 'utf8'));

function runMutation(mutate) {
  const directory = mkdtempSync(path.join(tmpdir(), 'obb-provider-manifest-'));
  try {
    const manifest = structuredClone(canonical);
    mutate(manifest);
    const file = path.join(directory, 'manifest.json');
    writeFileSync(file, `${JSON.stringify(manifest)}\n`);
    return spawnSync(process.execPath, [generator, '--manifest', file, '--check'], { cwd: root, encoding: 'utf8' });
  } finally { rmSync(directory, { recursive: true, force: true }); }
}

test('canonical provider manifest and generated outputs are current', () => {
  const result = spawnSync(process.execPath, [generator, '--check'], { cwd: root, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(canonical.providers.length, 33);
});

test('duplicate provider identity mutation fails closed', () => {
  const result = runMutation((manifest) => { manifest.providers[1].providerCase = manifest.providers[0].providerCase; });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /duplicate providerCase/);
});

test('pathless parser and incomplete path mutations fail closed', () => {
  let result = runMutation((manifest) => { manifest.providers.find((row) => row.providerCase === 'openAI').parserSource = 'FakeParser'; });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /parserSource cannot be set for no-local-logs/);
  result = runMutation((manifest) => { manifest.providers.find((row) => row.providerCase === 'codex').filePattern = null; });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /path rows require all three/);
});
