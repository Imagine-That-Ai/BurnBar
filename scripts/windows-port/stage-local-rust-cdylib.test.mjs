import assert from "node:assert/strict";
import { resolve } from "node:path";
import test from "node:test";

import {
  cargoBuildArguments,
  cargoCdylibArtifactPathFromMessages,
  cargoCdylibTargetFromMetadata,
  nativeLibraryFileName,
  runtimePlatformForTarget,
} from "./stage-local-rust-cdylib.mjs";

const packageId =
  "path+file:///repo/crates/burnbar-remote#burnbar-remote-ffi@0.1.0";

function artifactMessage(fileName, overrides = {}) {
  return JSON.stringify({
    reason: "compiler-artifact",
    package_id: packageId,
    target: {
      name: "burnbar_remote",
      crate_types: ["staticlib", "cdylib", "rlib"],
    },
    filenames: [fileName],
    ...overrides,
  });
}

test("maps Rust logical names to the platform cdylib file name", () => {
  assert.equal(
    nativeLibraryFileName("burnbar_remote", "win32"),
    "burnbar_remote.dll",
  );
  assert.equal(
    nativeLibraryFileName("openburnbar_iroh", "darwin"),
    "libopenburnbar_iroh.dylib",
  );
  assert.equal(
    nativeLibraryFileName("openburnbar_iroh", "linux"),
    "libopenburnbar_iroh.so",
  );
});

test("builds the exact package with locked dependencies and explicit target/profile", () => {
  assert.deepEqual(
    cargoBuildArguments({
      toolchain: "1.94.0",
      manifestPath: "/repo/crates/burnbar-remote/Cargo.toml",
      packageName: "burnbar-remote-ffi",
      targetTriple: "aarch64-pc-windows-msvc",
      profile: "release",
    }),
    [
      "run",
      "1.94.0",
      "cargo",
      "build",
      "--locked",
      "--manifest-path",
      "/repo/crates/burnbar-remote/Cargo.toml",
      "--package",
      "burnbar-remote-ffi",
      "--target",
      "aarch64-pc-windows-msvc",
      "--release",
      "--message-format=json-render-diagnostics",
    ],
  );
});

test("lets Cargo apply configured target settings when no target is explicit", () => {
  const args = cargoBuildArguments({
    toolchain: "1.96.0",
    manifestPath: "/repo/crates/openburnbar-iroh/Cargo.toml",
    packageName: "openburnbar-iroh",
    profile: "debug",
  });

  assert.equal(args.includes("--target"), false);
  assert.equal(args.includes("--release"), false);
  assert.equal(
    args.at(-1),
    "--message-format=json-render-diagnostics",
  );
});

test("uses Cargo's reported artifact path instead of assuming a target subdirectory", () => {
  const artifact = resolve(
    "configured-cargo-target",
    "custom-target-from-cargo-config",
    "debug",
    nativeLibraryFileName("burnbar_remote"),
  );
  const output = [
    JSON.stringify({
      reason: "build-script-executed",
      package_id: packageId,
    }),
    artifactMessage(artifact),
    JSON.stringify({ reason: "build-finished", success: true }),
  ].join("\n");

  assert.equal(
    cargoCdylibArtifactPathFromMessages(output, {
      packageId,
      logicalName: "burnbar_remote",
      expectedFileName: nativeLibraryFileName("burnbar_remote"),
    }),
    artifact,
  );
});

test("rejects missing, ambiguous, and malformed Cargo artifact output", () => {
  const expectedFileName = nativeLibraryFileName("burnbar_remote");
  const options = {
    packageId,
    logicalName: "burnbar_remote",
    expectedFileName,
  };
  assert.throws(
    () =>
      cargoCdylibArtifactPathFromMessages(
        JSON.stringify({ reason: "build-finished", success: true }),
        options,
      ),
    /exactly one .* artifact .* found 0/,
  );

  const first = resolve("first", expectedFileName);
  const second = resolve("second", expectedFileName);
  assert.throws(
    () =>
      cargoCdylibArtifactPathFromMessages(
        [artifactMessage(first), artifactMessage(second)].join("\n"),
        options,
      ),
    /exactly one .* artifact .* found 2/,
  );
  assert.throws(
    () => cargoCdylibArtifactPathFromMessages("not-json", options),
    /non-JSON line/,
  );
});

test("derives the native extension from an explicit Rust target", () => {
  assert.equal(
    runtimePlatformForTarget("x86_64-pc-windows-msvc", "darwin"),
    "win32",
  );
  assert.equal(
    runtimePlatformForTarget("aarch64-apple-darwin", "linux"),
    "darwin",
  );
  assert.equal(
    runtimePlatformForTarget("x86_64-unknown-linux-gnu", "win32"),
    "linux",
  );
  assert.throws(
    () => runtimePlatformForTarget("wasm32-wasip1", "darwin"),
    /cannot infer native library extension/,
  );
});

test("rejects unsafe logical names and unknown profiles", () => {
  assert.throws(
    () => nativeLibraryFileName("../burnbar_remote", "win32"),
    /logical native library name/,
  );
  assert.throws(
    () =>
      cargoBuildArguments({
        toolchain: "1.94.0",
        manifestPath: "/repo/Cargo.toml",
        packageName: "burnbar-remote-ffi",
        profile: "bench",
      }),
    /profile must be debug or release/,
  );
});

test("requires Cargo metadata to declare the exact cdylib target", () => {
  const metadata = {
    packages: [
      {
        id: packageId,
        name: "burnbar-remote-ffi",
        targets: [
          {
            name: "burnbar_remote",
            crate_types: ["staticlib", "cdylib", "rlib"],
          },
        ],
      },
    ],
  };

  assert.deepEqual(
    cargoCdylibTargetFromMetadata(metadata, "burnbar_remote"),
    {
      packageId,
      packageName: "burnbar-remote-ffi",
      targetName: "burnbar_remote",
    },
  );
  assert.throws(
    () => cargoCdylibTargetFromMetadata(metadata, "openburnbar_iroh"),
    /exactly one cdylib target named openburnbar_iroh; found 0/,
  );
  assert.throws(
    () =>
      cargoCdylibTargetFromMetadata(
        {
          packages: [...metadata.packages, ...metadata.packages],
        },
        "burnbar_remote",
      ),
    /exactly one cdylib target named burnbar_remote; found 2/,
  );
});
