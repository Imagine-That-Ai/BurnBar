import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  inspectEvidenceBundle,
  validateReleaseEvidence
} from './check-release-evidence.mjs';

const NATIVE = [{ path: 'Vendor/x', present: false, sha256: null }];

function git(cwd, args) {
  const result = spawnSync('git', args, { cwd, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function writeJson(root, relative, value) {
  const full = path.join(root, relative);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, `${JSON.stringify(value, null, 2)}\n`);
}

function seedRepo() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-release-ev-'));
  git(root, ['init']);
  git(root, ['config', 'user.email', 'm8@example.com']);
  git(root, ['config', 'user.name', 'M8']);
  fs.writeFileSync(path.join(root, 'README'), 'ok\n');
  git(root, ['add', 'README']);
  git(root, ['commit', '-m', 'init']);
  writeJson(root, 'docs/mobile-parity/store-readback.json', {
    schemaVersion: 1,
    id: 'openburnbar-mobile-store-readback-v1',
    status: 'blocked',
    apple: { status: 'blocked', version: null, build: null, artifactDigest: null, track: null, reviewState: null, testerAvailability: null },
    google: { status: 'blocked', version: null, build: null, artifactDigest: null, track: null, reviewState: null, testerAvailability: null }
  });
  writeJson(root, 'docs/mobile-parity/mobile-parity-ledger.json', {
    rows: [{ id: 'VAL-MOB-015', status: 'blocked' }]
  });
  fs.mkdirSync(path.join(root, 'docs/mobile-parity/evidence'), { recursive: true });
  fs.writeFileSync(path.join(root, 'docs/mobile-parity/evidence/README.md'), 'empty and blocked\n');
  return root;
}

test('repo release evidence checker is honest and exits 0', () => {
  const result = validateReleaseEvidence();
  assert.equal(result.passed, true, result.failures.join('\n'));
  assert.equal(result.receipt.closable, result.receipt.dirty !== true);
  assert.ok(['blocked', 'ran', 'failed'].includes(result.androidFirebase.status));
  assert.ok(['blocked', 'ran', 'failed'].includes(result.androidAbiPageSize.status));
  assert.ok(['blocked', 'ran', 'failed'].includes(result.androidAbiCoverage.status));
  assert.ok(result.commands.iosSourceFirestoreGraph.length > 0);
});

test('TODO lorem and PASS evidence files are rejected', () => {
  const root = seedRepo();
  fs.writeFileSync(path.join(root, 'docs/mobile-parity/evidence/todo.log'), 'TODO fill this in later\n');
  fs.writeFileSync(path.join(root, 'docs/mobile-parity/evidence/lorem.log'), 'lorem ipsum dolor sit amet\n');
  fs.writeFileSync(path.join(root, 'docs/mobile-parity/evidence/pass.log'), 'manual VoiceOver PASS\n');
  const inspected = inspectEvidenceBundle(root);
  const text = inspected.failures.join('\n');
  assert.match(text, /placeholder evidence rejected: .*todo\.log|TODO/i);
  assert.match(text, /lorem|placeholder/i);
  assert.match(text, /placeholder PASS evidence rejected: .*pass\.log/);
});

test('empty evidence file is rejected', () => {
  const root = seedRepo();
  fs.writeFileSync(path.join(root, 'docs/mobile-parity/evidence/empty.log'), '');
  const inspected = inspectEvidenceBundle(root);
  assert.ok(inspected.failures.some((line) => /empty evidence file rejected/.test(line)));
});

test('dirty candidate cannot close', () => {
  const root = seedRepo();
  const result = validateReleaseEvidence({
    repoRoot: root,
    fingerprint: {
      commitSha: git(root, ['rev-parse', 'HEAD']),
      dirty: true,
      dirtyEntries: ['?? dirty.txt'],
      nativeArtifacts: NATIVE
    },
    androidFirebase: { status: 'blocked', command: 'node scripts/ci/verify-android-firebase-release-config.mjs --strict-release', detail: 'missing config' },
    androidAbiPageSize: { status: 'blocked', command: './scripts/ci/verify-android-16kb-page-size.sh', detail: 'Android APK not present' },
    androidAbiCoverage: { status: 'blocked', command: 'node scripts/ci/verify-domain-core-android-universal-artifact.mjs', detail: 'artifact missing' }
  });
  assert.equal(result.receipt.closable, false);
  assert.equal(result.passed, true, result.failures.join('\n'));
  assert.ok(result.warnings.some((line) => /dirty tree/.test(line)));
});

test('store.status validated is accepted when apple/google fields, clean fingerprint, and digest are present', () => {
  const root = seedRepo();
  writeJson(root, 'docs/mobile-parity/store-readback.json', {
    schemaVersion: 1,
    id: 'openburnbar-mobile-store-readback-v1',
    status: 'validated',
    apple: {
      status: 'validated',
      version: '1.2.3',
      build: '45',
      artifactDigest: 'abc',
      track: 'testflight',
      reviewState: 'ready',
      testerAvailability: 'internal'
    },
    google: {
      status: 'validated',
      version: '1.2.3',
      build: '45',
      artifactDigest: 'def',
      track: 'closed',
      reviewState: 'ready',
      testerAvailability: 'closed'
    }
  });
  const result = validateReleaseEvidence({
    repoRoot: root,
    fingerprint: {
      commitSha: git(root, ['rev-parse', 'HEAD']),
      dirty: false,
      dirtyEntries: [],
      nativeArtifacts: [{ path: 'Vendor/x', present: true, sha256: 'deadbeef' }]
    },
    androidFirebase: { status: 'blocked', command: 'x', detail: 'missing config' },
    androidAbiPageSize: { status: 'blocked', command: 'x', detail: 'no apk' },
    androidAbiCoverage: { status: 'blocked', command: 'x', detail: 'no aar' }
  });
  assert.equal(result.passed, true, result.failures.join('\n'));
});

test('store.status validated is rejected without collected fields', () => {
  const root = seedRepo();
  writeJson(root, 'docs/mobile-parity/store-readback.json', {
    schemaVersion: 1,
    id: 'openburnbar-mobile-store-readback-v1',
    status: 'validated',
    apple: { status: 'blocked', version: null, build: null, artifactDigest: null, track: null, reviewState: null, testerAvailability: null },
    google: { status: 'blocked', version: null, build: null, artifactDigest: null, track: null, reviewState: null, testerAvailability: null }
  });
  const result = validateReleaseEvidence({
    repoRoot: root,
    fingerprint: {
      commitSha: git(root, ['rev-parse', 'HEAD']),
      dirty: false,
      dirtyEntries: [],
      nativeArtifacts: NATIVE
    },
    androidFirebase: { status: 'blocked', command: 'x', detail: 'missing config' },
    androidAbiPageSize: { status: 'blocked', command: 'x', detail: 'no apk' },
    androidAbiCoverage: { status: 'blocked', command: 'x', detail: 'no aar' }
  });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /cannot be validated without collected fields/);
});

