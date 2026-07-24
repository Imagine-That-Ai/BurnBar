import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { readStableRegularFile, readStableUtf8File } from './lib/stable-file.mjs';

test('stable file reader returns bytes and descriptor metadata for a regular file', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-stable-file-'));
  try {
    const file = path.join(root, 'subject.txt');
    fs.writeFileSync(file, 'sealed bytes');
    const snapshot = readStableRegularFile(file, 'sealed subject');
    assert.equal(snapshot.bytes.toString('utf8'), 'sealed bytes');
    assert.equal(snapshot.stat.isFile(), true);
    assert.equal(readStableUtf8File(file, 'sealed subject'), 'sealed bytes');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('stable file reader rejects directories and symbolic links', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-stable-file-reject-'));
  try {
    const file = path.join(root, 'subject.txt');
    const link = path.join(root, 'subject-link.txt');
    fs.writeFileSync(file, 'sealed bytes');
    fs.symlinkSync(file, link);
    assert.throws(() => readStableRegularFile(root, 'directory'), /must be a regular file/u);
    assert.throws(
      () => readStableRegularFile(link, 'symbolic link'),
      (error) => ['ELOOP', 'EMLINK'].includes(error?.code)
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
