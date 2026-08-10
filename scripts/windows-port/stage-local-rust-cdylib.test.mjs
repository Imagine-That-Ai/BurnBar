import assert from "node:assert/strict";
import { resolve } from "node:path";
import test from "node:test";

import {
  cargoCdylibPath,
  cargoTargetDirectoryFromMetadata,
  nativeLibraryFileName,
  runtimePlatformForTarget,
} from "./stage-local-rust-cdylib.mjs";

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

test("resolves an externally configured cargo target directory", () => {
  const targetDirectory = "/Volumes/DevSSD/BuildCache/cargo-target";
  assert.equal(
    cargoCdylibPath({
      targetDirectory,
      logicalName: "burnbar_remote",
      profile: "debug",
      runtimePlatform: "darwin",
    }),
    resolve(targetDirectory, "debug", "libburnbar_remote.dylib"),
  );
});

test("includes an explicit Windows target triple when cross or native targeting", () => {
  assert.equal(
    cargoCdylibPath({
      targetDirectory: "C:\\repo\\crates\\openburnbar-iroh\\target",
      targetTriple: "aarch64-pc-windows-msvc",
      logicalName: "openburnbar_iroh",
      profile: "release",
    }),
    resolve(
      "C:\\repo\\crates\\openburnbar-iroh\\target",
      "aarch64-pc-windows-msvc",
      "release",
      "openburnbar_iroh.dll",
    ),
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
      cargoCdylibPath({
        targetDirectory: "/tmp/cargo-target",
        logicalName: "burnbar_remote",
        profile: "bench",
        runtimePlatform: "linux",
      }),
    /profile must be debug or release/,
  );
});

test("requires Cargo metadata to declare the exact cdylib target", () => {
  const metadata = {
    target_directory: "/tmp/openburnbar-cargo-target",
    packages: [
      {
        targets: [
          {
            name: "burnbar_remote",
            crate_types: ["staticlib", "cdylib", "rlib"],
          },
        ],
      },
    ],
  };

  assert.equal(
    cargoTargetDirectoryFromMetadata(metadata, "burnbar_remote"),
    resolve(metadata.target_directory),
  );
  assert.throws(
    () => cargoTargetDirectoryFromMetadata(metadata, "openburnbar_iroh"),
    /exactly one cdylib target named openburnbar_iroh; found 0/,
  );
  assert.throws(
    () =>
      cargoTargetDirectoryFromMetadata(
        {
          ...metadata,
          packages: [...metadata.packages, ...metadata.packages],
        },
        "burnbar_remote",
      ),
    /exactly one cdylib target named burnbar_remote; found 2/,
  );
});
