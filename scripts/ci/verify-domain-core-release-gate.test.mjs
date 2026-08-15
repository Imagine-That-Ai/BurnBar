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
const ACTIVATION = Object.freeze({
  candidateCommit: CANDIDATE.candidateCommit,
  activationCommit: "d".repeat(40),
  coreVersion: CANDIDATE.coreVersion,
  abiVersion: CANDIDATE.abiVersion,
  sourceSha256: CANDIDATE.sourceSha256,
  changedPathsSha256: "e".repeat(64),
  releaseCommit: "d".repeat(40),
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
      release: { version: "1.2.3", tag: "v1.2.3", commit: ACTIVATION.activationCommit },
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
    "--release-commit",
    ACTIVATION.activationCommit,
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
    "--release-version",
    "1.2.3",
    "--release-tag",
    "v1.2.3",
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
      activationVerifier: () => ACTIVATION,
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
            activationVerifier: () => ACTIVATION,
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
    run(files.args, {
      promotionVerifier: () => [],
      activationVerifier: () => ACTIVATION,
    });
    assert.doesNotThrow(() =>
      run(files.args, {
        promotionVerifier: () => [],
        activationVerifier: () => ACTIVATION,
      }),
    );
    writeFileSync(files.output, "different");
    assert.throws(
      () =>
        run(files.args, {
          promotionVerifier: () => [],
          activationVerifier: () => ACTIVATION,
        }),
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
        release: { version: "1.2.3", tag: "v1.2.3", commit: ACTIVATION.activationCommit },
        tampered: true,
      })}\n`,
    );
    const tamperedSha256 = sha(readFileSync(files.rollbackArtifact));
    assert.throws(
      () =>
        run(replaceArgument(files.args, "--rollback-sha256", tamperedSha256), {
          promotionVerifier: () => [],
          activationVerifier: () => ACTIVATION,
        }),
      /rollback artifact digest does not match the protected candidate bundle rollback proof/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a rollback artifact missing release coordinates at the release gate", () => {
  const files = fixture();
  try {
    writeFileSync(
      files.rollbackArtifact,
      `${JSON.stringify({
        candidateIdentity: CANDIDATE,
        modes: { quota: "legacy", cloudVault: "legacy" },
      })}\n`,
    );
    assert.throws(
      () =>
        run(files.args, {
          promotionVerifier: () => [],
          activationVerifier: () => ACTIVATION,
        }),
      /rollback artifact release coordinates are missing/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a rollback artifact bound to the wrong release commit at the release gate", () => {
  const files = fixture();
  try {
    writeFileSync(
      files.rollbackArtifact,
      `${JSON.stringify({
        candidateIdentity: CANDIDATE,
        modes: { quota: "legacy", cloudVault: "legacy" },
        release: { version: "1.2.3", tag: "v1.2.3", commit: "f".repeat(40) },
      })}\n`,
    );
    const tamperedSha256 = sha(readFileSync(files.rollbackArtifact));
    assert.throws(
      () =>
        run(
          replaceArgument(files.args, "--rollback-sha256", tamperedSha256),
          {
            promotionVerifier: () => [],
            activationVerifier: () => ACTIVATION,
          },
        ),
      /rollback artifact release commit does not match the expected release P/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a rollback artifact bound to the wrong release version at the release gate", () => {
  const files = fixture();
  try {
    writeFileSync(
      files.rollbackArtifact,
      `${JSON.stringify({
        candidateIdentity: CANDIDATE,
        modes: { quota: "legacy", cloudVault: "legacy" },
        release: { version: "2.0.0", tag: "v2.0.0", commit: ACTIVATION.activationCommit },
      })}\n`,
    );
    const tamperedSha256 = sha(readFileSync(files.rollbackArtifact));
    assert.throws(
      () =>
        run(
          replaceArgument(files.args, "--rollback-sha256", tamperedSha256),
          {
            promotionVerifier: () => [],
            activationVerifier: () => ACTIVATION,
          },
        ),
      /rollback artifact release version does not match the expected release version/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a candidate-only rollback artifact whose release commit equals the candidate commit at the release gate", () => {
  const files = fixture();
  try {
    writeFileSync(
      files.rollbackArtifact,
      `${JSON.stringify({
        candidateIdentity: CANDIDATE,
        modes: { quota: "legacy", cloudVault: "legacy" },
        release: {
          version: "1.2.3",
          tag: "v1.2.3",
          commit: CANDIDATE.candidateCommit,
        },
      })}\n`,
    );
    const tamperedSha256 = sha(readFileSync(files.rollbackArtifact));
    assert.throws(
      () =>
        run(
          replaceArgument(
            replaceArgument(files.args, "--rollback-sha256", tamperedSha256),
            "--release-commit",
            CANDIDATE.candidateCommit,
          ),
          {
            promotionVerifier: () => [],
            activationVerifier: () => ({
              ...ACTIVATION,
              releaseCommit: CANDIDATE.candidateCommit,
            }),
          },
        ),
      /rollback artifact release commit must be distinct from the candidate commit/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});