test('fingerprint marked closable while dirty fails', () => {
  const root = seedRepo();
  const result = validateReleaseEvidence({
    repoRoot: root,
    receipt: {
      commitSha: git(root, ['rev-parse', 'HEAD']),
      dirty: true,
      dirtyEntries: ['?? dirty.txt'],
      closable: true,
      nativeArtifacts: NATIVE
    },
    androidFirebase: { status: 'blocked', command: 'x', detail: 'missing config' },
    androidAbiPageSize: { status: 'blocked', command: 'x', detail: 'no apk' },
    androidAbiCoverage: { status: 'blocked', command: 'x', detail: 'no aar' }
  });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /dirty candidate cannot close|closable but/);
});

test('VAL-MOB-015 validated without store readback fails', () => {
  const root = seedRepo();
  writeJson(root, 'docs/mobile-parity/mobile-parity-ledger.json', {
    rows: [{ id: 'VAL-MOB-015', status: 'validated' }]
  });
  const result = validateReleaseEvidence({
    repoRoot: root,
    fingerprint: {
      commitSha: git(root, ['rev-parse', 'HEAD']),
      dirty: false,
      dirtyEntries: [],
      nativeArtifacts: NATIVE
    },
    androidFirebase: { status: 'blocked', command: 'x', detail: 'missing config' },
    androidAbiPageSize: { status: 'blocked', command: 'x', detail: 'no apk' },
    androidAbiCoverage: { status: 'blocked', command: 'x', detail: 'no aar' }
  });
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /cannot be validated without store readback fields/);
});
