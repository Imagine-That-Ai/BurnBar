import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { validateArchitectureShardSet } from './lib/linux-release-shards.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const assembler = path.join(repoRoot, 'scripts/linux-port/assemble-linux-release.mjs');
const assemblerSource = fs.readFileSync(assembler, 'utf8');
const signingKeyName = 'OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM';

const manifest = {
  requiredArtifacts: ['appimage', 'deb', 'rpm', 'daemon'],
  supportedArchitectures: ['aarch64', 'x86_64']
};
const version = '1.2.3';
const commit = '0123456789abcdef0123456789abcdef01234567';
const firebaseAppId = '1:123456789:web:linuxabcdef012345';

function shard(architecture) {
  return {
    schemaVersion: 1,
    version,
    architecture,
    firebaseAppId,
    git: { commit, dirty: false },
    blockers: [],
    artifacts: manifest.requiredArtifacts.map((type) => ({ type, architecture }))
  };
}

test('complete native architecture shard matrix passes', () => {
  assert.deepEqual(validateArchitectureShardSet({
    manifest,
    shards: [shard('aarch64'), shard('x86_64')],
    version,
    commit
  }), []);
});

test('missing architecture and artifact fail closed', () => {
  const aarch64 = shard('aarch64');
  aarch64.artifacts.pop();
  const failures = validateArchitectureShardSet({ manifest, shards: [aarch64], version, commit });
  assert.ok(failures.some((failure) => /missing architecture shard: x86_64/.test(failure)));
  assert.ok(failures.some((failure) => /missing required shard artifact: daemon:aarch64/.test(failure)));
});

test('missing, invalid, and cross-architecture Firebase app identities fail closed', () => {
  const missing = shard('aarch64');
  delete missing.firebaseAppId;
  const invalid = shard('x86_64');
  invalid.firebaseAppId = '1:123:linux:not-web';
  let failures = validateArchitectureShardSet({ manifest, shards: [missing, invalid], version, commit });
  assert.ok(failures.some((failure) => /aarch64 firebaseAppId is missing or invalid/.test(failure)));
  assert.ok(failures.some((failure) => /x86_64 firebaseAppId is missing or invalid/.test(failure)));

  const mismatched = shard('x86_64');
  mismatched.firebaseAppId = '1:987654321:web:linuxfedcba543210';
  failures = validateArchitectureShardSet({
    manifest,
    shards: [shard('aarch64'), mismatched],
    version,
    commit
  });
  assert.ok(failures.some((failure) => /x86_64 firebaseAppId does not match/.test(failure)));
});

test('duplicate, cross-commit, dirty, and unexpected shards fail closed', () => {
  const first = shard('aarch64');
  const duplicate = shard('aarch64');
  duplicate.git.commit = 'f'.repeat(40);
  duplicate.git.dirty = true;
  duplicate.artifacts.push({ type: 'tarball', architecture: 'x86_64' });
  const failures = validateArchitectureShardSet({
    manifest,
    shards: [first, duplicate, shard('x86_64')],
    version,
    commit
  });
  for (const pattern of [
    /duplicate architecture shard/,
    /commit does not match/,
    /dirty checkout/,
    /cross-architecture/,
    /unexpected shard artifact/
  ]) assert.ok(failures.some((failure) => pattern.test(failure)), pattern);
});

test('aggregate assembly rejects legacy environment custody before child execution', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-aggregate-env-reject-'));
  const marker = path.join(root, 'child-ran');
  const bin = path.join(root, 'bin');
  fs.mkdirSync(bin);
  for (const command of ['git', 'python3']) {
    fs.writeFileSync(path.join(bin, command), `#!${process.execPath}\nrequire('node:fs').writeFileSync(${JSON.stringify(marker)}, 'ran');\n`, { mode: 0o755 });
  }
  const result = spawnSync(process.execPath, [assembler, '--private-key-stdin', '--version', version], {
    cwd: repoRoot,
    encoding: 'utf8',
    input: 'not-used',
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      [signingKeyName]: 'environment-secret-must-not-leak'
    }
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /is forbidden for release assembly/u);
  assert.doesNotMatch(result.stdout + result.stderr, /environment-secret-must-not-leak/u);
  assert.equal(fs.existsSync(marker), false);
  fs.rmSync(root, { recursive: true, force: true });
});

