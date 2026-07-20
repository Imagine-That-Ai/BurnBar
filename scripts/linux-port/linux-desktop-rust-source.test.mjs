import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import {
  LINUX_DESKTOP_RUST_SOURCE_ROOT,
  linuxDesktopRustSourcePaths,
  readLinuxDesktopRustSource
} from './lib/linux-desktop-rust-source.mjs';

function fixture() {
  const root = fs.mkdtempSync(path.join(process.cwd(), '.linux-rust-source-test-'));
  const sourceRoot = path.join(root, LINUX_DESKTOP_RUST_SOURCE_ROOT);
  fs.mkdirSync(path.join(sourceRoot, 'nested'), { recursive: true });
  fs.writeFileSync(path.join(sourceRoot, 'z.rs'), 'const Z: u8 = 1;\n');
  fs.writeFileSync(path.join(sourceRoot, 'a.rs'), 'const A: u8 = 2;\n');
  fs.writeFileSync(path.join(sourceRoot, 'nested', 'b.rs'), 'const B: u8 = 3;\n');
  fs.writeFileSync(path.join(sourceRoot, 'ignored.txt'), 'not Rust\n');
  return { root, sourceRoot };
}

test('Linux desktop Rust source reader recursively returns stable source order', () => {
  const value = fixture();
  try {
    assert.deepEqual(linuxDesktopRustSourcePaths(value.root), [
      `${LINUX_DESKTOP_RUST_SOURCE_ROOT}/a.rs`,
      `${LINUX_DESKTOP_RUST_SOURCE_ROOT}/nested/b.rs`,
      `${LINUX_DESKTOP_RUST_SOURCE_ROOT}/z.rs`
    ]);
    const source = readLinuxDesktopRustSource(value.root);
    assert.ok(source.indexOf('const A') < source.indexOf('const B'));
    assert.ok(source.indexOf('const B') < source.indexOf('const Z'));
    assert.equal(source.includes('not Rust'), false);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('Linux desktop Rust source reader rejects symlinked source entries', () => {
  const value = fixture();
  try {
    fs.symlinkSync(path.join(value.sourceRoot, 'a.rs'), path.join(value.sourceRoot, 'linked.rs'));
    assert.throws(
      () => linuxDesktopRustSourcePaths(value.root),
      /Rust source must not be a symlink/u
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
