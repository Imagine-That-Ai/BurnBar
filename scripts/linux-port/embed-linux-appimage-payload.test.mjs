import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { requiredPayloadPaths, validatePayload } from './embed-linux-appimage-payload.mjs';
import {
  findAppImageFilesystemOffset,
  squashfsCandidateOffsets
} from './lib/appimage-filesystem.mjs';

test('AppImage payload validator requires daemon, Swift, and SQLCipher runtime', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-appimage-payload-'));
  fs.writeFileSync(path.join(root, 'openburnbar-daemon'), 'daemon');
  fs.mkdirSync(path.join(root, 'swift'));
  fs.mkdirSync(path.join(root, 'native'));
  fs.writeFileSync(path.join(root, 'native/libsqlcipher.so.0'), 'sqlcipher');

  assert.deepEqual(requiredPayloadPaths, [
    'openburnbar-daemon',
    'swift',
    'native/libsqlcipher.so.0'
  ]);
  assert.equal(validatePayload(root), root);
  fs.rmSync(root, { recursive: true, force: true });
});

test('AppImage payload validator fails closed when a runtime is absent', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-appimage-payload-missing-'));
  fs.writeFileSync(path.join(root, 'openburnbar-daemon'), 'daemon');
  fs.mkdirSync(path.join(root, 'swift'));

  assert.throws(() => validatePayload(root), /native\/libsqlcipher\.so\.0/);
  fs.rmSync(root, { recursive: true, force: true });
});

test('AppImage filesystem scanner handles chunk boundaries and validates candidates', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-appimage-offset-'));
  const image = path.join(root, 'fixture.AppImage');
  const fixture = Buffer.alloc(32, 0);
  fixture.write('hsqs', 4, 'ascii');
  fixture.write('hsqs', 14, 'ascii');
  fs.writeFileSync(image, fixture);

  assert.deepEqual(squashfsCandidateOffsets(image, { chunkSize: 8 }), [4, 14]);
  assert.equal(
    findAppImageFilesystemOffset(image, (_file, offset) => offset === 14, { chunkSize: 8 }),
    14
  );
  assert.throws(
    () => findAppImageFilesystemOffset(image, () => false, { chunkSize: 8 }),
    /no valid SquashFS filesystem offset/
  );
  fs.rmSync(root, { recursive: true, force: true });
});
