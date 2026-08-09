#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import {
  copyFileSync,
  mkdirSync,
  renameSync,
  rmSync,
} from "node:fs";
import { platform } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  regularFile,
  sha256File,
} from "../lib/domain-core-release-evidence.mjs";

function nativeFileName(runtimePlatform) {
  if (runtimePlatform === "win32") return "openburnbar_domain_ffi.dll";
  if (runtimePlatform === "darwin") return "libopenburnbar_domain_ffi.dylib";
  return "libopenburnbar_domain_ffi.so";
}

export function stageNativeLibrary(sourcePath, destinationPath) {
  const source = regularFile(sourcePath, "built local domain-core library");
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
    regularFile(temporary, "staged local domain-core library");
    const sourceSha256 = sha256File(source);
    const stagedSha256 = sha256File(temporary);
    if (sourceSha256 !== stagedSha256) {
      throw new Error(
        `staged local domain-core digest mismatch\nsource=${sourceSha256}\nstaged=${stagedSha256}`,
      );
    }
    rmSync(destination, { force: true });
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

function readCargoTargetDirectory(manifestPath) {
  const metadata = JSON.parse(
    execFileSync(
      "cargo",
      [
        "metadata",
        "--locked",
        "--manifest-path",
        manifestPath,
        "--format-version",
        "1",
        "--no-deps",
      ],
      { encoding: "utf8" },
    ),
  );
  if (
    typeof metadata.target_directory !== "string" ||
    metadata.target_directory.length === 0
  ) {
    throw new Error("cargo metadata did not return target_directory");
  }
  return resolve(metadata.target_directory);
}

export function run(argv) {
  if (
    argv.length !== 4 ||
    argv[0] !== "--manifest-path" ||
    argv[2] !== "--destination"
  ) {
    throw new Error("usage: --manifest-path PATH --destination PATH");
  }
  const manifestPath = resolve(argv[1]);
  regularFile(manifestPath, "domain-core Cargo manifest");
  const source = join(
    readCargoTargetDirectory(manifestPath),
    "debug",
    nativeFileName(platform()),
  );
  const result = stageNativeLibrary(source, argv[3]);
  process.stdout.write(`${JSON.stringify({ ok: true, ...result })}\n`);
  return result;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
