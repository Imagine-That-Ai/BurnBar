import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
} from "node:fs";
import { resolve } from "node:path";

function regularFileError(label, path) {
  return new Error(`${label} must be a regular file: ${path}`);
}

function sameFile(left, right) {
  return left.dev === right.dev && left.ino === right.ino;
}

export function readRegularFileSync(path, { encoding, label = "file" } = {}) {
  const absolute = resolve(path);
  const noFollow = constants.O_NOFOLLOW ?? 0;
  let descriptor;
  try {
    descriptor = openSync(absolute, constants.O_RDONLY | noFollow);
  } catch (error) {
    if (error?.code === "ELOOP") throw regularFileError(label, absolute);
    throw error;
  }

  try {
    const opened = fstatSync(descriptor);
    if (!opened.isFile()) throw regularFileError(label, absolute);

    // O_NOFOLLOW protects the open on POSIX. The identity check also rejects a
    // pathname swapped after open and provides a fail-closed fallback elsewhere.
    const current = lstatSync(absolute);
    if (
      !current.isFile() ||
      current.isSymbolicLink() ||
      !sameFile(opened, current)
    ) {
      throw regularFileError(label, absolute);
    }

    return encoding === undefined
      ? readFileSync(descriptor)
      : readFileSync(descriptor, { encoding });
  } finally {
    closeSync(descriptor);
  }
}

export function readRegularFileIfExistsSync(path, options) {
  try {
    return readRegularFileSync(path, options);
  } catch (error) {
    if (error?.code === "ENOENT") return undefined;
    throw error;
  }
}
