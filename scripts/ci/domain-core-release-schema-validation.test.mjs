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
const rollbackReceiptSchema = JSON.parse(
  readFileSync(
    new URL(
      "../../config/domain-core-legacy-deletion-receipt.schema.json",
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

test("release predicate accepts only the governed production/profile mode pairs", () => {
  const ajv = new Ajv2020({ allErrors: true, strict: true });
  const validate = ajv.compile(releaseSchema);
  const base = common();
  const rollback = {
    ...base,
    predicateType:
      "https://openburnbar.dev/attestations/domain-core-release-artifact/v2",
    publicProfile: {
      ...base.publicProfile,
      profile: "public-production-rollback",
      mode: "legacy",
    },
    artifact: {
      fileName: "OpenBurnBar-1.2.3-functions-deployment.json",
      sha256: "f".repeat(64),
    },
  };
  assert.equal(validate(rollback), true, JSON.stringify(validate.errors));

  for (const [profile, mode] of [
    ["public-production", "legacy"],
    ["public-production-rollback", "rust"],
    ["unprotected-rollback", "legacy"],
  ]) {
    const substituted = structuredClone(rollback);
    substituted.publicProfile.profile = profile;
    substituted.publicProfile.mode = mode;
    assert.equal(
      validate(substituted),
      false,
      `schema accepted unauthorized profile/mode pair ${profile}/${mode}`,
    );
  }
});

test("rollback receipt schema requires exact completion paths and signed health fields", () => {
  const ajv = new Ajv2020({
    allErrors: true,
    strict: true,
    strictRequired: false,
    formats: { "date-time": true },
  });
  const validate = ajv.compile(rollbackReceiptSchema);
  const activation = {
    ...candidate,
    activationCommit: "3".repeat(40),
    changedPathsSha256: "4".repeat(64),
  };
  const sourceRun = {
    repository: "Imagine-That-Ai/BurnBar",
    workflowPath: ".github/workflows/domain-core.yml",
    runId: 11,
    runAttempt: 2,
    event: "push",
    ref: "refs/heads/main",
    headSha: candidate.candidateCommit,
  };
  const receipt = {
    schemaVersion: 2,
    rowId: "quota.claude_statusline",
    authorityGeneration: 1,
    transition: "rollback",
    status: "active",
    evidence: ["https://github.com/Imagine-That-Ai/BurnBar/issues/123"],
    approvedBy: "@release-owner",
    approvedAt: "2026-07-17T00:00:00Z",
    commit: "5".repeat(40),
    rollback: {
      stableReceiptSha256: "6".repeat(64),
      issueUri: "https://github.com/Imagine-That-Ai/BurnBar/issues/123",
      activatedAt: "2026-07-17T00:00:00Z",
      candidate,
      activation,
      authority: {
        candidateBundleSha256: "7".repeat(64),
        sourceRun,
        promotionSigner: {
          workflowPath: ".github/workflows/domain-core-promotion-proof.yml",
          runId: 21,
          runAttempt: 3,
          trustedMainCommit: "8".repeat(40),
          provenanceSha256: "9".repeat(64),
        },
      },
      retainedRollbackArtifact: {
        artifactUri:
          "https://github.com/Imagine-That-Ai/BurnBar/releases/download/v1.2.3/OpenBurnBar-1.2.3-legacy-rollback.zip",
        artifactSha256: "a".repeat(64),
        provenanceSha256: "b".repeat(64),
        retentionPolicy: "retain_until_legacy_deletion_complete",
      },
      approverAuthority: {
        reviewClass: "domain_owner",
        catalogSha256: "c".repeat(64),
        trustedMainCommit: "8".repeat(40),
      },
      completionEvidence: [
        {
          consumer: "apple",
          domain: "quota",
          artifactPath:
            "config/domain-core-rollback-completions/quota.claude_statusline/1/apple.json",
          artifactSha256: "d".repeat(64),
          provenancePath:
            "config/domain-core-rollback-completions/quota.claude_statusline/1/apple.sigstore.json",
          provenanceSha256: "e".repeat(64),
          rollbackProfileSha256: "f".repeat(64),
          release: {
            version: "1.2.3",
            tag: "v1.2.3",
            commit: activation.activationCommit,
          },
          signer: {
            workflowPath: ".github/workflows/release.yml",
            runId: 31,
            runAttempt: 2,
            runInvocationUri:
              "https://github.com/Imagine-That-Ai/BurnBar/actions/runs/31/attempts/2",
          },
          actionRun: {
            repository: "Imagine-That-Ai/BurnBar",
            workflowPath: ".github/workflows/release.yml",
            runId: 31,
            runAttempt: 2,
            event: "workflow_dispatch",
            ref: "refs/tags/v1.2.3",
            headSha: activation.activationCommit,
          },
          deployedArtifactSha256: "d".repeat(64),
          healthArtifactSha256: null,
          completedAt: "2026-07-17T00:00:00Z",
        },
      ],
    },
  };
  assert.equal(validate(receipt), true, JSON.stringify(validate.errors));

  const wrongPath = structuredClone(receipt);
  wrongPath.rollback.completionEvidence[0].artifactPath =
    "artifacts/quota.claude_statusline/1/apple.json";
  assert.equal(validate(wrongPath), false);
  const missingHealthBinding = structuredClone(receipt);
  delete missingHealthBinding.rollback.completionEvidence[0]
    .healthArtifactSha256;
  assert.equal(validate(missingHealthBinding), false);
  const extraAuthority = structuredClone(receipt);
  extraAuthority.rollback.authority.selfAuthorized = true;
  assert.equal(validate(extraAuthority), false);
});

test("activation-annulment receipt schema preserves history and requires a replacement candidate", () => {
  const ajv = new Ajv2020({
    allErrors: true,
    strict: true,
    strictRequired: false,
    formats: { "date-time": true },
  });
  const validate = ajv.compile(rollbackReceiptSchema);
  const activation = {
    ...candidate,
    activationCommit: "3".repeat(40),
    changedPathsSha256: "4".repeat(64),
  };
  const receipt = {
    schemaVersion: 2,
    rowId: "quota.claude_statusline",
    authorityGeneration: 1,
    transition: "annulment",
    status: "active",
    evidence: ["https://github.com/Imagine-That-Ai/BurnBar/pull/2097"],
    approvedBy: "@release-owner",
    approvedAt: "2026-07-28T00:00:00Z",
    commit: "5".repeat(40),
    activationAnnulment: {
      promotionReceiptSha256: "6".repeat(64),
      candidate,
      activation,
      advancedMainCommit: "5".repeat(40),
      reason: "release_train_advanced_before_stable_receipt",
      replacementCandidateRequired: true,
    },
  };
  assert.equal(validate(receipt), true, JSON.stringify(validate.errors));

  const weakened = structuredClone(receipt);
  weakened.activationAnnulment.replacementCandidateRequired = false;
  assert.equal(validate(weakened), false);
  const mixed = structuredClone(receipt);
  mixed.release = {};
  assert.equal(validate(mixed), false);
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
