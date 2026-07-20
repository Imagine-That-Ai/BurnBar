import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";

import {
  buildAndroidUniversalManifest,
  run,
  validateAndroidUniversalManifest,
} from "./verify-domain-core-android-universal-artifact.mjs";

const LIBRARY = "libopenburnbar_domain_ffi.so";
const AAB_PATHS = [
  `base/lib/arm64-v8a/${LIBRARY}`,
  `base/lib/x86_64/${LIBRARY}`,
];
const AAR_PATHS = [`jni/arm64-v8a/${LIBRARY}`, `jni/x86_64/${LIBRARY}`];
const AAR_SHA = "a".repeat(64);

function bytes() {
  return new Map([
    [AAB_PATHS[0], Buffer.from("arm64 candidate bytes")],
    [AAB_PATHS[1], Buffer.from("x86_64 candidate bytes")],
    [AAR_PATHS[0], Buffer.from("arm64 candidate bytes")],
    [AAR_PATHS[1], Buffer.from("x86_64 candidate bytes")],
  ]);
}

function build(overrides = {}) {
  const values = overrides.values ?? bytes();
  return buildAndroidUniversalManifest({
    aabEntries: overrides.aabEntries ?? AAB_PATHS,
    aarEntries: overrides.aarEntries ?? AAR_PATHS,
    readAabEntry: (path) => values.get(path),
    readAarEntry: (path) => values.get(path),
    aarSha256: overrides.aarSha256 ?? AAR_SHA,
    protectedAarSha256: overrides.protectedAarSha256 ?? AAR_SHA,
  });
}

test("manifest is deterministic and binds every shipped ABI", () => {
  const first = build({
    aabEntries: [...AAB_PATHS].reverse(),
    aarEntries: [...AAR_PATHS].reverse(),
  });
  const second = build();
  assert.deepEqual(first, second);
  assert.deepEqual(
    first.abis.map(({ abi, path }) => ({ abi, path })),
    [
      { abi: "arm64-v8a", path: AAB_PATHS[0] },
      { abi: "x86_64", path: AAB_PATHS[1] },
    ],
  );
  assert.deepEqual(validateAndroidUniversalManifest(first), first);
});

test("tampered non-executed x86_64 ABI fails byte identity", () => {
  const values = bytes();
  values.set(AAB_PATHS[1], Buffer.from("tampered x86_64 bytes"));
  assert.throws(() => build({ values }), /x86_64.*differs/u);
});

test("missing, extra, duplicate, and unsafe AAB ABI paths fail closed", () => {
  assert.throws(
    () => build({ aabEntries: [AAB_PATHS[0]] }),
    /missing required.*x86_64/u,
  );
  assert.throws(
    () =>
      build({
        aabEntries: [...AAB_PATHS, `base/lib/x86/${LIBRARY}`],
      }),
    /unexpected.*x86/u,
  );
  assert.throws(
    () => build({ aabEntries: [...AAB_PATHS, AAB_PATHS[1]] }),
    /duplicates/u,
  );
  assert.throws(
    () =>
      build({
        aabEntries: [AAB_PATHS[0], `base/lib/x86_64/../x86_64/${LIBRARY}`],
      }),
    /unsafe/u,
  );
});

test("candidate AAR provenance digest and corresponding ABI paths fail closed", () => {
  assert.throws(
    () => build({ protectedAarSha256: "b".repeat(64) }),
    /does not match protected kotlin-aar/u,
  );
  assert.throws(
    () => build({ aarEntries: [AAR_PATHS[0]] }),
    /missing required ABI path.*x86_64/u,
  );
  assert.throws(
    () => build({ aarEntries: [...AAR_PATHS, AAR_PATHS[1]] }),
    /duplicates/u,
  );
});

function writeTree(root, entries) {
  for (const [path, value] of entries) {
    const destination = join(root, path);
    mkdirSync(dirname(destination), { recursive: true });
    writeFileSync(destination, value);
  }
}

function zipTree(root, output) {
  const result = spawnSync("zip", ["-q", "-r", output, "."], {
    cwd: root,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
}

test("CLI extracts signed archive bytes and writes a stable manifest", () => {
  const directory = mkdtempSync(join(tmpdir(), "android-universal-proof-"));
  try {
    const aabRoot = join(directory, "aab");
    const aarRoot = join(directory, "aar");
    const vendor = join(directory, "Vendor");
    const aab = join(directory, "release.aab");
    const aar = join(vendor, "openburnbar-domain-core.aar");
    const candidate = join(directory, "domain-core-candidate-bundle.json");
    const output = join(directory, "android-universal.json");
    mkdirSync(vendor, { recursive: true });
    const content = bytes();
    writeTree(
      aabRoot,
      AAB_PATHS.map((path) => [path, content.get(path)]),
    );
    writeTree(
      aarRoot,
      AAR_PATHS.map((path) => [path, content.get(path)]),
    );
    zipTree(aabRoot, aab);
    zipTree(aarRoot, aar);
    const aarSha256 = createHash("sha256")
      .update(readFileSync(aar))
      .digest("hex");
    writeFileSync(
      candidate,
      `${JSON.stringify({
        artifacts: [
          {
            id: "kotlin-aar",
            consumer: "kotlin",
            jobId: "android",
            artifactSha256: aarSha256,
          },
        ],
      })}\n`,
    );
    run([
      "--aab",
      aab,
      "--candidate-aar",
      aar,
      "--candidate-bundle",
      candidate,
      "--output",
      output,
    ]);
    const manifest = JSON.parse(readFileSync(output, "utf8"));
    assert.equal(manifest.candidateAar.sha256, aarSha256);
    assert.deepEqual(
      manifest.abis.map((entry) => entry.abi),
      ["arm64-v8a", "x86_64"],
    );
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
