import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  NATIVE_RELEASE_VERSION,
  STABLE_RELEASE_VERSION,
  validateReleaseCoordinates,
} from "../lib/domain-core-release-evidence.mjs";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

function json(path) {
  return JSON.parse(readFileSync(join(REPO_ROOT, path), "utf8"));
}

test("release predicate v2 requires the complete deterministic trust chain", () => {
  const schema = json("config/domain-core-release-predicate.schema.json");
  assert.equal(schema.properties.schemaVersion.const, 2);
  assert.equal(
    schema.properties.predicateType.const,
    "https://openburnbar.dev/attestations/domain-core-release-artifact/v2",
  );
  assert.deepEqual(
    new Set(schema.required),
    new Set([
      "schemaVersion",
      "predicateType",
      "consumer",
      "domain",
      "artifactKind",
      "target",
      "candidate",
      "sourceRun",
      "promotionProof",
      "rollbackArtifact",
      "activation",
      "publicProfile",
      "artifact",
      "release",
    ]),
  );
  assert.deepEqual(
    new Set(schema.$defs.candidate.required),
    new Set(["candidateCommit", "coreVersion", "abiVersion", "sourceSha256"]),
  );
  assert.equal(
    schema.$defs.promotionProof.properties.signerWorkflow.const,
    ".github/workflows/domain-core-promotion-proof.yml",
  );
  assert.equal(schema.$defs.sourceRun.properties.event.const, "push");
  assert.equal(schema.$defs.sourceRun.properties.ref.const, "refs/heads/main");
  assert.ok(schema.$defs.rollbackArtifact.required.includes("candidate"));
  assert.ok(schema.$defs.rollbackArtifact.required.includes("sha256"));
  assert.equal(schema.oneOf.length, 5);
  assert.deepEqual(schema.$defs.publicProfile.required, [
    "profile",
    "domain",
    "mode",
    "sha256",
  ]);
  assert.equal(schema.$defs.publicProfile.properties.mode.const, "rust");
  assert.deepEqual(schema.$defs.activation.required, [
    "candidateCommit",
    "activationCommit",
    "coreVersion",
    "abiVersion",
    "sourceSha256",
    "changedPathsSha256",
  ]);
  const android = schema.oneOf.find(
    (entry) => entry.properties.consumer.const === "android",
  );
  assert.ok(android.required.includes("androidUniversal"));
  assert.deepEqual(
    schema.$defs.androidUniversal.properties.abis.prefixItems.map(
      (entry) => entry.properties.abi.const,
    ),
    ["arm64-v8a", "x86_64"],
  );
});

test("schema and runtime share consumer-specific release version vectors", () => {
  const schema = json("config/domain-core-release-predicate.schema.json");
  const nativeSchema = new RegExp(schema.$defs.nativeVersion.pattern, "u");
  const stableSchema = new RegExp(schema.$defs.stableVersion.pattern, "u");
  const nativeTagSchema = new RegExp(schema.$defs.nativeTag.pattern, "u");
  const stableTagSchema = new RegExp(schema.$defs.stableTag.pattern, "u");
  const contracts = {
    apple: ["quota", "macos-dmg", "macos-arm64"],
    android: ["cloudVault", "android-aab", "android-universal"],
    windows: ["quota", "windows-release-bundle", "windows-x64-arm64"],
    console: [
      "cloudVault",
      "console-deployment-receipt",
      "firebase-hosting-production",
    ],
    functions: [
      "pricing",
      "functions-deployment-receipt",
      "firebase-functions-production",
    ],
  };
  const vectors = [
    ["1.2.3", true],
    ["1.2.3+linux-x64", true],
    ["1.2.3-rc.1", "native-only"],
    ["1.2.3-rc.1+build-7", "native-only"],
    ["01.2.3", false],
  ];
  const candidate = {
    candidateCommit: "a".repeat(40),
    coreVersion: "0.3.0",
    abiVersion: 3,
    sourceSha256: "b".repeat(64),
  };
  const activation = {
    ...candidate,
    activationCommit: "c".repeat(40),
    changedPathsSha256: "d".repeat(64),
  };
  for (const [consumer, [domain, artifactKind, target]] of Object.entries(
    contracts,
  )) {
    const native = new Set(["apple", "android"]).has(consumer);
    for (const [version, policy] of vectors) {
      const accepted = policy === true || (policy === "native-only" && native);
      const runtimePattern = native
        ? NATIVE_RELEASE_VERSION
        : STABLE_RELEASE_VERSION;
      const schemaPattern = native ? nativeSchema : stableSchema;
      const tag =
        consumer === "windows" ? `windows-v${version}` : `v${version}`;
      const tagPattern = native ? nativeTagSchema : stableTagSchema;
      assert.equal(
        runtimePattern.test(version),
        accepted,
        `${consumer} ${version}`,
      );
      assert.equal(
        schemaPattern.test(version),
        accepted,
        `${consumer} schema ${version}`,
      );
      assert.equal(
        tagPattern.test(tag),
        accepted,
        `${consumer} tag ${version}`,
      );
      const call = () =>
        validateReleaseCoordinates({
          consumer,
          domain,
          artifactKind,
          target,
          version,
          tag,
          commit: activation.activationCommit,
          candidate,
          activation,
        });
      if (accepted) assert.doesNotThrow(call);
      else assert.throws(call);
    }
  }
});

