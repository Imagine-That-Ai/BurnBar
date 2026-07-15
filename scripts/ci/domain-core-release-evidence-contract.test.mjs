import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

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
      "activation",
      "sourceRun",
      "promotionProof",
      "rollbackArtifact",
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
  assert.ok(schema.$defs.rollbackArtifact.required.includes("activation"));
  assert.ok(schema.$defs.rollbackArtifact.required.includes("sha256"));
  assert.equal(schema.oneOf.length, 7);
});

test("deployment receipt v2 carries the same proof chain and deployed bytes", () => {
  const schema = json("config/domain-core-deployment-receipt.schema.json");
  assert.equal(schema.properties.schemaVersion.const, 2);
  for (const field of [
    "candidate",
    "activation",
    "sourceRun",
    "promotionProof",
    "rollbackArtifact",
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
    "domain-core-release-predicate.schema.json#/$defs/artifact",
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
    "--release-commit",
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
