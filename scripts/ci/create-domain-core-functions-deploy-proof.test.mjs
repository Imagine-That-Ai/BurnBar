import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { profileFunctionsJavaScript } from "../lib/domain-core-build-profile.mjs";
import {
  buildFunctionsDeployProof,
  run,
} from "./create-domain-core-functions-deploy-proof.mjs";

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
});
const DOMAINS = [
  "quota",
  "cloudVault",
  "cloudVaultRewrap",
  "cloudVaultSearch",
  "hermes",
  "pricing",
];

function profile(name = "public-production", pricing = "rust") {
  return {
    schemaVersion: 1,
    name,
    artifactAuthority: "signed",
    distribution: "public",
    rolloutChannel: null,
    evidenceEnabled: false,
    modes: Object.fromEntries(
      DOMAINS.map((domain) => [
        domain,
        domain === "pricing" ? pricing : "legacy",
      ]),
    ),
    candidateIdentity: structuredClone(CANDIDATE),
  };
}

function workspace(selected = profile()) {
  const directory = mkdtempSync(join(tmpdir(), "functions-deploy-proof-test-"));
  const profilePath = join(directory, "profile.json");
  const compiledReceiptPath = join(directory, "domainCoreCandidateReceipt.js");
  const releaseGatePath = join(directory, "domain-core-release-gate.json");
  const runtimeManifestPath = join(
    directory,
    "domain-core-runtime-artifact-manifest.json",
  );
  const output = join(directory, "domain-core-functions-deploy-proof.json");
  writeFileSync(profilePath, `${JSON.stringify(selected, null, 2)}\n`);
  writeFileSync(compiledReceiptPath, profileFunctionsJavaScript(selected));
  writeFileSync(
    runtimeManifestPath,
    `${JSON.stringify({
      schemaVersion: 1,
      manifestKind: "domain-core-runtime-artifact",
      consumer: "functions",
      profile: selected.name,
      candidate: CANDIDATE,
      files: [
        {
          path: "vendor/openburnbar/domain-core-wasm/openburnbar_domain_core_bg.wasm",
          sha256: "9".repeat(64),
          size: 100,
        },
      ],
    })}\n`,
  );
  writeFileSync(
    releaseGatePath,
    `${JSON.stringify(
      {
        schemaVersion: 2,
        verificationKind: "domain-core-release-gate",
        releaseCommit: ACTIVATION.activationCommit,
        candidate: CANDIDATE,
        activation: ACTIVATION,
        sourceRun: { runId: 101, runAttempt: 2 },
        promotionProof: { signerRun: { runId: 202, runAttempt: 3 } },
        rollbackArtifact: {
          fileName: "domain-core-public-production-rollback.json",
          sha256: "c".repeat(64),
          candidate: CANDIDATE,
          activation: ACTIVATION,
        },
      },
      null,
      2,
    )}\n`,
  );
  return {
    directory,
    profilePath,
    compiledReceiptPath,
    runtimeManifestPath,
    releaseGatePath,
    output,
  };
}

function args(files) {
  return [
    "--profile",
    files.profilePath,
    "--compiled-receipt",
    files.compiledReceiptPath,
    "--runtime-manifest",
    files.runtimeManifestPath,
    "--release-gate",
    files.releaseGatePath,
    "--tag",
    "v1.2.3",
    "--commit",
    ACTIVATION.activationCommit,
    "--deploy-run-id",
    "303",
    "--deploy-run-attempt",
    "4",
    "--output",
    files.output,
  ];
}

test("binds the selected profile, compiled receipt, release gate, and exact deploy run", () => {
  const files = workspace();
  try {
    const proof = run(args(files));
    assert.equal(proof.profile.value.name, "public-production");
    assert.equal(proof.profile.value.modes.pricing, "rust");
    assert.equal(proof.release.commit, ACTIVATION.activationCommit);
    assert.deepEqual(proof.deployRun, { runId: 303, runAttempt: 4 });
    assert.match(proof.compiledReceipt.sha256, /^[0-9a-f]{64}$/u);
    assert.equal(
      JSON.parse(readFileSync(files.output, "utf8")).proofKind,
      proof.proofKind,
    );
    run(args(files));
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a compiled receipt that differs from the selected profile", () => {
  const files = workspace();
  try {
    writeFileSync(
      files.compiledReceiptPath,
      profileFunctionsJavaScript(profile("public-production", "legacy")),
    );
    assert.throws(
      () => run(args(files)),
      /compiled Functions receipt does not match the selected profile/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("requires rollback profiles to be permanently legacy", () => {
  const files = workspace(profile("public-production-rollback", "rust"));
  try {
    assert.throws(
      () => run(args(files)),
      /rollback profile must restore every domain to legacy/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a release gate for another candidate", () => {
  const files = workspace();
  try {
    const gate = JSON.parse(readFileSync(files.releaseGatePath, "utf8"));
    gate.candidate = { ...gate.candidate, candidateCommit: "d".repeat(40) };
    writeFileSync(files.releaseGatePath, `${JSON.stringify(gate)}\n`);
    assert.throws(
      () =>
        buildFunctionsDeployProof({
          profilePath: files.profilePath,
          compiledReceiptPath: files.compiledReceiptPath,
          runtimeManifestPath: files.runtimeManifestPath,
          releaseGatePath: files.releaseGatePath,
          tag: "v1.2.3",
          commit: ACTIVATION.activationCommit,
          deployRunId: 303,
          deployRunAttempt: 4,
        }),
      /release gate candidate does not match/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});
