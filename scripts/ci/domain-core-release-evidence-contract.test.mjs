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
  assert.ok(schema.$defs.rollbackArtifact.required.includes("sha256"));
  assert.equal(schema.oneOf.length, 5);
});

test("deployment receipt v2 carries the same proof chain and deployed bytes", () => {
  const schema = json("config/domain-core-deployment-receipt.schema.json");
  assert.equal(schema.properties.schemaVersion.const, 2);
  for (const field of [
    "candidate",
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
    "domain-core-release-predicate-v2.json#/$defs/artifact",
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

test("deployment receipt refs resolve to the v2 predicate schema, not the unversioned URL", () => {
  const schema = json("config/domain-core-deployment-receipt.schema.json");
  const predicateSchema = json(
    "config/domain-core-release-predicate.schema.json",
  );
  const expectedBase = predicateSchema.$id.replace(
    /^https:\/\/openburnbar\.dev\/schemas\//u,
    "",
  );
  const refPaths = [];
  function collectRefs(node) {
    if (node === null || typeof node !== "object") return;
    for (const [key, value] of Object.entries(node)) {
      if (key === "$ref" && typeof value === "string") refPaths.push(value);
      else if (typeof value === "object") collectRefs(value);
    }
  }
  collectRefs(schema);
  assert.ok(refPaths.length > 0, "schema should contain at least one $ref");
  for (const ref of refPaths) {
    assert.ok(
      ref.startsWith(`${expectedBase}#/`),
      `ref ${ref} must resolve to the v2 predicate schema ${expectedBase}`,
    );
    assert.ok(
      !ref.startsWith("domain-core-release-predicate.schema.json"),
      `ref ${ref} must not point at the unversioned predicate URL`,
    );
  }
});

test("deployment receipt oneOf ties each deploy workflow to its specific deployment consumer", () => {
  const schema = json("config/domain-core-deployment-receipt.schema.json");
  const branches = schema.oneOf;
  assert.equal(branches.length, 2);
  for (const branch of branches) {
    const consumer = branch.properties.consumer.const;
    const expectedWorkflow =
      consumer === "console"
        ? ".github/workflows/deploy-hosting.yml"
        : ".github/workflows/deploy-production.yml";
    const actualWorkflow =
      branch.properties.deployment.properties.deployRun.properties.workflowPath
        .const;
    assert.equal(
      actualWorkflow,
      expectedWorkflow,
      `${consumer} receipt must pin ${expectedWorkflow}`,
    );
  }
  // A console receipt with the functions deploy workflow must not match any oneOf branch.
  const consoleBranch = branches.find(
    (b) => b.properties.consumer.const === "console",
  );
  const functionsWorkflow =
    ".github/workflows/deploy-production.yml";
  assert.notEqual(
    consoleBranch.properties.deployment.properties.deployRun.properties
      .workflowPath.const,
    functionsWorkflow,
    "console branch must not accept the functions deploy workflow",
  );
  // A functions receipt with the console deploy workflow must not match any oneOf branch.
  const functionsBranch = branches.find(
    (b) => b.properties.consumer.const === "functions",
  );
  const consoleWorkflow = ".github/workflows/deploy-hosting.yml";
  assert.notEqual(
    functionsBranch.properties.deployment.properties.deployRun.properties
      .workflowPath.const,
    consoleWorkflow,
    "functions branch must not accept the console deploy workflow",
  );
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
