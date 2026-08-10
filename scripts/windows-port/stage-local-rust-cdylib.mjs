#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { platform } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { regularFile } from "../lib/domain-core-release-evidence.mjs";
import { stageNativeLibrary } from "./stage-local-domain-core-native.mjs";

const LOGICAL_NAME = /^[A-Za-z][A-Za-z0-9_]*$/u;
const PROFILE = /^(?:debug|release)$/u;
const USAGE =
  "usage: --manifest-path PATH --toolchain VERSION --logical-name NAME --destination PATH [--target TRIPLE] [--profile debug|release]";

export function nativeLibraryFileName(
  logicalName,
  runtimePlatform = platform(),
) {
  if (typeof logicalName !== "string" || !LOGICAL_NAME.test(logicalName)) {
    throw new Error(
      "logical native library name must start with a letter and contain only letters, numbers, or underscores",
    );
  }
  if (runtimePlatform === "win32") return `${logicalName}.dll`;
  if (runtimePlatform === "darwin") return `lib${logicalName}.dylib`;
  return `lib${logicalName}.so`;
}

export function runtimePlatformForTarget(
  targetTriple,
  hostPlatform = platform(),
) {
  if (targetTriple === undefined) return hostPlatform;
  if (typeof targetTriple !== "string" || targetTriple.trim().length === 0) {
    throw new Error("Rust target triple must be non-empty when supplied");
  }
  if (targetTriple.includes("windows")) return "win32";
  if (targetTriple.includes("darwin")) return "darwin";
  if (targetTriple.includes("linux")) return "linux";
  throw new Error(
    `cannot infer native library extension from Rust target triple: ${targetTriple}`,
  );
}

export function cargoCdylibPath({
  targetDirectory,
  logicalName,
  targetTriple,
  profile = "debug",
  runtimePlatform,
}) {
  if (typeof targetDirectory !== "string" || targetDirectory.length === 0) {
    throw new Error("cargo target directory must be non-empty");
  }
  if (!PROFILE.test(profile)) {
    throw new Error("cargo profile must be debug or release");
  }
  const libraryPlatform =
    runtimePlatform ?? runtimePlatformForTarget(targetTriple);

  return resolve(
    targetDirectory,
    ...(targetTriple ? [targetTriple] : []),
    profile,
    nativeLibraryFileName(logicalName, libraryPlatform),
  );
}

export function cargoTargetDirectoryFromMetadata(metadata, logicalName) {
  if (
    metadata === null ||
    typeof metadata !== "object" ||
    !Array.isArray(metadata.packages)
  ) {
    throw new Error("cargo metadata did not return a package list");
  }

  const cdylibTargets = metadata.packages.flatMap((cargoPackage) =>
    Array.isArray(cargoPackage?.targets)
      ? cargoPackage.targets.filter(
          (target) =>
            Array.isArray(target?.crate_types) &&
            target.crate_types.includes("cdylib") &&
            typeof target.name === "string" &&
            target.name.replaceAll("-", "_") === logicalName,
        )
      : [],
  );
  if (cdylibTargets.length !== 1) {
    throw new Error(
      `cargo metadata must declare exactly one cdylib target named ${logicalName}; found ${cdylibTargets.length}`,
    );
  }
  if (
    typeof metadata.target_directory !== "string" ||
    metadata.target_directory.length === 0
  ) {
    throw new Error("cargo metadata did not return target_directory");
  }
  return resolve(metadata.target_directory);
}

function cargoTargetDirectory(manifestPath, toolchain, logicalName) {
  const metadata = JSON.parse(
    execFileSync(
      "rustup",
      [
        "run",
        toolchain,
        "cargo",
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
  return cargoTargetDirectoryFromMetadata(metadata, logicalName);
}

function parseArguments(argv) {
  if (argv.length < 8 || argv.length > 12 || argv.length % 2 !== 0) {
    throw new Error(USAGE);
  }

  const allowed = new Set([
    "--manifest-path",
    "--toolchain",
    "--logical-name",
    "--destination",
    "--target",
    "--profile",
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    if (!allowed.has(flag) || values.has(flag)) {
      throw new Error(USAGE);
    }
    values.set(flag, argv[index + 1]);
  }

  for (const required of [
    "--manifest-path",
    "--toolchain",
    "--logical-name",
    "--destination",
  ]) {
    if (!values.has(required) || values.get(required).length === 0) {
      throw new Error(USAGE);
    }
  }

  const profile = values.get("--profile") ?? "debug";
  if (!PROFILE.test(profile)) {
    throw new Error("cargo profile must be debug or release");
  }

  return {
    manifestPath: resolve(values.get("--manifest-path")),
    toolchain: values.get("--toolchain"),
    logicalName: values.get("--logical-name"),
    destination: values.get("--destination"),
    targetTriple: values.get("--target"),
    profile,
  };
}

export function run(argv) {
  const options = parseArguments(argv);
  regularFile(options.manifestPath, "Cargo manifest");
  const source = cargoCdylibPath({
    targetDirectory: cargoTargetDirectory(
      options.manifestPath,
      options.toolchain,
      options.logicalName,
    ),
    logicalName: options.logicalName,
    targetTriple: options.targetTriple,
    profile: options.profile,
  });
  const result = stageNativeLibrary(source, options.destination);
  process.stdout.write(
    `${JSON.stringify({
      ok: true,
      logicalName: options.logicalName,
      toolchain: options.toolchain,
      targetTriple: options.targetTriple ?? null,
      profile: options.profile,
      ...result,
    })}\n`,
  );
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
