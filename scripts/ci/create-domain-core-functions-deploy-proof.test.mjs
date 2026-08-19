import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
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
  releaseCommit: "d".repeat(40),
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
      candidate: selected.candidateIdentity,
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

test("binds an inactive legacy release directly to its exact tag commit", () => {
  const selected = profile("public-production", "legacy");
  selected.candidateIdentity = {
    ...CANDIDATE,
    candidateCommit: ACTIVATION.activationCommit,
  };
  const files = workspace(selected);
  try {
    writeFileSync(
      files.releaseGatePath,
      `${JSON.stringify(
        {
          schemaVersion: 2,
          verificationKind: "domain-core-release-gate-inactive",
          candidate: selected.candidateIdentity,
          activation: {
            candidateCommit: ACTIVATION.activationCommit,
            activationCommit: ACTIVATION.activationCommit,
            coreVersion: selected.candidateIdentity.coreVersion,
            abiVersion: selected.candidateIdentity.abiVersion,
            sourceSha256: selected.candidateIdentity.sourceSha256,
            changedPathsSha256:
              "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945",
            releaseCommit: ACTIVATION.activationCommit,
          },
          release: {
            tag: "v1.2.3",
            commit: ACTIVATION.activationCommit,
          },
        },
        null,
        2,
      )}\n`,
    );
    const proof = run([...args(files), "--domain-core-inactive", "true"]);
    assert.equal(proof.profile.value.modes.pricing, "legacy");
    assert.equal(proof.release.commit, ACTIVATION.activationCommit);
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

// ---------------------------------------------------------------------------
// Adversarial functions-deploy-proof tests: staged expected artifacts,
// unrelated dirty files, digest mismatch, filesystem replacement/race, and
// exact provenance repository/workflow validation rather than substring
// acceptance.
// ---------------------------------------------------------------------------

function sha(value) {
  return createHash("sha256").update(value).digest("hex");
}

function proofArgs(files, overrides = {}) {
  return {
    profilePath: files.profilePath,
    compiledReceiptPath: files.compiledReceiptPath,
    runtimeManifestPath: files.runtimeManifestPath,
    releaseGatePath: files.releaseGatePath,
    tag: "v1.2.3",
    commit: ACTIVATION.activationCommit,
    deployRunId: 303,
    deployRunAttempt: 4,
    ...overrides,
  };
}

test("proof binds the exact staged digest of every expected artifact", () => {
  const files = workspace();
  try {
    const proof = run(args(files));
    assert.equal(
      proof.profile.sha256,
      sha(readFileSync(files.profilePath)),
    );
    assert.equal(
      proof.compiledReceipt.sha256,
      sha(readFileSync(files.compiledReceiptPath)),
    );
    assert.equal(
      proof.runtimeArtifact.sha256,
      sha(readFileSync(files.runtimeManifestPath)),
    );
    assert.equal(
      proof.releaseGate.sha256,
      sha(readFileSync(files.releaseGatePath)),
    );
    // The output file must contain the proof with exact staged digests.
    const written = JSON.parse(readFileSync(files.output, "utf8"));
    assert.equal(written.profile.sha256, proof.profile.sha256);
    assert.equal(written.runtimeArtifact.sha256, proof.runtimeArtifact.sha256);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("unrelated dirty workspace files do not alter the deploy proof", () => {
  const files = workspace();
  try {
    writeFileSync(join(files.directory, "stray.log"), "noise");
    writeFileSync(join(files.directory, "unrelated.json"), '{"x": 1}');
    writeFileSync(join(files.directory, "leftover.tmp"), "junk");

    const proof = run(args(files));
    assert.equal(proof.profile.value.name, "public-production");
    assert.equal(proof.profile.value.modes.pricing, "rust");
    assert.deepEqual(proof.deployRun, { runId: 303, runAttempt: 4 });
    assert.equal(
      proof.profile.sha256,
      sha(readFileSync(files.profilePath)),
    );
    assert.equal(
      proof.runtimeArtifact.sha256,
      sha(readFileSync(files.runtimeManifestPath)),
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a runtime manifest whose digest was swapped after staging", () => {
  const files = workspace();
  try {
    const originalProof = run(args(files));
    const originalDigest = originalProof.runtimeArtifact.sha256;

    // Swap the runtime manifest bytes after the proof was written.
    writeFileSync(
      files.runtimeManifestPath,
      `${JSON.stringify({
        schemaVersion: 1,
        manifestKind: "domain-core-runtime-artifact",
        consumer: "functions",
        profile: "public-production",
        candidate: CANDIDATE,
        files: [
          {
            path: "vendor/openburnbar/domain-core-wasm/openburnbar_domain_core_bg.wasm",
            sha256: "0".repeat(64),
            size: 999,
          },
        ],
        tampered: true,
      })}\n`,
    );

    // Re-running must produce a different runtime artifact digest — the
    // proof fails closed because the output already exists with different
    // bytes (the new proof would carry the new digest).
    assert.throws(
      () => run(args(files)),
      /refusing to replace non-identical .* deploy proof/u,
    );

    // The original proof's digest does not match the swapped manifest.
    assert.notEqual(
      originalDigest,
      sha(readFileSync(files.runtimeManifestPath)),
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a profile replaced by a symlink after staging", () => {
  const files = workspace();
  try {
    const decoy = join(files.directory, "decoy-profile.json");
    writeFileSync(decoy, `${JSON.stringify(profile())}\n`);
    rmSync(files.profilePath);
    symlinkSync(decoy, files.profilePath);

    assert.throws(
      () => buildFunctionsDeployProof(proofArgs(files)),
      /must be a .*regular file/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a runtime manifest replaced by a symlink after staging", () => {
  const files = workspace();
  try {
    const decoy = join(files.directory, "decoy-manifest.json");
    writeFileSync(
      decoy,
      `${JSON.stringify({
        schemaVersion: 1,
        manifestKind: "domain-core-runtime-artifact",
        consumer: "functions",
        profile: "public-production",
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
    rmSync(files.runtimeManifestPath);
    symlinkSync(decoy, files.runtimeManifestPath);

    assert.throws(
      () => buildFunctionsDeployProof(proofArgs(files)),
      /must be a .*regular file/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a release gate replaced by a symlink after staging", () => {
  const files = workspace();
  try {
    const decoy = join(files.directory, "decoy-gate.json");
    writeFileSync(decoy, readFileSync(files.releaseGatePath, "utf8"));
    rmSync(files.releaseGatePath);
    symlinkSync(decoy, files.releaseGatePath);

    assert.throws(
      () => buildFunctionsDeployProof(proofArgs(files)),
      /must be a .*regular file/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a compiled receipt replaced by a symlink after staging", () => {
  const files = workspace();
  try {
    const decoy = join(files.directory, "decoy-receipt.js");
    writeFileSync(
      decoy,
      profileFunctionsJavaScript(profile()),
    );
    rmSync(files.compiledReceiptPath);
    symlinkSync(decoy, files.compiledReceiptPath);

    assert.throws(
      () => buildFunctionsDeployProof(proofArgs(files)),
      /must be a .*regular file/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("proof repository and workflow path are exact constants, not substring-validated", () => {
  const files = workspace();
  try {
    const proof = run(args(files));
    assert.equal(proof.repository, "Imagine-That-Ai/BurnBar");
    assert.equal(
      proof.workflowPath,
      ".github/workflows/deploy-production.yml",
    );
    // The repository is an exact match — a substring like the org name
    // alone must not be accepted as equivalent.
    assert.notEqual(proof.repository, "Imagine-That-Ai");
    assert.notEqual(proof.repository, "BurnBar");
    // The workflow path is exact — a substring match must not pass.
    assert.notEqual(proof.workflowPath, "deploy-production.yml");
    assert.notEqual(
      proof.workflowPath,
      ".github/workflows/deploy-production",
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("output deploy proof is immutable and refuses rewrite with different bytes", () => {
  const files = workspace();
  try {
    run(args(files));
    const original = readFileSync(files.output, "utf8");

    // Tamper with the output file to simulate a replacement attack.
    writeFileSync(files.output, '{"tampered": true}\n');

    // Re-running must fail closed because the output exists with different
    // bytes than the expected proof.
    assert.throws(
      () => run(args(files)),
      /refusing to replace non-identical .* deploy proof/u,
    );

    // The tampered output does not match the original proof.
    assert.notEqual(readFileSync(files.output, "utf8"), original);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a runtime manifest missing the required WASM file binding", () => {
  const files = workspace();
  try {
    writeFileSync(
      files.runtimeManifestPath,
      `${JSON.stringify({
        schemaVersion: 1,
        manifestKind: "domain-core-runtime-artifact",
        consumer: "functions",
        profile: "public-production",
        candidate: CANDIDATE,
        files: [
          {
            path: "vendor/other/openburnbar_domain_core_bg.wasm",
            sha256: "9".repeat(64),
            size: 100,
          },
        ],
      })}\n`,
    );
    assert.throws(
      () => buildFunctionsDeployProof(proofArgs(files)),
      /Functions runtime manifest is not bound to the selected candidate and WASM/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects a runtime manifest whose candidate identity differs from the profile", () => {
  const files = workspace();
  try {
    writeFileSync(
      files.runtimeManifestPath,
      `${JSON.stringify({
        schemaVersion: 1,
        manifestKind: "domain-core-runtime-artifact",
        consumer: "functions",
        profile: "public-production",
        candidate: { ...CANDIDATE, candidateCommit: "f".repeat(40) },
        files: [
          {
            path: "vendor/openburnbar/domain-core-wasm/openburnbar_domain_core_bg.wasm",
            sha256: "9".repeat(64),
            size: 100,
          },
        ],
      })}\n`,
    );
    assert.throws(
      () => buildFunctionsDeployProof(proofArgs(files)),
      /Functions runtime manifest is not bound to the selected candidate and WASM/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});
