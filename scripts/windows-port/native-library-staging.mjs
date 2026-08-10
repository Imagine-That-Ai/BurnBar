import {
  copyFileSync,
  mkdirSync,
  renameSync,
  rmSync,
} from "node:fs";
import { dirname, resolve } from "node:path";

import {
  regularFile,
  sha256File,
} from "../lib/domain-core-release-evidence.mjs";

export function stageNativeLibrary(sourcePath, destinationPath) {
  const source = regularFile(sourcePath, "built native library");
  const destination = resolve(destinationPath);
  if (source === destination) {
    return {
      source,
      destination,
      sha256: sha256File(source),
      staged: false,
    };
  }

  mkdirSync(dirname(destination), { recursive: true });
  const temporary = `${destination}.tmp-${process.pid}`;
  rmSync(temporary, { force: true });
  try {
    copyFileSync(source, temporary);
    regularFile(temporary, "staged native library");
    const sourceSha256 = sha256File(source);
    const stagedSha256 = sha256File(temporary);
    if (sourceSha256 !== stagedSha256) {
      throw new Error(
        `staged native library digest mismatch\nsource=${sourceSha256}\nstaged=${stagedSha256}`,
      );
    }
    // renameSync replaces an existing file on Node's supported platforms.
    // Keep the previous candidate present until the verified replacement is
    // installed instead of creating a delete-before-rename gap.
    renameSync(temporary, destination);
    return {
      source,
      destination,
      sha256: stagedSha256,
      staged: true,
    };
  } finally {
    rmSync(temporary, { force: true });
  }
}
