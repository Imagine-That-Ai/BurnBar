import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  candidateCloseRefusal,
  collectCandidateFingerprint
} from './lib/candidate-fingerprint.mjs';

function git(cwd, args) {
  const result = spawnSync('git', args, { cwd, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function initRepo() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-fingerprint-'));
  git(root, ['init']);
  git(root, ['config', 'user.email', 'm0@example.com']);
  git(root, ['config', 'user.name', 'M0']);
  fs.writeFileSync(path.join(root, 'README'), 'ok\n');
  git(root, ['add', 'README']);
  git(root, ['commit', '-m', 'init']);
  return root;
}

test('collectCandidateFingerprint records SHA and clean status', () => {
  const root = initRepo();
  const fingerprint = collectCandidateFingerprint(root);
  assert.equal(fingerprint.commitSha, git(root, ['rev-parse', 'HEAD']));
  assert.equal(fingerprint.dirty, false);
  assert.deepEqual(fingerprint.dirtyEntries, []);
  assert.equal(candidateCloseRefusal(fingerprint), null);
});

test('dirty tree is recorded and cannot close a candidate', () => {
  const root = initRepo();
  fs.writeFileSync(path.join(root, 'dirty.txt'), 'nope\n');
  const fingerprint = collectCandidateFingerprint(root);
  assert.equal(fingerprint.dirty, true);
  assert.ok(fingerprint.dirtyEntries.some((line) => line.includes('dirty.txt')));
  assert.match(candidateCloseRefusal(fingerprint), /dirty tree cannot be a closable candidate/);
});

test('candidateCloseRefusal rejects missing SHA and missing fingerprint', () => {
  assert.match(candidateCloseRefusal(null), /missing/);
  assert.match(
    candidateCloseRefusal({ commitSha: 'not-a-sha', dirty: false, dirtyEntries: [] }),
    /canonical/
  );
});
