import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  boundedOutputTail,
  extractPreflightedArchiveBytes,
  extractPreflightedArchiveFile,
  streamBinaryToFile,
  NATIVE_PACKAGE_NON_USR_PATH_ALLOWLIST
} from './lib/linux-native-package.mjs';

function commandAvailable(command) {
  return (process.env.PATH ?? '').split(path.delimiter).some((directory) => {
    try {
      fs.accessSync(path.join(directory, command), fs.constants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
}

// Larger than the 64 MiB captured-output bound: a payload this size would
// have to stream to disk; capturing it through spawnSync stdout would abort
// with ENOBUFS under the new metadata bound.
const LARGE_PAYLOAD_BYTES = 256 * 1024 * 1024;

test('payload-scale producer output streams to disk without entering process memory', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-stream-large-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const output = path.join(root, 'payload');
  const before = process.memoryUsage().rss;
  streamBinaryToFile('sh', ['-c', `head -c ${LARGE_PAYLOAD_BYTES} /dev/zero`], output);
  const after = process.memoryUsage().rss;
  assert.equal(fs.statSync(output).size, LARGE_PAYLOAD_BYTES);
  assert.equal(fs.statSync(output).mode & 0o777, 0o600);
  // The payload must not have been buffered: RSS growth stays far below the
  // payload size (allow generous headroom for GC noise).
  assert.ok(after - before < LARGE_PAYLOAD_BYTES / 4,
    `RSS grew by ${after - before} bytes while streaming ${LARGE_PAYLOAD_BYTES}`);
});

test('a failing producer removes its partial payload and bounds its stderr tail', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-stream-fail-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const output = path.join(root, 'payload');
  // Hostile/failing producer: emits 8 MiB of stderr noise, some stdout, then
  // fails. The partial stdout must be cleaned up and the error message must
  // carry only a bounded stderr tail.
  let error = null;
  try {
    streamBinaryToFile('sh', ['-c',
      'head -c 1024 /dev/zero; head -c 8388608 /dev/zero | tr "\\0" "e" 1>&2; exit 7'
    ], output);
  } catch (caught) {
    error = caught;
  }
  assert.ok(error, 'failing producer must throw');
  assert.equal(fs.existsSync(output), false, 'partial payload file must be removed');
  assert.ok(error.message.length < 64 * 1024, `error message too large: ${error.message.length}`);
  assert.match(error.message, /\[truncated \d+ bytes\]/u);
});

test('a wedged producer is killed by the tool timeout and leaves no payload', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-stream-timeout-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const output = path.join(root, 'payload');
  const startedAt = Date.now();
  assert.throws(
    () => streamBinaryToFile('sh', ['-c', 'sleep 3600'], output, { timeoutMs: 1500 }),
    /timeout|terminated by signal/u
  );
  assert.ok(Date.now() - startedAt < 60_000, 'timeout must fire promptly');
  assert.equal(fs.existsSync(output), false, 'timed-out payload file must be removed');
});

test('archive extraction reads the archive from disk and keeps traversal protections', {
  skip: commandAvailable('bsdtar') ? false : 'requires bsdtar'
}, (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-stream-extract-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const payload = path.join(root, 'payload');
  fs.mkdirSync(path.join(payload, 'usr/bin'), { recursive: true });
  fs.writeFileSync(path.join(payload, 'usr/bin/openburnbar'), 'binary\n');
  const archive = path.join(root, 'good.tar');
  const packed = spawnSync('bsdtar', ['-cf', archive, '-C', payload, '.'], { encoding: 'utf8' });
  assert.equal(packed.status, 0, packed.stderr);

  const destination = path.join(root, 'out');
  extractPreflightedArchiveFile(archive, destination, {
    allowedPaths: NATIVE_PACKAGE_NON_USR_PATH_ALLOWLIST
  });
  assert.equal(fs.readFileSync(path.join(destination, 'usr/bin/openburnbar'), 'utf8'), 'binary\n');

  // Hostile member outside /usr must still fail closed through the file path.
  const hostile = path.join(root, 'hostile');
  fs.mkdirSync(path.join(hostile, 'etc/cron.d'), { recursive: true });
  fs.writeFileSync(path.join(hostile, 'etc/cron.d/backdoor'), '* * * * * root id\n');
  const hostileArchive = path.join(root, 'hostile.tar');
  const packedHostile = spawnSync('bsdtar', ['-cf', hostileArchive, '-C', hostile, '.'], { encoding: 'utf8' });
  assert.equal(packedHostile.status, 0, packedHostile.stderr);
  assert.throws(
    () => extractPreflightedArchiveFile(hostileArchive, path.join(root, 'out-hostile'), {
      allowedPaths: NATIVE_PACKAGE_NON_USR_PATH_ALLOWLIST
    }),
    /outside \/usr/u
  );
  assert.equal(fs.existsSync(path.join(root, 'out-hostile')), false);
});

test('a member-listing bomb hits the bounded listing buffer instead of exhausting memory', {
  skip: commandAvailable('bsdtar') ? false : 'requires bsdtar'
}, (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-stream-listing-bomb-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const payload = path.join(root, 'payload');
  const deep = path.join(payload, 'usr/share/openburnbar');
  fs.mkdirSync(deep, { recursive: true });
  for (let index = 0; index < 64; index += 1) {
    fs.writeFileSync(path.join(deep, `member-${'x'.repeat(120)}-${index}`), 'a');
  }
  const archive = path.join(root, 'listing-bomb.tar');
  const packed = spawnSync('bsdtar', ['-cf', archive, '-C', payload, '.'], { encoding: 'utf8' });
  assert.equal(packed.status, 0, packed.stderr);
  // With a deliberately tiny listing bound, the listing pass must fail closed
  // (ENOBUFS surfaces as a spawn error) rather than extract anything.
  assert.throws(
    () => extractPreflightedArchiveFile(archive, path.join(root, 'out'), {
      allowedPaths: NATIVE_PACKAGE_NON_USR_PATH_ALLOWLIST,
      listingMaxBuffer: 512
    }),
    /bsdtar/u
  );
  assert.equal(fs.existsSync(path.join(root, 'out')), false);
});

test('the byte-buffer compatibility wrapper delegates to the streaming file path', {
  skip: commandAvailable('bsdtar') ? false : 'requires bsdtar'
}, (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-stream-bytes-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const payload = path.join(root, 'payload');
  fs.mkdirSync(path.join(payload, 'usr/bin'), { recursive: true });
  fs.writeFileSync(path.join(payload, 'usr/bin/openburnbar'), 'binary\n');
  const archive = path.join(root, 'bytes.tar');
  const packed = spawnSync('bsdtar', ['-cf', archive, '-C', payload, '.'], { encoding: 'utf8' });
  assert.equal(packed.status, 0, packed.stderr);
  const destination = path.join(root, 'out');
  extractPreflightedArchiveBytes(fs.readFileSync(archive), destination, {
    allowedPaths: NATIVE_PACKAGE_NON_USR_PATH_ALLOWLIST
  });
  assert.equal(fs.readFileSync(path.join(destination, 'usr/bin/openburnbar'), 'utf8'), 'binary\n');
  assert.throws(() => extractPreflightedArchiveBytes(Buffer.alloc(0), destination), /archive is empty/u);
});

test('boundedOutputTail truncates oversized diagnostics deterministically', () => {
  const oversized = Buffer.alloc(1024 * 1024, 0x61);
  const tail = boundedOutputTail(oversized);
  assert.ok(tail.length < 32 * 1024);
  assert.match(tail, /^\[truncated \d+ bytes\]\n/u);
  assert.equal(boundedOutputTail(Buffer.alloc(0)), '');
  assert.equal(boundedOutputTail(null), '');
});
