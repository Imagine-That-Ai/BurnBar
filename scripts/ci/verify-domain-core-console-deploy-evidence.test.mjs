import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { run as createIdentity } from "./create-domain-core-deployment-identity.mjs";
import { run } from "./verify-domain-core-console-deploy-evidence.mjs";

const CANDIDATE_COMMIT = "a".repeat(40);
const COMMIT = "d".repeat(40);
const TAG = "v1.2.3";
const CANDIDATE = {
  candidateCommit: CANDIDATE_COMMIT,
  coreVersion: "0.3.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
};

function sha(value) {
  return createHash("sha256").update(value).digest("hex");
}

function fixture(profileName = "public-production") {
  const directory = mkdtempSync(join(tmpdir(), "console-deploy-proof-"));
  const paths = Object.fromEntries(
    ["profile", "gate", "identity", "health", "run", "jobs", "output"].map(
      (name) => [name, join(directory, `${name}.json`)],
    ),
  );
  const rollback = profileName === "public-production-rollback";
  const profile = {
    schemaVersion: 1,
    name: profileName,
    artifactAuthority: "signed",
    distribution: "public",
    rolloutChannel: null,
    evidenceEnabled: false,
    modes: {
      quota: rollback ? "legacy" : "rust",
      cloudVault: rollback ? "legacy" : "rust",
      cloudVaultRewrap: "legacy",
      cloudVaultSearch: "legacy",
      hermes: "legacy",
      pricing: "legacy",
    },
    candidateIdentity: CANDIDATE,
  };
  const gate = {
    schemaVersion: 2,
    verificationKind: "domain-core-release-gate",
    candidate: CANDIDATE,
    activation: {
      ...CANDIDATE,
      activationCommit: COMMIT,
      changedPathsSha256: "f".repeat(64),
    },
    sourceRun: {
      repository: "Imagine-That-Ai/BurnBar",
      workflowPath: ".github/workflows/domain-core.yml",
      runId: 101,
      runAttempt: 2,
      event: "push",
      ref: "refs/heads/main",
      headSha: CANDIDATE_COMMIT,
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
      activation: {
        ...CANDIDATE,
        activationCommit: COMMIT,
        changedPathsSha256: "f".repeat(64),
      },
    },
  };
  writeFileSync(paths.profile, `${JSON.stringify(profile, null, 2)}\n`);
  writeFileSync(paths.gate, `${JSON.stringify(gate, null, 2)}\n`);
  createIdentity([
    "--consumer",
    "console",
    "--commit",
    COMMIT,
    "--tag",
    TAG,
    "--profile-receipt",
    paths.profile,
    "--release-gate",
    paths.gate,
    "--output",
    paths.identity,
  ]);
  writeFileSync(
    paths.health,
    `${JSON.stringify(
      {
        provider: "firebase-hosting",
        project: "burnbar",
        environment: "production",
        status: "healthy",
        healthChecks: [
          "marketing-http-200-csp",
          "console-http-200-csp",
          "console-deployment-identity-no-redirect",
        ],
        deployedArtifact: {
          fileName: "domain-core-deployment-identity.json",
          sha256: sha(readFileSync(paths.identity)),
        },
      },
      null,
      2,
    )}\n`,
  );
  writeFileSync(
    paths.run,
    `${JSON.stringify({
      id: 303,
      run_attempt: 4,
      path: ".github/workflows/deploy-hosting.yml",
      head_sha: COMMIT,
      head_branch: TAG,
      event: "push",
      status: "completed",
      conclusion: "success",
    })}\n`,
  );
  const conclusions = {
    "authorize-domain-core-rollback": rollback ? "success" : "skipped",
    "build-hosting-artifacts": "success",
    "deploy-hosting": "success",
    "hosting-smoke-result": "success",
    "dispatch-domain-core-console-evidence": "success",
  };
  const jobs = Object.entries(conclusions).map(([name, conclusion]) => ({
    name,
    run_id: 303,
    head_sha: COMMIT,
    status: "completed",
    conclusion,
  }));
  writeFileSync(
    paths.jobs,
    `${JSON.stringify([{ total_count: jobs.length, jobs }])}\n`,
  );
  const args = [
    "--deploy-run",
    paths.run,
    "--deploy-jobs",
    paths.jobs,
    "--expected-run-id",
    "303",
    "--expected-run-attempt",
    "4",
    "--expected-commit",
    COMMIT,
    "--expected-tag",
    TAG,
    "--identity",
    paths.identity,
    "--profile-receipt",
    paths.profile,
    "--release-gate",
    paths.gate,
    "--health",
    paths.health,
    "--output",
    paths.output,
  ];
  return { directory, paths, args };
}

test("accepts only the exact successful tag deploy and live identity digest", () => {
  const files = fixture();
  try {
    const receipt = run(files.args);
    assert.equal(receipt.deployRun.runId, 303);
    assert.equal(receipt.deployRun.runAttempt, 4);
    assert.equal(receipt.deployRun.ref, "refs/tags/v1.2.3");
    assert.match(receipt.deployRun.jobSetSha256, /^[0-9a-f]{64}$/u);
    assert.match(receipt.healthArtifactSha256, /^[0-9a-f]{64}$/u);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects stale health evidence from different live identity bytes", () => {
  const files = fixture();
  try {
    const health = JSON.parse(readFileSync(files.paths.health, "utf8"));
    health.deployedArtifact.sha256 = "0".repeat(64);
    writeFileSync(files.paths.health, `${JSON.stringify(health)}\n`);
    assert.throws(
      () => run(files.args),
      /does not bind the verified live identity bytes/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects rollback evidence when protected authorization was skipped", () => {
  const files = fixture("public-production-rollback");
  try {
    const pages = JSON.parse(readFileSync(files.paths.jobs, "utf8"));
    pages[0].jobs.find(
      (job) => job.name === "authorize-domain-core-rollback",
    ).conclusion = "skipped";
    writeFileSync(files.paths.jobs, `${JSON.stringify(pages)}\n`);
    assert.throws(
      () => run(files.args),
      /rollback authorization must be success/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

test("rejects replay against a different deploy attempt", () => {
  const files = fixture();
  try {
    const replay = [...files.args];
    replay[replay.indexOf("--expected-run-attempt") + 1] = "5";
    assert.throws(
      () => run(replay),
      /exact workflow, attempt, tag, and commit/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});
