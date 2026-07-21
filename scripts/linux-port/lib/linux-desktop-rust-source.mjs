import fs from 'node:fs';
import path from 'node:path';
import { repoRoot } from './linux-release-common.mjs';

export const LINUX_DESKTOP_RUST_SOURCE_ROOT = 'apps/linux-desktop/src-tauri/src';
export const LINUX_DESKTOP_RUST_SOURCE_READER_PATH =
  'scripts/linux-port/lib/linux-desktop-rust-source.mjs';

function comparePathNames(left, right) {
  return Buffer.compare(Buffer.from(left, 'utf8'), Buffer.from(right, 'utf8'));
}

export function linuxDesktopRustSourcePaths(root = repoRoot) {
  const sourceRoot = path.join(root, LINUX_DESKTOP_RUST_SOURCE_ROOT);
  const paths = [];

  function collect(directory) {
    const entries = fs.readdirSync(directory, { withFileTypes: true })
      .sort((left, right) => comparePathNames(left.name, right.name));
    for (const entry of entries) {
      const absolute = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) {
        throw new Error(`Linux desktop Rust source must not be a symlink: ${absolute}`);
      }
      if (entry.isDirectory()) {
        collect(absolute);
      } else if (entry.isFile() && entry.name.endsWith('.rs')) {
        paths.push(path.relative(root, absolute).split(path.sep).join('/'));
      }
    }
  }

  collect(sourceRoot);
  if (paths.length === 0) throw new Error('Linux desktop Rust source set is empty');
  return paths;
}

export function readLinuxDesktopRustSource(root = repoRoot) {
  return linuxDesktopRustSourcePaths(root)
    .map((relativePath) => {
      const source = fs.readFileSync(path.join(root, relativePath), 'utf8');
      return `// source: ${relativePath}\n${source}`;
    })
    .join('\n');
}
