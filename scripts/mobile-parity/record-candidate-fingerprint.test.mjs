import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { collectCandidateFingerprint } from './lib/candidate-fingerprint.mjs';
import {
  buildCandidateReceipt,
  writeCandidateReceipt
} from './record-candidate-fingerprint.mjs';

function git(cwd, args) {
  const result = spawnSync('git', args, { cwd, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function initRepo() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-record-fp-'));
  git(root, ['init']);
  git(root, ['config', 'user.email', 'm8@example.com']);
  git(root, ['config', 'user.name', 'M8']);
  fs.writeFileSync(path.join(root, 'README'), 'ok\n');
  git(root, ['add', 'README']);
  git(root, ['commit', '-m', 'init']);
  return root;
}

test('clean candidate receipt is closable', () => {
  const root = initRepo();
  const receipt = buildCandidateReceipt(root);
  assert.equal(receipt.dirty, false);
  assert.equal(receipt.closable, true);
  assert.equal(receipt.closeRefusal, null);
  assert.equal(receipt.packageIds.ios, 'com.openburnbar.app');
  assert.equal(receipt.packageIds.android, 'com.openburnbar');
  assert.equal(receipt.version.ios, null);
  assert.equal(receipt.build.android, null);
});

test('dirty candidate cannot close', () => {
  const root = initRepo();
  fs.writeFileSync(path.join(root, 'dirty.txt'), 'nope\n');
  const receipt = buildCandidateReceipt(root);
  assert.equal(receipt.dirty, true);
  assert.equal(receipt.closable, false);
  assert.match(receipt.closeRefusal, /dirty tree cannot be a closable candidate/);
});

test('write-then-inspect receipt does not contain placeholder', () => {
  const root = initRepo();
  const result = writeCandidateReceipt(root, 'docs/mobile-parity/evidence/candidate-fingerprint.json', {
    fingerprint: collectCandidateFingerprint(root)
  });
  assert.equal(result.wrote, true);
  const written = fs.readFileSync(path.join(root, result.path), 'utf8');
  assert.match(written, /unbound until a signed artifact is recorded/);
  assert.doesNotMatch(written, /\bPLACEHOLDER\b/i);
  const parsed = JSON.parse(written);
  assert.ok(Array.isArray(parsed.nativeArtifacts));
});

test('--require-closable refuses to write a dirty receipt as closable', () => {
  const root = initRepo();
  fs.writeFileSync(path.join(root, 'dirty.txt'), 'nope\n');
  const result = writeCandidateReceipt(root, 'docs/mobile-parity/evidence/candidate-fingerprint.json', {
    requireClosable: true,
    fingerprint: collectCandidateFingerprint(root)
  });
  assert.equal(result.wrote, false);
  assert.match(result.error, /dirty tree cannot be a closable candidate/);
  assert.equal(
    fs.existsSync(path.join(root, 'docs/mobile-parity/evidence/candidate-fingerprint.json')),
    false
  );
});
