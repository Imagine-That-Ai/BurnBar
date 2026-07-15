import assert from "node:assert/strict";
import {
  mkdtempSync,
  mkdirSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import test from "node:test";

import { createRuntimeArtifactManifest } from "./create-domain-core-runtime-artifact-manifest.mjs";

const candidate = {
  candidateCommit: "a".repeat(40),
  coreVersion: "1.2.3",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
};

function fixture(consumer) {
  const root = mkdtempSync(join(tmpdir(), `domain-core-${consumer}-manifest-`));
  const profile = join(root, "profile.json");
  writeFileSync(
    profile,
    JSON.stringify({ name: "public-production", candidateIdentity: candidate }),
  );
  if (consumer === "console") {
    mkdirSync(join(root, "_next/static/media"), { recursive: true });
    mkdirSync(join(root, "_next/static/chunks"), { recursive: true });
    writeFileSync(join(root, "domain-core-build-profile.json"), "{}\n");
    writeFileSync(join(root, "domain-core-deployment-identity.json"), "{}\n");
    writeFileSync(join(root, "_next/static/media/core.wasm"), "wasm");
    writeFileSync(
      join(root, "_next/static/chunks/core.js"),
      'fetch("core.wasm");domainCoreSourceFingerprint();',
    );
  } else {
    for (const path of ["lib/generated", "vendor/openburnbar/domain-core-wasm"])
      mkdirSync(join(root, path), { recursive: true });
    for (const path of [
      "lib/domainCoreBuildProfile.js",
      "lib/health.js",
      "lib/index.js",
      "lib/domainCorePricing.js",
      "lib/generated/domainCoreCandidateReceipt.js",
      "vendor/openburnbar/domain-core-wasm/openburnbar-domain-core-source.sha256",
      "vendor/openburnbar/domain-core-wasm/openburnbar_domain_core.js",
      "vendor/openburnbar/domain-core-wasm/openburnbar_domain_core_bg.wasm",
      "vendor/openburnbar/domain-core-wasm/package.json",
      "package.json",
      "package-lock.json",
    ])
      writeFileSync(join(root, path), path);
  }
  return { root, profile };
}

for (const consumer of ["console", "functions"]) {
  test(`creates deterministic ${consumer} runtime manifest bound to candidate and exact files`, () => {
    const { root, profile } = fixture(consumer);
    const first = createRuntimeArtifactManifest({
      consumer,
      root,
      profileReceipt: profile,
    });
    const second = createRuntimeArtifactManifest({
      consumer,
      root,
      profileReceipt: profile,
    });
    assert.deepEqual(first, second);
    assert.deepEqual(first.candidate, candidate);
    assert.ok(first.files.length >= (consumer === "console" ? 4 : 11));
    assert.ok(
      first.files.every(
        (file) => /^[0-9a-f]{64}$/u.test(file.sha256) && file.size > 0,
      ),
    );
  });
}

test("rejects missing loader, duplicate WASM, and symlink substitutions", () => {
  const { root, profile } = fixture("console");
  writeFileSync(join(root, "_next/static/chunks/core.js"), "unrelated");
  assert.throws(
    () =>
      createRuntimeArtifactManifest({
        consumer: "console",
        root,
        profileReceipt: profile,
      }),
    /no JavaScript loader/u,
  );
  writeFileSync(
    join(root, "_next/static/chunks/core.js"),
    "domainCoreSourceFingerprint()",
  );
  writeFileSync(join(root, "_next/static/media/second.wasm"), "wasm2");
  assert.throws(
    () =>
      createRuntimeArtifactManifest({
        consumer: "console",
        root,
        profileReceipt: profile,
      }),
    /exactly one WASM/u,
  );
  const functions = fixture("functions");
  const target = join(functions.root, "lib/domainCorePricing.js");
  writeFileSync(join(functions.root, "outside"), "bad");
  // Replacing a required file with a symlink must fail even when the bytes match.
  unlinkSync(target);
  symlinkSync(join(functions.root, "outside"), target);
  assert.throws(
    () =>
      createRuntimeArtifactManifest({
        consumer: "functions",
        root: functions.root,
        profileReceipt: functions.profile,
      }),
    /regular non-symlink/u,
  );
});
