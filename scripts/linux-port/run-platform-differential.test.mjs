import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  buildReport,
  compareArtifacts,
  normalizeArtifact,
  parseArgs,
  run,
  validateIgnorePaths
} from './run-platform-differential.mjs';

function tempArtifacts(macos, linux) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-differential-'));
  const macosPath = path.join(root, 'macos.json');
  const linuxPath = path.join(root, 'linux.json');
  fs.writeFileSync(macosPath, JSON.stringify(macos), 'utf8');
  fs.writeFileSync(linuxPath, JSON.stringify(linux), 'utf8');
  return { root, macosPath, linuxPath };
}

test('normalization sorts object keys and redacts credential-shaped fields', () => {
  assert.deepEqual(normalizeArtifact({ b: 2, a: 1, apiKey: 'do-not-print', totalTokens: 4 }), {
    a: 1,
    apiKey: '[REDACTED]',
    b: 2,
    totalTokens: 4
  });
  const report = compareArtifacts({ apiKey: 'one' }, { apiKey: 'two' });
  assert.equal(report.status, 'exact_match');
  assert.equal(JSON.stringify(report).includes('one'), false);
  assert.equal(JSON.stringify(report).includes('two'), false);
});

test('exact artifacts produce matching checksums and no differences', () => {
  const report = compareArtifacts({ version: '1.0', rows: [{ id: 'a' }] }, { rows: [{ id: 'a' }], version: '1.0' });
  assert.equal(report.status, 'exact_match');
  assert.equal(report.macos.sha256, report.linux.sha256);
  assert.deepEqual(report.differences, []);
});

test('ignored volatile paths are replaced on both sides', () => {
  const report = compareArtifacts(
    { version: '1.0', metadata: { generatedAt: 'mac' } },
    { version: '1.0', metadata: { generatedAt: 'linux' } },
    { ignore: ['$.metadata.generatedAt'] }
  );
  assert.equal(report.status, 'exact_match');
  assert.deepEqual(report.ignoredPaths, ['$.metadata.generatedAt']);
});

test('ignore paths fail closed instead of allowing a root or wildcard bypass', () => {
  assert.throws(() => validateIgnorePaths(['$']), /not canonical/u);
  assert.throws(() => validateIgnorePaths(['$.payload.*']), /not canonical/u);
  assert.throws(() => compareArtifacts({ value: 1 }, { value: 2 }, { ignore: ['$'] }), /not canonical/u);
});

test('nested mismatch reports a stable path without dumping secrets', () => {
  const report = compareArtifacts(
    { providers: [{ id: 'openai', models: ['a'] }], secret: 'mac-secret' },
    { providers: [{ id: 'openai', models: ['b'] }], secret: 'linux-secret' }
  );
  assert.equal(report.status, 'differences');
  assert.deepEqual(report.differences, [{ path: '$.providers[0].models[0]', expected: 'a', actual: 'b', kind: 'changed' }]);
  assert.equal(JSON.stringify(report).includes('mac-secret'), false);
  assert.equal(JSON.stringify(report).includes('linux-secret'), false);
});

test('missing and malformed artifacts are invalid', () => {
  const missing = buildReport({ macos: '/missing/macos.json', linux: '/missing/linux.json', ignore: [] });
  assert.equal(missing.status, 'invalid');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-differential-invalid-'));
  const macosPath = path.join(root, 'macos.json');
  const linuxPath = path.join(root, 'linux.json');
  fs.writeFileSync(macosPath, '{not-json', 'utf8');
  fs.writeFileSync(linuxPath, '{}', 'utf8');
  assert.equal(buildReport({ macos: macosPath, linux: linuxPath, ignore: [] }).status, 'invalid');
});

test('CLI returns explicit exit codes and writes machine-readable output', () => {
  const artifacts = tempArtifacts({ version: '1' }, { version: '2' });
  const outputPath = path.join(artifacts.root, 'report.json');
  let stdout = '';
  let stderr = '';
  const exitCode = run(
    ['--macos', artifacts.macosPath, '--linux', artifacts.linuxPath, '--out', outputPath],
    { stdout: { write: (value) => { stdout += value; } }, stderr: { write: (value) => { stderr += value; } } }
  );
  assert.equal(exitCode, 1);
  assert.equal(stderr, '');
  assert.equal(JSON.parse(stdout).status, 'differences');
  assert.equal(JSON.parse(fs.readFileSync(outputPath, 'utf8')).status, 'differences');
  assert.deepEqual(parseArgs(['--macos', 'm.json', '--linux', 'l.json', '--ignore=$.generatedAt']).ignore, ['$.generatedAt']);
});
