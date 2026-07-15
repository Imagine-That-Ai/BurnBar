import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { run } from "./verify-domain-core-release-gate.mjs";

const CANDIDATE = Object.freeze({
  candidateCommit: "a".repeat(40),
  coreVersion: "0.3.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
});

function sha(value) {
  return createHash("sha256").update(value).digest("hex");
}

function fixture() {
  const directory = mkdtempSync(
    join(tmpdir(), "domain-core-release-gate-test-"),
  );
  const candidateBundle = join(directory, "domain-core-candidate-bundle.json");
  const promotionAttestation = join(directory, "promotion.sigstore.json");
  const rollbackArtifact = join(directory, "domain-core-legacy-rollback.json");
  const output = join(directory, "release-gate.json");
  writeFileSync(promotionAttestation, "signed-protected-attestation");
  writeFileSync(
    rollbackArtifact,
    `${JSON.stringify({
      candidateIdentity: CANDIDATE,
      modes: { quota: "legacy", cloudVault: "legacy" },
    })}\n`,
  );
  const rollbackArtifactSha256 = sha(readFileSync(rollbackArtifact));
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
        jobs: [],
      },
      rollback: {
        jobId: "rollback-drill",
        suiteId: "rollback-drill",
        runId: 101,
        runAttempt: 2,
        reportSha256: "e".repeat(64),
        fromCandidateCommit: CANDIDATE.candidateCommit,
        restoredArtifactSha256: rollbackArtifactSha256,
        restoredMode: "legacy",
      },
    })}\n`,
  );
  const args = [
    "--candidate-bundle",
    candidateBundle,
    "--promotion-attestation",
    promotionAttestation,
    "--rollback-artifact",
    rollbackArtifact,
    "--candidate-commit",
    CANDIDATE.candidateCommit,
    "--core-version",
    CANDIDATE.coreVersion,
    "--abi-version",
    String(CANDIDATE.abiVersion),
    "--source-sha256",
    CANDIDATE.sourceSha256,
    "--source-run-id",
    "101",
    "--source-run-attempt",
    "2",
    "--protected-signer-run-id",
    "202",
    "--protected-signer-run-attempt",
    "3",
    "--rollback-sha256",
    rollbackArtifactSha256,
    "--output",
    output,
  ];
  return {
    directory,
    candidateBundle,
    promotionAttestation,
    rollbackArtifact,
    rollbackArtifactSha256,
    output,
    args,
  };
}

function replaceArgument(args, flag, value) {
  const result = [...args];
  result[result.indexOf(flag) + 1] = value;
  return result;
}

test("emits an exact pre-release gate for the candidate source signer and rollback bytes", () => {
  const files = fixture();
  try {
    let verifierInput;
    const receipt = run(files.args, {
      promotionVerifier: (value) => {
        verifierInput = value;
        return [];
      },
    });
    assert.deepEqual(receipt.candidate, CANDIDATE);
    assert.equal(receipt.sourceRun.runId, 101);
    assert.equal(receipt.sourceRun.runAttempt, 2);
    assert.equal(receipt.promotionProof.signerRun.runId, 202);
    assert.equal(receipt.promotionProof.signerRun.runAttempt, 3);
    assert.equal(
      receipt.rollbackArtifact.sha256,
      sha(readFileSync(files.rollbackArtifact)),
    );
    assert.equal(verifierInput.signerRunId, 202);
    assert.equal(verifierInput.signerRunAttempt, 3);
    assert.deepEqual(JSON.parse(readFileSync(files.output, "utf8")), receipt);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects candidate tuple source run and rollback substitutions", () => {
  const files = fixture();
  try {
    const cases = [
      ["--source-sha256", "c".repeat(64), /candidate tuple does not match/u],
      ["--source-run-attempt", "3", /source run does not match/u],
      [
        "--rollback-sha256",
        "d".repeat(64),
        /rollback artifact digest does not match/u,
      ],
    ];
    for (const [flag, value, pattern] of cases) {
      assert.throws(
        () =>
          run(replaceArgument(files.args, flag, value), {
            promotionVerifier: () => [],
          }),
        pattern,
      );
    }
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("is byte-idempotent and refuses a different existing gate receipt", () => {
  const files = fixture();
  try {
    run(files.args, { promotionVerifier: () => [] });
    assert.doesNotThrow(() => run(files.args, { promotionVerifier: () => [] }));
    writeFileSync(files.output, "different");
    assert.throws(
      () => run(files.args, { promotionVerifier: () => [] }),
      /refusing to replace non-identical release gate receipt/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects rollback artifact whose SHA-256 differs from the bundle rollback proof", () => {
  const files = fixture();
  try {
    writeFileSync(
      files.rollbackArtifact,
      `${JSON.stringify({
        candidateIdentity: CANDIDATE,
        modes: { quota: "legacy", cloudVault: "legacy" },
        tampered: true,
      })}\n`,
    );
    const tamperedSha256 = sha(readFileSync(files.rollbackArtifact));
    assert.throws(
      () =>
        run(
          replaceArgument(files.args, "--rollback-sha256", tamperedSha256),
          { promotionVerifier: () => [] },
        ),
      /rollback artifact digest does not match the protected candidate bundle rollback proof/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});
