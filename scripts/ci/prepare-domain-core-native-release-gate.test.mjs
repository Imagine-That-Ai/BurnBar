import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  run,
  selectExactSourceRun,
  validateProtectedSignerRun,
} from "./prepare-domain-core-native-release-gate.mjs";
import {
  loadDomainCoreBuildProfiles,
  resolveDomainCoreBuildProfile,
} from "../lib/domain-core-build-profile.mjs";
import { publicDomainProfileSha256 } from "../lib/domain-core-native-release.mjs";

const COMMIT = "a".repeat(40);
const RELEASE_COMMIT = "c".repeat(40);
const CANDIDATE = Object.freeze({
  candidateCommit: COMMIT,
  coreVersion: "0.3.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
});

function sourceRun(overrides = {}) {
  return {
    id: 123,
    run_attempt: 2,
    event: "push",
    head_branch: "main",
    head_sha: COMMIT,
    status: "completed",
    conclusion: "success",
    ...overrides,
  };
}

test("source lookup accepts exactly one successful main push run", () => {
  assert.deepEqual(
    selectExactSourceRun(
      [
        { workflow_runs: [sourceRun({ conclusion: "failure", id: 99 })] },
        { workflow_runs: [sourceRun()] },
      ],
      COMMIT,
    ),
    { runId: 123, runAttempt: 2 },
  );
});

test("source lookup rejects duplicate successes across pagination", () => {
  assert.throws(
    () =>
      selectExactSourceRun(
        [
          { workflow_runs: [sourceRun()] },
          { workflow_runs: [sourceRun({ id: 124 })] },
        ],
        COMMIT,
      ),
    /exactly one successful/,
  );
});

test("source lookup rejects wrong branch, event, commit, status, or attempt", () => {
  for (const overrides of [
    { head_branch: "feature" },
    { event: "workflow_dispatch" },
    { head_sha: "b".repeat(40) },
    { status: "in_progress" },
    { conclusion: "cancelled" },
  ]) {
    assert.throws(() =>
      selectExactSourceRun([{ workflow_runs: [sourceRun(overrides)] }], COMMIT),
    );
  }
  assert.throws(() =>
    selectExactSourceRun(
      [{ workflow_runs: [sourceRun({ run_attempt: 0 })] }],
      COMMIT,
    ),
  );
});

test("signer lookup binds exact successful protected workflow attempt on main", () => {
  const coordinates = { runId: 987, runAttempt: 3 };
  const run = {
    id: 987,
    run_attempt: 3,
    event: "workflow_dispatch",
    status: "completed",
    conclusion: "success",
    head_branch: "main",
    path: ".github/workflows/domain-core-promotion-proof.yml@refs/heads/main",
  };
  assert.deepEqual(
    validateProtectedSignerRun(run, coordinates, COMMIT),
    coordinates,
  );
  for (const overrides of [
    { id: 988 },
    { run_attempt: 4 },
    { event: "push" },
    { status: "in_progress" },
    { conclusion: "failure" },
    { head_branch: "feature" },
    {
      path: ".github/workflows/domain-core-promotion-proof.yml@refs/heads/feature",
    },
  ]) {
    assert.throws(() =>
      validateProtectedSignerRun({ ...run, ...overrides }, coordinates, COMMIT),
    );
  }
});