test('aggregate metadata children receive a signing-custody-scrubbed environment', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-aggregate-sentinel-'));
  const bin = path.join(root, 'bin');
  const childLog = path.join(root, 'children.jsonl');
  const out = path.join(root, 'out');
  const shards = path.join(root, 'shards');
  const evidence = path.join(root, 'evidence');
  fs.mkdirSync(bin);
  fs.mkdirSync(shards);
  fs.mkdirSync(evidence);

  fs.writeFileSync(path.join(bin, 'git'), `#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2);
fs.appendFileSync(process.env.OPENBURNBAR_CHILD_LOG, JSON.stringify({
  command: 'git',
  secret: process.env.${signingKeyName} ?? null,
  keyPath: process.env.OPENBURNBAR_LINUX_RELEASE_SIGNING_KEY_FILE ?? null,
  manifestKeyPath: process.env.OPENBURNBAR_LINUX_INSTALLED_MANIFEST_KEY_FILE ?? null
}) + '\\n');
if (args[0] === 'rev-parse') process.stdout.write('${commit}\\n');
else if (args[0] === 'branch') process.stdout.write('main\\n');
else if (args[0] === 'remote') process.stdout.write('https://github.com/Imagine-That-Ai/BurnBar.git\\n');
else if (args[0] === 'archive') {
  const output = args.find((arg) => arg.startsWith('--output=')).slice('--output='.length);
  fs.writeFileSync(output, 'source archive');
}
`, { mode: 0o755 });
  fs.writeFileSync(path.join(bin, 'python3'), `#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2);
fs.appendFileSync(process.env.OPENBURNBAR_CHILD_LOG, JSON.stringify({
  command: 'python3',
  secret: process.env.${signingKeyName} ?? null,
  keyPath: process.env.OPENBURNBAR_LINUX_RELEASE_SIGNING_KEY_FILE ?? null,
  manifestKeyPath: process.env.OPENBURNBAR_LINUX_INSTALLED_MANIFEST_KEY_FILE ?? null
}) + '\\n');
const output = args[args.indexOf('--output') + 1];
fs.writeFileSync(output, '{}\\n');
`, { mode: 0o755 });

  const { privateKey } = crypto.generateKeyPairSync('ed25519');
  const pem = privateKey.export({ format: 'pem', type: 'pkcs8' });
  const result = spawnSync(process.execPath, [
    assembler,
    '--private-key-stdin',
    '--version', version,
    '--channel', 'prerelease'
  ], {
    cwd: repoRoot,
    encoding: 'utf8',
    input: pem,
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      OPENBURNBAR_CHILD_LOG: childLog,
      OPENBURNBAR_LINUX_RELEASE_OUT: out,
      OPENBURNBAR_LINUX_SHARDS_DIR: shards,
      OPENBURNBAR_LINUX_EVIDENCE_OUT: evidence,
      OPENBURNBAR_LINUX_RELEASE_SIGNING_KEY_FILE: '/must/not/reach/children.pem',
      OPENBURNBAR_LINUX_INSTALLED_MANIFEST_KEY_FILE: '/must/not/reach/children-either.pem'
    }
  });
  assert.notEqual(result.status, 0, 'empty shard fixtures remain a release blocker');
  const rows = fs.readFileSync(childLog, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
  assert.ok(rows.length >= 7);
  for (const row of rows) {
    assert.equal(row.secret, null, `${row.command} secret`);
    assert.equal(row.keyPath, null, `${row.command} key path`);
    assert.equal(row.manifestKeyPath, null, `${row.command} manifest key path`);
  }
  fs.rmSync(root, { recursive: true, force: true });
});

test('aggregate key material loads only after the final subprocess boundary', () => {
  const keyLoad = assemblerSource.indexOf('// Load signing material only after the last build/metadata subprocess exits.');
  const mainEnd = assemblerSource.indexOf('\nfunction findNamedFiles');
  assert.ok(keyLoad > 0);
  assert.ok(assemblerSource.slice(0, mainEnd).lastIndexOf('runStep(') < keyLoad);
  assert.match(assemblerSource, /exactly one of --private-key-stdin or --private-key-file is required/u);
  assert.match(assemblerSource, /keyStat\.mode & 0o077/u);
});
