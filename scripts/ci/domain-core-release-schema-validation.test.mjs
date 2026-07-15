import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import test from "node:test";

const require = createRequire(
  new URL("../../apps/console/package.json", import.meta.url),
);
const Ajv2020 = require("ajv/dist/2020").default;

const releaseSchema = JSON.parse(
  readFileSync(
    new URL(
      "../../config/domain-core-release-predicate.schema.json",
      import.meta.url,
    ),
    "utf8",
  ),
);
const deploymentSchema = JSON.parse(
  readFileSync(
    new URL(
      "../../config/domain-core-deployment-receipt.schema.json",
      import.meta.url,
    ),
    "utf8",
  ),
);
const sha = (value) => createHash("sha256").update(value).digest("hex");
const candidate = {
  candidateCommit: "a".repeat(40),
  coreVersion: "1.2.3",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
};

function common() {
  const activation = {
    ...candidate,
    activationCommit: candidate.candidateCommit,
    changedPathsSha256: "3".repeat(64),
  };
  return {
    schemaVersion: 2,
    consumer: "functions",
    domain: "pricing",
    artifactKind: "functions-deployment-receipt",
    target: "firebase-functions-production",
    candidate,
    sourceRun: {
      repository: "Imagine-That-Ai/BurnBar",
      workflowPath: ".github/workflows/domain-core.yml",
      runId: 1,
      runAttempt: 1,
      event: "push",
      ref: "refs/heads/main",
      headSha: candidate.candidateCommit,
    },
    promotionProof: {
      predicateType: "https://slsa.dev/provenance/v1",
      signerWorkflow: ".github/workflows/domain-core-promotion-proof.yml",
      signerRun: { runId: 2, runAttempt: 1 },
      attestationSubject: {
        fileName: "domain-core-candidate-bundle.json",
        sha256: "c".repeat(64),
      },
      attestationBundleSha256: "9".repeat(64),
    },
    rollbackArtifact: {
      fileName: "domain-core-public-production-rollback.json",
      sha256: "d".repeat(64),
      candidate,
      activation,
    },
    activation,
    publicProfile: {
      profile: "public-production",
      domain: "pricing",
      mode: "rust",
      sha256: "4".repeat(64),
    },
    release: {
      version: "1.2.3",
      tag: "v1.2.3",
      commit: candidate.candidateCommit,
      publicProfileSha256: "e".repeat(64),
    },
  };
}

function generatedReceipt() {
  return {
    ...common(),
    deployment: {
      provider: "firebase-functions",
      project: "burnbar",
      environment: "production",
      status: "healthy",
      healthChecks: ["loadedWasm", "relevantRevisions"],
      deployedArtifact: {
        fileName: "domain-core-runtime-artifact-manifest.json",
        sha256: "f".repeat(64),
      },
      providerCoordinates: {
        buildArtifactSha256: "f".repeat(64),
        sharedSource: {
          bucket: "sources",
          object: "source.zip",
          generation: "42",
        },
        targets: [
          {
            target: "insightsHostedAnswer",
            function:
              "projects/burnbar/locations/us-central1/functions/insightsHostedAnswer",
            build: "projects/burnbar/locations/us-central1/builds/1",
            service:
              "projects/burnbar/locations/us-central1/services/insightshostedanswer",
            revision: "insightshostedanswer-00001-abc",
          },
        ],
      },
      deployRun: {
        repository: "Imagine-That-Ai/BurnBar",
        workflowPath: ".github/workflows/deploy-production.yml",
        runId: 3,
        runAttempt: 1,
        event: "push",
        ref: "refs/tags/v1.2.3",
        headSha: candidate.candidateCommit,
        jobSetSha256: "1".repeat(64),
      },
      healthArtifactSha256: "2".repeat(64),
    },
  };
}

function generatedConsoleReceipt() {
  const value = generatedReceipt();
  return {
    ...value,
    consumer: "console",
    domain: "cloudVault",
    artifactKind: "console-deployment-receipt",
    target: "firebase-hosting-production",
    publicProfile: {
      ...value.publicProfile,
      domain: "cloudVault",
    },
    deployment: {
      ...value.deployment,
      provider: "firebase-hosting",
      providerCoordinates: {
        sites: [
          {
            target: "marketing",
            site: "burnbar",
            versionName: "sites/burnbar/versions/version-1",
            releaseName: "sites/burnbar/channels/live/releases/release-1",
          },
          {
            target: "console",
            site: "burnbar-console",
            versionName: "sites/burnbar-console/versions/version-2",
            releaseName:
              "sites/burnbar-console/channels/live/releases/release-2",
          },
        ],
      },
      deployRun: {
        ...value.deployment.deployRun,
        workflowPath: ".github/workflows/deploy-hosting.yml",
      },
    },
  };
}

test("Draft 2020-12 schemas compile and validate generated receipt and predicate shapes", () => {
  const ajv = new Ajv2020({ allErrors: true, strict: true });
  ajv.addSchema(releaseSchema);
  const validateDeployment = ajv.compile(deploymentSchema);
  const validatePredicate = ajv.getSchema(releaseSchema.$id);
  const receipt = generatedReceipt();
  assert.equal(
    validateDeployment(receipt),
    true,
    JSON.stringify(validateDeployment.errors),
  );
  assert.equal(
    validateDeployment(generatedConsoleReceipt()),
    true,
    JSON.stringify(validateDeployment.errors),
  );
  const receiptBytes = Buffer.from(`${JSON.stringify(receipt, null, 2)}\n`);
  const predicate = {
    ...common(),
    predicateType:
      "https://openburnbar.dev/attestations/domain-core-release-artifact/v2",
    artifact: {
      fileName: "OpenBurnBar-1.2.3-functions-deployment.json",
      sha256: sha(receiptBytes),
    },
  };
  assert.equal(
    validatePredicate(predicate),
    true,
    JSON.stringify(validatePredicate.errors),
  );
});

test("compiled schemas reject missing provider coordinates, mixed consumer shape, and unknown fields", () => {
  const ajv = new Ajv2020({ allErrors: true, strict: true });
  ajv.addSchema(releaseSchema);
  const validate = ajv.compile(deploymentSchema);
  const missing = generatedReceipt();
  delete missing.deployment.providerCoordinates;
  assert.equal(validate(missing), false);
  const mixed = generatedReceipt();
  mixed.deployment.providerCoordinates = { sites: [] };
  assert.equal(validate(mixed), false);
  const extra = generatedReceipt();
  extra.deployment.untrusted = true;
  assert.equal(validate(extra), false);
  const duplicateHostingTarget = generatedConsoleReceipt();
  duplicateHostingTarget.deployment.providerCoordinates.sites[1].target =
    "marketing";
  assert.equal(validate(duplicateHostingTarget), false);
});
