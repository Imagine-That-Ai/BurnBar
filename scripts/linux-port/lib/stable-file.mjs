import fs from 'node:fs';

function unchanged(before, after) {
  return before.dev === after.dev
    && before.ino === after.ino
    && before.size === after.size
    && before.mtimeMs === after.mtimeMs
    && before.ctimeMs === after.ctimeMs;
}

/** Read bytes through one no-follow descriptor and reject concurrent mutation. */
export function readStableRegularFile(file, label = 'file') {
  const descriptor = fs.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
  try {
    const before = fs.fstatSync(descriptor);
    if (!before.isFile()) throw new Error(`${label} must be a regular file`);
    const bytes = fs.readFileSync(descriptor);
    const after = fs.fstatSync(descriptor);
    if (!unchanged(before, after)) throw new Error(`${label} changed while it was read`);
    return { bytes, stat: after };
  } finally {
    fs.closeSync(descriptor);
  }
}

export function readStableUtf8File(file, label = 'file') {
  return readStableRegularFile(file, label).bytes.toString('utf8');
}
