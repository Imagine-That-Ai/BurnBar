import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  buildReleaseEvidence,
  run,
} from "./create-domain-core-release-evidence.mjs";
import { verifyProtectedPromotionAttestation } from "../lib/domain-core-release-evidence.mjs";

const CANDIDATE = Object.freeze({
  candidateCommit: "a".repeat(40),
  coreVersion: "0.3.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
});
const PROFILE_SHA = "c".repeat(64);
const ACTIVATION = Object.freeze({
  candidateCommit: CANDIDATE.candidateCommit,
  activationCommit: "d".repeat(40),
  coreVersion: CANDIDATE.coreVersion,
  abiVersion: CANDIDATE.abiVersion,
  sourceSha256: CANDIDATE.sourceSha256,
  changedPathsSha256: "e".repeat(64),
});

function sha(value) {
  return createHash("sha256").update(value).digest("hex");
}

function workspace() {
  const directory = mkdtempSync(join(tmpdir(), "domain-core-release-test-"));
  const candidateBundle = join(directory, "domain-core-candidate-bundle.json");
  const promotionAttestation = join(directory, "promotion.sigstore.json");
  const rollbackArtifact = join(directory, "domain-core-legacy-rollback.json");
  writeFileSync(
    candidateBundle,
    `${JSON.stringify({
      schemaVersion: 1,
      bundleKind: "unsigned-domain-core-candidate",
      status: "eligible_for_attestation",
      proofComplete: true,
      eligibleForAttestation: true,
      promotionAuthorized: false,
      candidate: CANDIDATE,
      workflow: {
        repository: "Imagine-That-Ai/BurnBar",
        workflowPath: ".github/workflows/domain-core.yml",
        workflowName: "Shared Rust domain core",
        runId: 101,
        runAttempt: 2,
        event: "push",
        ref: "refs/heads/main",
        headSha: CANDIDATE.candidateCommit,
        jobs: [
          { id: "rust-and-csharp", status: "completed", conclusion: "success" },
        ],
      },
    })}\n`,
  );
  writeFileSync(
    promotionAttestation,
    '{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json"}\n',
  );
  writeFileSync(
    rollbackArtifact,
    `${JSON.stringify({
      schemaVersion: 1,
      candidateIdentity: CANDIDATE,
      modes: { quota: "legacy", cloudVault: "legacy" },
    })}\n`,
  );
  return { directory, candidateBundle, promotionAttestation, rollbackArtifact };
}

function baseOptions(files, artifactPath) {
  return {
    consumer: "apple",
    domain: "quota",
    artifactKind: "macos-dmg",
    target: "macos-universal",
    version: "1.2.3",
    tag: "v1.2.3",
    commit: ACTIVATION.activationCommit,
    artifactPath,
    candidateBundlePath: files.candidateBundle,
    promotionAttestationPath: files.promotionAttestation,
    protectedSignerRunId: 202,
    protectedSignerRunAttempt: 3,
    rollbackArtifactPath: files.rollbackArtifact,
    publicProfileSha256: PROFILE_SHA,
    promotionVerifier: () => [],
    activationVerifier: () => ACTIVATION,
  };
}

function consoleDeployment() {
  return {
    provider: "firebase-hosting",
    project: "burnbar",
    environment: "production",
    status: "healthy",
    healthChecks: ["marketing", "console", "deploymentIdentity"],
    deployedArtifact: {
      fileName: "console-static-bundle.tar",
      sha256: "f".repeat(64),
    },
    deployRun: {
      repository: "Imagine-That-Ai/BurnBar",
      workflowPath: ".github/workflows/deploy-hosting.yml",
      runId: 303,
      runAttempt: 4,
      event: "push",
      ref: "refs/tags/v1.2.3",
      headSha: ACTIVATION.activationCommit,
      jobSetSha256: "d".repeat(64),
    },
    healthArtifactSha256: "e".repeat(64),
  };
}

