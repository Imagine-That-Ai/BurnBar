import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  buildDeploymentIdentity,
  run,
} from "./create-domain-core-deployment-identity.mjs";

const CANDIDATE = Object.freeze({
  candidateCommit: "a".repeat(40),
  coreVersion: "0.3.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
});
const ACTIVATION = Object.freeze({
  ...CANDIDATE,
  activationCommit: "d".repeat(40),
  changedPathsSha256: "e".repeat(64),
  releaseCommit: "d".repeat(40),
});

function sha(value) {
  return createHash("sha256").update(value).digest("hex");
}

function fixture({ mode = "rust", profileName = "public-production" } = {}) {
  const directory = mkdtempSync(
    join(tmpdir(), "domain-core-console-identity-"),
  );
  const profile = join(directory, "domain-core-build-profile.json");
  const gate = join(directory, "release-gate.json");
  const output = join(directory, "identity.json");
  const profileValue = {
    schemaVersion: 1,
    name: profileName,
    artifactAuthority: "signed",
    distribution: "public",
    rolloutChannel: null,
    evidenceEnabled: false,
    modes: {
      quota: profileName.endsWith("rollback") ? "legacy" : mode,
      cloudVault: profileName.endsWith("rollback") ? "legacy" : mode,
      cloudVaultRewrap: "legacy",
      cloudVaultSearch: "legacy",
      hermes: "legacy",
      pricing: "legacy",
    },
    candidateIdentity: CANDIDATE,
  };
  writeFileSync(profile, `${JSON.stringify(profileValue, null, 2)}\n`);
  const gateValue = {
    schemaVersion: 2,
    verificationKind: "domain-core-release-gate",
    candidate: CANDIDATE,
    activation: ACTIVATION,
    sourceRun: {
      repository: "Imagine-That-Ai/BurnBar",
      workflowPath: ".github/workflows/domain-core.yml",
      runId: 101,
      runAttempt: 2,
      event: "push",
      ref: "refs/heads/main",
      headSha: CANDIDATE.candidateCommit,
    },
    promotionProof: {
      signerWorkflow: ".github/workflows/domain-core-promotion-proof.yml",
      predicateType: "https://slsa.dev/provenance/v1",
      signerRun: { runId: 202, runAttempt: 3 },
      attestationSubject: {
        fileName: "domain-core-candidate-bundle.json",
        sha256: "c".repeat(64),
      },
      attestationBundleSha256: "d".repeat(64),
    },
    rollbackArtifact: {
      fileName: "domain-core-public-production-rollback.json",
      sha256: "e".repeat(64),
      candidate: CANDIDATE,
      activation: ACTIVATION,
    },
  };
  writeFileSync(gate, `${JSON.stringify(gateValue, null, 2)}\n`);
  return { directory, profile, profileValue, gate, gateValue, output };
}

test("binds the live Console identity to exact profile candidate and proof bytes", () => {
  const files = fixture();
  try {
    const identity = buildDeploymentIdentity({
      consumer: "console",
      commit: ACTIVATION.activationCommit,
      tag: "v1.2.3+build.7",
      profileReceiptPath: files.profile,
      releaseGatePath: files.gate,
    });
    assert.equal(identity.schemaVersion, 2);
    assert.equal(
      identity.profile.sha256,
      "3657c5cc7dd184f12f6f7682ae039f4b13f1fb45aa8205cde1cb2052c27a0f8b",
    );
    assert.equal(
      identity.profile.receiptSha256,
      sha(readFileSync(files.profile)),
    );
    assert.deepEqual(identity.profile.candidate, CANDIDATE);
    assert.deepEqual(identity.releaseGate, files.gateValue);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("legacy main deploy may omit proof but tagged and Rust deploys fail closed", () => {
  const legacy = fixture({ mode: "legacy" });
  const rust = fixture({ mode: "rust" });
  try {
    assert.equal(
      buildDeploymentIdentity({
        consumer: "console",
        commit: CANDIDATE.candidateCommit,
        profileReceiptPath: legacy.profile,
      }).releaseGate,
      null,
    );
    assert.throws(
      () =>
        buildDeploymentIdentity({
          consumer: "console",
          commit: ACTIVATION.activationCommit,
          tag: "v1.2.3",
          profileReceiptPath: legacy.profile,
        }),
      /require a protected release gate/u,
    );
    assert.throws(
      () =>
        buildDeploymentIdentity({
          consumer: "console",
          commit: ACTIVATION.activationCommit,
          profileReceiptPath: rust.profile,
        }),
      /require a protected release gate/u,
    );
  } finally {
    rmSync(legacy.directory, { recursive: true, force: true });
    rmSync(rust.directory, { recursive: true, force: true });
  }
});

test("tagged legacy deployment may bind its tag when the domain-core lane is explicitly inactive", () => {
  const files = fixture({ mode: "legacy" });
  try {
    const identity = buildDeploymentIdentity({
      consumer: "console",
      commit: ACTIVATION.activationCommit,
      tag: "v1.2.3",
      profileReceiptPath: files.profile,
      domainCoreInactive: true,
    });
    assert.equal(identity.tag, "v1.2.3");
    assert.equal(identity.releaseGate, null);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("inactive domain-core mode cannot weaken Rust or rollback profiles", () => {
  const rust = fixture({ mode: "rust" });
  const rollback = fixture({
    mode: "legacy",
    profileName: "public-production-rollback",
  });
  try {
    assert.throws(
      () =>
        buildDeploymentIdentity({
          consumer: "console",
          commit: ACTIVATION.activationCommit,
          tag: "v1.2.3",
          profileReceiptPath: rust.profile,
          domainCoreInactive: true,
        }),
      /inactive domain-core mode is only valid/u,
    );
    assert.throws(
      () =>
        buildDeploymentIdentity({
          consumer: "console",
          commit: CANDIDATE.candidateCommit,
          profileReceiptPath: rollback.profile,
          domainCoreInactive: true,
        }),
      /inactive domain-core mode is only valid/u,
    );
  } finally {
    rmSync(rust.directory, { recursive: true, force: true });
    rmSync(rollback.directory, { recursive: true, force: true });
  }
});

test("rollback deploy requires exact protected proof and all-legacy modes", () => {
  const files = fixture({ profileName: "public-production-rollback" });
  try {
    assert.throws(
      () =>
        buildDeploymentIdentity({
          consumer: "console",
          commit: CANDIDATE.candidateCommit,
          profileReceiptPath: files.profile,
        }),
      /require a protected release gate/u,
    );
    files.profileValue.modes.pricing = "rust";
    writeFileSync(files.profile, `${JSON.stringify(files.profileValue)}\n`);
    assert.throws(
      () =>
        buildDeploymentIdentity({
          consumer: "console",
          commit: CANDIDATE.candidateCommit,
          profileReceiptPath: files.profile,
          releaseGatePath: files.gate,
        }),
      /restore every domain to legacy/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("verification rejects stale hosted identity and substituted proof", () => {
  const files = fixture();
  try {
    const args = [
      "--consumer",
      "console",
      "--commit",
      ACTIVATION.activationCommit,
      "--tag",
      "v1.2.3",
      "--profile-receipt",
      files.profile,
      "--release-gate",
      files.gate,
      "--output",
      files.output,
    ];
    run(args);
    const stale = JSON.parse(readFileSync(files.output, "utf8"));
    stale.releaseGate.promotionProof.signerRun.runAttempt += 1;
    writeFileSync(files.output, `${JSON.stringify(stale)}\n`);
    assert.throws(
      () => run([...args.slice(0, -2), "--verify", files.output]),
      /deployed identity does not match/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});
