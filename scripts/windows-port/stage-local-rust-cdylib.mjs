#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { platform } from "node:os";
import { basename, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { regularFile } from "../lib/domain-core-release-evidence.mjs";
import { stageNativeLibrary } from "./native-library-staging.mjs";

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

export function cargoCdylibTargetFromMetadata(metadata, logicalName) {
  if (
    metadata === null ||
    typeof metadata !== "object" ||
    !Array.isArray(metadata.packages)
  ) {
    throw new Error("cargo metadata did not return a package list");
  }

  const cdylibTargets = metadata.packages.flatMap((cargoPackage) => {
    if (
      typeof cargoPackage?.id !== "string" ||
      cargoPackage.id.length === 0 ||
      typeof cargoPackage?.name !== "string" ||
      cargoPackage.name.length === 0 ||
      !Array.isArray(cargoPackage?.targets)
    ) {
      return [];
    }
    return cargoPackage.targets
      .filter(
        (target) =>
          Array.isArray(target?.crate_types) &&
          target.crate_types.includes("cdylib") &&
          typeof target.name === "string" &&
          target.name.replaceAll("-", "_") === logicalName,
      )
      .map((target) => ({
        packageId: cargoPackage.id,
        packageName: cargoPackage.name,
        targetName: target.name,
      }));
  });
  if (cdylibTargets.length !== 1) {
    throw new Error(
      `cargo metadata must declare exactly one cdylib target named ${logicalName}; found ${cdylibTargets.length}`,
    );
  }
  return cdylibTargets[0];
}

export function cargoBuildArguments({
  toolchain,
  manifestPath,
  packageName,
  targetTriple,
  profile = "debug",
}) {
  if (typeof toolchain !== "string" || toolchain.length === 0) {
    throw new Error("Rust toolchain must be non-empty");
  }
  if (typeof manifestPath !== "string" || manifestPath.length === 0) {
    throw new Error("Cargo manifest path must be non-empty");
  }
  if (typeof packageName !== "string" || packageName.length === 0) {
    throw new Error("Cargo package name must be non-empty");
  }
  if (!PROFILE.test(profile)) {
    throw new Error("cargo profile must be debug or release");
  }

  return [
    "run",
    toolchain,
    "cargo",
    "build",
    "--locked",
    "--manifest-path",
    manifestPath,
    "--package",
    packageName,
    ...(targetTriple ? ["--target", targetTriple] : []),
    ...(profile === "release" ? ["--release"] : []),
    "--message-format=json-render-diagnostics",
  ];
}

export function cargoCdylibArtifactPathFromMessages(
  output,
  { packageId, logicalName, expectedFileName },
) {
  if (typeof output !== "string") {
    throw new Error("Cargo build output must be text");
  }
  const artifactPaths = new Set();
  for (const rawLine of output.split(/\r?\n/u)) {
    const line = rawLine.trim();
    if (line.length === 0) continue;

    let message;
    try {
      message = JSON.parse(line);
    } catch {
      throw new Error("Cargo build output contained a non-JSON line");
    }
    if (
      message?.reason !== "compiler-artifact" ||
      message.package_id !== packageId ||
      !Array.isArray(message.target?.crate_types) ||
      !message.target.crate_types.includes("cdylib") ||
      typeof message.target?.name !== "string" ||
      message.target.name.replaceAll("-", "_") !== logicalName ||
      !Array.isArray(message.filenames)
    ) {
      continue;
    }
    for (const fileName of message.filenames) {
      if (
        typeof fileName === "string" &&
        basename(fileName) === expectedFileName
      ) {
        artifactPaths.add(resolve(fileName));
      }
    }
  }
  if (artifactPaths.size !== 1) {
    throw new Error(
      `Cargo build must report exactly one ${expectedFileName} artifact for ${logicalName}; found ${artifactPaths.size}`,
    );
  }
  return [...artifactPaths][0];
}

function cargoMetadata(manifestPath, toolchain) {
  return JSON.parse(
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
      { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 },
    ),
  );
}

function buildCdylibArtifact(options) {
  const target = cargoCdylibTargetFromMetadata(
    cargoMetadata(options.manifestPath, options.toolchain),
    options.logicalName,
  );
  const expectedFileName = nativeLibraryFileName(
    options.logicalName,
    runtimePlatformForTarget(options.targetTriple),
  );
  const output = execFileSync(
    "rustup",
    cargoBuildArguments({
      toolchain: options.toolchain,
      manifestPath: options.manifestPath,
      packageName: target.packageName,
      targetTriple: options.targetTriple,
      profile: options.profile,
    }),
    { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
  );
  const source = cargoCdylibArtifactPathFromMessages(output, {
    packageId: target.packageId,
    logicalName: options.logicalName,
    expectedFileName,
  });
  regularFile(source, "Cargo-reported native library");
  return { source, target };
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
  const { source, target } = buildCdylibArtifact(options);
  const result = stageNativeLibrary(source, options.destination);
  process.stdout.write(
    `${JSON.stringify({
      ok: true,
      logicalName: options.logicalName,
      toolchain: options.toolchain,
      packageName: target.packageName,
      targetName: target.targetName,
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