test("builds an exact candidate-bound native release contract", () => {
  const files = workspace();
  try {
    const artifact = join(files.directory, "OpenBurnBar-1.2.3-macOS.dmg");
    writeFileSync(artifact, "signed-native-bytes");
    const result = buildReleaseEvidence(baseOptions(files, artifact));
    assert.equal(result.deploymentReceipt, undefined);
    assert.deepEqual(result.common.candidate, CANDIDATE);
    assert.equal(result.common.sourceRun.runId, 101);
    assert.equal(result.common.sourceRun.runAttempt, 2);
    assert.equal(
      result.common.promotionProof.signerWorkflow,
      ".github/workflows/domain-core-promotion-proof.yml",
    );
    assert.equal(result.common.promotionProof.signerRun.runId, 202);
    assert.equal(
      result.common.promotionProof.attestationSubject.sha256,
      sha(readFileSync(files.candidateBundle)),
    );
    assert.equal(
      result.common.rollbackArtifact.sha256,
      sha(readFileSync(files.rollbackArtifact)),
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("cryptographically verifies the exact protected signer and candidate subject", () => {
  const files = workspace();
  try {
    let command;
    const runner = (executable, args) => {
      command = [executable, ...args];
      return {
        status: 0,
        stdout: JSON.stringify([
          {
            verificationResult: {
              signature: {
                certificate: {
                  runInvocationURI:
                    "https://github.com/Imagine-That-Ai/BurnBar/actions/runs/202/attempts/3",
                },
              },
              statement: {
                subject: [
                  {
                    name: "domain-core-candidate-bundle.json",
                    digest: {
                      sha256: sha(readFileSync(files.candidateBundle)),
                    },
                  },
                ],
              },
            },
          },
        ]),
        stderr: "",
      };
    };
    verifyProtectedPromotionAttestation({
      candidateBundlePath: files.candidateBundle,
      promotionAttestationPath: files.promotionAttestation,
      signerRunId: 202,
      signerRunAttempt: 3,
      runner,
    });
    assert.ok(
      command.includes(
        "Imagine-That-Ai/BurnBar/.github/workflows/domain-core-promotion-proof.yml",
      ),
    );
    assert.ok(command.includes("refs/heads/main"));
    assert.ok(command.includes("--deny-self-hosted-runners"));
    assert.ok(command.includes("https://slsa.dev/provenance/v1"));
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a valid signature over a different candidate bundle subject", () => {
  const files = workspace();
  try {
    assert.throws(
      () =>
        verifyProtectedPromotionAttestation({
          candidateBundlePath: files.candidateBundle,
          promotionAttestationPath: files.promotionAttestation,
          signerRunId: 202,
          signerRunAttempt: 3,
          runner: () => ({
            status: 0,
            stdout: JSON.stringify([
              {
                verificationResult: {
                  signature: {
                    certificate: {
                      runInvocationURI:
                        "https://github.com/Imagine-That-Ai/BurnBar/actions/runs/202/attempts/3",
                    },
                  },
                  statement: {
                    subject: [
                      {
                        name: "domain-core-candidate-bundle.json",
                        digest: { sha256: "0".repeat(64) },
                      },
                    ],
                  },
                },
              },
            ]),
            stderr: "",
          }),
        }),
      /does not bind the exact candidate bundle subject and signer run/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a protected signature from a different signer run attempt", () => {
  const files = workspace();
  try {
    assert.throws(
      () =>
        verifyProtectedPromotionAttestation({
          candidateBundlePath: files.candidateBundle,
          promotionAttestationPath: files.promotionAttestation,
          signerRunId: 202,
          signerRunAttempt: 3,
          runner: () => ({
            status: 0,
            stdout: JSON.stringify([
              {
                verificationResult: {
                  signature: {
                    certificate: {
                      runInvocationURI:
                        "https://github.com/Imagine-That-Ai/BurnBar/actions/runs/202/attempts/2",
                    },
                  },
                  statement: {
                    subject: [
                      {
                        name: "domain-core-candidate-bundle.json",
                        digest: {
                          sha256: sha(readFileSync(files.candidateBundle)),
                        },
                      },
                    ],
                  },
                },
              },
            ]),
            stderr: "",
          }),
        }),
      /does not bind the exact candidate bundle subject and signer run/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a release commit outside the path-restricted activation closure", () => {
  const files = workspace();
  try {
    const artifact = join(files.directory, "OpenBurnBar-1.2.3-macOS.dmg");
    writeFileSync(artifact, "signed-native-bytes");
    assert.throws(
      () =>
        buildReleaseEvidence({
          ...baseOptions(files, artifact),
          commit: "f".repeat(40),
          activationVerifier: () => {
            throw new Error("activation diff contains forbidden paths");
          },
        }),
      /forbidden paths/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a rollback artifact from another candidate", () => {
  const files = workspace();
  try {
    const artifact = join(files.directory, "OpenBurnBar-1.2.3-macOS.dmg");
    writeFileSync(artifact, "signed-native-bytes");
    writeFileSync(
      files.rollbackArtifact,
      `${JSON.stringify({
        candidateIdentity: { ...CANDIDATE, candidateCommit: "e".repeat(40) },
        modes: { quota: "legacy" },
      })}\n`,
    );
    assert.throws(
      () => buildReleaseEvidence(baseOptions(files, artifact)),
      /rollback artifact candidate identity does not match/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects rollback evidence that does not restore every declared mode", () => {
  const files = workspace();
  try {
    const artifact = join(files.directory, "OpenBurnBar-1.2.3-macOS.dmg");
    writeFileSync(artifact, "signed-native-bytes");
    writeFileSync(
      files.rollbackArtifact,
      `${JSON.stringify({
        candidateIdentity: CANDIDATE,
        modes: { quota: "rust" },
      })}\n`,
    );
    assert.throws(
      () => buildReleaseEvidence(baseOptions(files, artifact)),
      /restore every declared domain to legacy/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("writes a deployment receipt and predicate with both artifact digests", () => {
  const files = workspace();
  try {
    const artifact = join(
      files.directory,
      "OpenBurnBar-1.2.3-console-deployment.json",
    );
    const predicate = join(files.directory, "console.predicate.json");
    const deployment = join(files.directory, "deployment.json");
    writeFileSync(deployment, `${JSON.stringify(consoleDeployment())}\n`);
    const result = run(
      [
        "--consumer",
        "console",
        "--domain",
        "cloudVault",
        "--artifact-kind",
        "console-deployment-receipt",
        "--target",
        "firebase-hosting-production",
        "--version",
        "1.2.3",
        "--tag",
        "v1.2.3",
        "--commit",
        ACTIVATION.activationCommit,
        "--artifact",
        artifact,
        "--predicate",
        predicate,
        "--public-profile-sha256",
        PROFILE_SHA,
        "--candidate-bundle",
        files.candidateBundle,
        "--promotion-attestation",
        files.promotionAttestation,
        "--protected-signer-run-id",
        "202",
        "--protected-signer-run-attempt",
        "3",
        "--rollback-artifact",
        files.rollbackArtifact,
        "--deployment",
        deployment,
      ],
      { promotionVerifier: () => [], activationVerifier: () => ACTIVATION },
    );
    const receipt = JSON.parse(readFileSync(artifact, "utf8"));
    const writtenPredicate = JSON.parse(readFileSync(predicate, "utf8"));
    assert.equal(receipt.schemaVersion, 2);
    assert.equal(receipt.deployment.deployedArtifact.sha256, "f".repeat(64));
    assert.equal(receipt.deployment.deployRun.runId, 303);
    assert.equal(receipt.deployment.deployRun.runAttempt, 4);
    assert.equal(receipt.deployment.healthArtifactSha256, "e".repeat(64));
    assert.equal(writtenPredicate.artifact.sha256, sha(readFileSync(artifact)));
    assert.equal(
      writtenPredicate.rollbackArtifact.sha256,
      result.predicate.rollbackArtifact.sha256,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects substituted deployment run and health artifact bindings", () => {
  const files = workspace();
  try {
    const artifact = join(
      files.directory,
      "OpenBurnBar-1.2.3-console-deployment.json",
    );
    const cases = [
      (deployment) => {
        deployment.deployRun.workflowPath =
          ".github/workflows/deploy-production.yml";
      },
      (deployment) => {
        deployment.deployRun.ref = "refs/tags/v1.2.2";
      },
      (deployment) => {
        deployment.deployRun.headSha = "0".repeat(40);
      },
      (deployment) => {
        deployment.deployRun.jobSetSha256 = "invalid";
      },
      (deployment) => {
        deployment.healthArtifactSha256 = "invalid";
      },
    ];
    for (const mutate of cases) {
      const deployment = consoleDeployment();
      mutate(deployment);
      assert.throws(() =>
        buildReleaseEvidence({
          ...baseOptions(files, artifact),
          consumer: "console",
          domain: "cloudVault",
          artifactKind: "console-deployment-receipt",
          target: "firebase-hosting-production",
          deployment,
        }),
      );
    }
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("refuses to rewrite an immutable predicate with different bytes", () => {
  const files = workspace();
  try {
    const artifact = join(files.directory, "OpenBurnBar-1.2.3-macOS.dmg");
    const predicate = join(files.directory, "apple.predicate.json");
    writeFileSync(artifact, "signed-native-bytes");
    writeFileSync(predicate, "{}\n");
    assert.throws(
      () =>
        run(
          [
            "--consumer",
            "apple",
            "--domain",
            "quota",
            "--artifact-kind",
            "macos-dmg",
            "--target",
            "macos-universal",
            "--version",
            "1.2.3",
            "--tag",
            "v1.2.3",
            "--commit",
            ACTIVATION.activationCommit,
            "--artifact",
            artifact,
            "--predicate",
            predicate,
            "--public-profile-sha256",
            PROFILE_SHA,
            "--candidate-bundle",
            files.candidateBundle,
            "--promotion-attestation",
            files.promotionAttestation,
            "--protected-signer-run-id",
            "202",
            "--protected-signer-run-attempt",
            "3",
            "--rollback-artifact",
            files.rollbackArtifact,
          ],
          { promotionVerifier: () => [], activationVerifier: () => ACTIVATION },
        ),
      /refusing to replace non-identical immutable output/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});