test("full gate resolves the signed public profile against the exact candidate", () => {
  const outputDirectory = mkdtempSync(join(tmpdir(), "native-gate-run-"));
  const profileCatalogPath = join(outputDirectory, "profiles.json");
  const profileCatalog = JSON.parse(
    readFileSync("config/domain-core-build-profiles.json", "utf8"),
  );
  profileCatalog.profiles["public-production"].modes.quota = "rust";
  writeFileSync(profileCatalogPath, `${JSON.stringify(profileCatalog)}\n`);
  const profile = resolveDomainCoreBuildProfile(
    loadDomainCoreBuildProfiles(profileCatalogPath),
    "public-production",
    CANDIDATE,
  );
  const activationPath = join(outputDirectory, "domain-core-activation.json");
  const activeDomains = Object.entries(profile.modes)
    .filter(([, mode]) => mode === "rust")
    .map(([domain]) => domain);
  writeFileSync(
    activationPath,
    `${JSON.stringify({
      active: true,
      candidateCommit: COMMIT,
      activationCommit: RELEASE_COMMIT,
      coreVersion: CANDIDATE.coreVersion,
      abiVersion: CANDIDATE.abiVersion,
      sourceSha256: CANDIDATE.sourceSha256,
      changedPathsSha256: "d".repeat(64),
      domains: activeDomains.map((domain, index) => ({
        domain,
        rowId: `${domain}.row`,
        promotionReceiptPath: `receipts/${domain}.json`,
        attestationPath: `attestations/${domain}.json`,
        bundlePath: `bundles/${domain}.json`,
        provenancePath: `provenance/${domain}.json`,
        signerRunId: 100 + index,
        signerRunAttempt: 1,
        publicProfileSha256: publicDomainProfileSha256(profile, domain),
      })),
    })}\n`,
  );
  const rollback = `${JSON.stringify({
    candidateIdentity: CANDIDATE,
    modes: {
      quota: "legacy",
      cloudVault: "legacy",
      cloudVaultRewrap: "legacy",
      cloudVaultSearch: "legacy",
      hermes: "legacy",
      pricing: "legacy",
    },
  })}\n`;
  const rollbackArtifactSha256 = createHash("sha256")
    .update(rollback)
    .digest("hex");
  const candidate = `${JSON.stringify({
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
      runId: 123,
      runAttempt: 2,
      event: "push",
      ref: "refs/heads/main",
      headSha: COMMIT,
      jobs: [],
    },
    rollback: {
      jobId: "rollback-drill",
      suiteId: "rollback-drill",
      runId: 123,
      runAttempt: 2,
      reportSha256: "e".repeat(64),
      fromCandidateCommit: COMMIT,
      restoredArtifactSha256: rollbackArtifactSha256,
      restoredMode: "legacy",
    },
  })}\n`;
  const candidateDigest = createHash("sha256").update(candidate).digest("hex");
  const verified = [
    {
      verificationResult: {
        statement: {
          subject: [
            {
              name: "domain-core-candidate-bundle.json",
              digest: { sha256: candidateDigest },
            },
          ],
        },
        signature: {
          certificate: {
            workflow: {
              repository:
                "Imagine-That-Ai/BurnBar/.github/workflows/domain-core-promotion-proof.yml",
            },
            runInvocationURI:
              "https://github.com/Imagine-That-Ai/BurnBar/actions/runs/987/attempts/3",
          },
        },
      },
    },
  ];
  const command = (program, args, options = {}) => {
    assert.equal(program, "gh");
    if (args[0] === "api" && args.includes("--paginate")) {
      return JSON.stringify([{ workflow_runs: [sourceRun()] }]);
    }
    if (args[0] === "run" && args[1] === "download") {
      const directory = args[args.indexOf("--dir") + 1];
      const name = args[args.indexOf("--name") + 1];
      if (name.startsWith("domain-core-candidate-bundle-")) {
        writeFileSync(
          join(directory, "domain-core-candidate-bundle.json"),
          candidate,
        );
      } else {
        writeFileSync(
          join(directory, "domain-core-public-production-rollback.json"),
          rollback,
        );
      }
      return "";
    }
    if (args[0] === "attestation" && args[1] === "download") {
      writeFileSync(
        join(options.cwd, `sha256-${candidateDigest}.jsonl`),
        "protected-attestation",
      );
      return "";
    }
    if (args[0] === "attestation" && args[1] === "verify") {
      return JSON.stringify(verified);
    }
    if (args[0] === "api" && args[1].includes("/actions/runs/987/attempts/3")) {
      return JSON.stringify({
        id: 987,
        run_attempt: 3,
        event: "workflow_dispatch",
        status: "completed",
        conclusion: "success",
        head_branch: "main",
        path: ".github/workflows/domain-core-promotion-proof.yml@refs/heads/main",
      });
    }
    throw new Error(`unexpected command: ${program} ${args.join(" ")}`);
  };

  try {
    const result = run(
      [
        "--candidate-commit",
        COMMIT,
        "--release-commit",
        RELEASE_COMMIT,
        "--activation",
        activationPath,
        "--event-name",
        "push",
        "--requested-profile",
        "public-production",
        "--output-dir",
        outputDirectory,
        "--profile-catalog",
        profileCatalogPath,
      ],
      {
        command,
        activationVerifier: () =>
          JSON.parse(readFileSync(activationPath, "utf8")),
      },
    );
    assert.equal(result.profileName, "public-production");
    assert.deepEqual(result.candidate, CANDIDATE);
    assert.equal(result.activation.activationCommit, RELEASE_COMMIT);
    assert.equal(
      JSON.parse(readFileSync(result.profilePath, "utf8")).candidateIdentity
        .candidateCommit,
      COMMIT,
    );
  } finally {
    rmSync(outputDirectory, { recursive: true, force: true });
  }
});
