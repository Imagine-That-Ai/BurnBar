import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const squashfsMagic = Buffer.from('hsqs', 'ascii');

export function squashfsCandidateOffsets(file, { chunkSize = 1024 * 1024 } = {}) {
  if (!Number.isSafeInteger(chunkSize) || chunkSize < squashfsMagic.length) {
    throw new Error(`invalid AppImage scan chunk size: ${chunkSize}`);
  }

  const fd = fs.openSync(file, 'r');
  const chunk = Buffer.allocUnsafe(chunkSize);
  const offsets = [];
  let carry = Buffer.alloc(0);
  let position = 0;
  try {
    while (true) {
      const read = fs.readSync(fd, chunk, 0, chunk.length, position);
      if (read === 0) break;
      const data = Buffer.concat([carry, chunk.subarray(0, read)]);
      const base = position - carry.length;
      let cursor = 0;
      while (cursor <= data.length - squashfsMagic.length) {
        const index = data.indexOf(squashfsMagic, cursor);
        if (index < 0) break;
        offsets.push(base + index);
        cursor = index + 1;
      }
      carry = data.subarray(Math.max(0, data.length - (squashfsMagic.length - 1)));
      position += read;
    }
  } finally {
    fs.closeSync(fd);
  }
  return offsets;
}

function defaultSquashfsProbe(file, offset) {
  const result = spawnSync('unsquashfs', ['-s', '-offset', String(offset), file], {
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024
  });
  return result.status === 0;
}

export function findAppImageFilesystemOffset(file, probe = defaultSquashfsProbe, options = {}) {
  const offsets = squashfsCandidateOffsets(file, options);
  for (const offset of offsets) {
    if (probe(file, offset)) return offset;
  }
  throw new Error(
    `AppImage has no valid SquashFS filesystem offset (checked ${offsets.length} magic candidates): ${file}`
  );
}