test("deployment receipt v2 carries the same proof chain and deployed bytes", () => {
  const schema = json("config/domain-core-deployment-receipt.schema.json");
  assert.equal(schema.properties.schemaVersion.const, 2);
  for (const field of [
    "candidate",
    "sourceRun",
    "promotionProof",
    "rollbackArtifact",
    "activation",
    "publicProfile",
    "release",
    "deployment",
  ]) {
    assert.ok(schema.required.includes(field));
  }
  for (const field of [
    "deployedArtifact",
    "deployRun",
    "healthArtifactSha256",
  ]) {
    assert.ok(schema.properties.deployment.required.includes(field));
  }
  assert.equal(
    schema.properties.deployment.properties.deployedArtifact.$ref,
    "https://openburnbar.dev/schemas/domain-core-release-predicate-v2.json#/$defs/artifact",
  );
  assert.deepEqual(
    new Set(schema.properties.deployment.properties.deployRun.required),
    new Set([
      "repository",
      "workflowPath",
      "runId",
      "runAttempt",
      "event",
      "ref",
      "headSha",
      "jobSetSha256",
    ]),
  );
  assert.equal(
    schema.properties.deployment.properties.deployRun.properties.repository
      .const,
    "Imagine-That-Ai/BurnBar",
  );
  assert.equal(schema.oneOf.length, 2);
});

test("pre-release gate verifies immutable candidate source signer and rollback identities", () => {
  const library = readFileSync(
    join(REPO_ROOT, "scripts/lib/domain-core-release-evidence.mjs"),
    "utf8",
  );
  const command = readFileSync(
    join(REPO_ROOT, "scripts/ci/verify-domain-core-release-gate.mjs"),
    "utf8",
  );
  assert.match(
    library,
    /certificate\?\.runInvocationURI === expectedRunInvocation/u,
  );
  for (const flag of [
    "--candidate-commit",
    "--core-version",
    "--abi-version",
    "--source-sha256",
    "--source-run-id",
    "--source-run-attempt",
    "--protected-signer-run-id",
    "--protected-signer-run-attempt",
    "--rollback-sha256",
  ]) {
    assert.match(command, new RegExp(flag, "u"));
  }
});

test("release substrate contains no telemetry promotion authority", () => {
  const paths = [
    "config/domain-core-release-predicate.schema.json",
    "config/domain-core-deployment-receipt.schema.json",
    "scripts/lib/domain-core-release-evidence.mjs",
    "scripts/ci/create-domain-core-release-evidence.mjs",
    "scripts/ci/publish-domain-core-release-evidence.mjs",
    "scripts/ci/verify-domain-core-release-gate.mjs",
  ];
  const source = paths
    .map((path) => readFileSync(join(REPO_ROOT, path), "utf8"))
    .join("\n");
  assert.doesNotMatch(
    source,
    /10,?000|14[- ]day|minimumSamples|telemetry report/iu,
  );
});
