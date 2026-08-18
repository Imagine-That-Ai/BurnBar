import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  createCommandRunner,
  isTransientCommandFailure,
  materializeCandidateBoundRollback,
  normalizeProtectedSignerWorkflowPath,
  run,
  selectCommittedCandidateBundle,
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
    // Live GitHub Actions run metadata returns the bare workflow path.
    path: ".github/workflows/domain-core-promotion-proof.yml",
  };
  assert.deepEqual(
    normalizeProtectedSignerWorkflowPath(run.path),
    {
      workflowPath: ".github/workflows/domain-core-promotion-proof.yml",
      sourceRef: null,
    },
  );
  assert.deepEqual(
    validateProtectedSignerRun(run, coordinates, COMMIT),
    coordinates,
  );
  // Legacy fixture / attestation identity form still accepted on main.
  assert.deepEqual(
    validateProtectedSignerRun(
      {
        ...run,
        path: ".github/workflows/domain-core-promotion-proof.yml@refs/heads/main",
      },
      coordinates,
      COMMIT,
    ),
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
  const githubOutput = join(outputDirectory, "github-output.txt");
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
    release: {
      version: CANDIDATE.coreVersion,
      tag: `v${CANDIDATE.coreVersion}`,
      commit: RELEASE_COMMIT,
    },
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
        "--github-output",
        githubOutput,
      ],
      {
        command,
        activationVerifier: () => ({
          ...JSON.parse(readFileSync(activationPath, "utf8")),
          releaseCommit: RELEASE_COMMIT,
        }),
      },
    );
    assert.equal(result.profileName, "public-production");
    assert.deepEqual(result.candidate, CANDIDATE);
    assert.equal(result.activation.activationCommit, RELEASE_COMMIT);
    // release.yml skips every Rust demand unless this reads exactly "true",
    // so an active gate that forgets to emit it would fail open.
    assert.equal(result.rustActive, true);
    assert.match(readFileSync(githubOutput, "utf8"), /^rust_active=true$/mu);
    assert.equal(
      JSON.parse(readFileSync(result.profilePath, "utf8")).candidateIdentity
        .candidateCommit,
      COMMIT,
    );
  } finally {
    rmSync(outputDirectory, { recursive: true, force: true });
  }
});

test("expired Actions artifacts hydrate from committed promotion evidence", () => {
  const REAL_CANDIDATE = "99ba1f66b02d4721077bbce652b84c2304bacf7c";
  const REAL_SOURCE_RUN = { runId: 30754893279, runAttempt: 1 };
  const selected = selectCommittedCandidateBundle({
    repoRoot: process.cwd(),
    candidateCommit: REAL_CANDIDATE,
    sourceRun: REAL_SOURCE_RUN,
  });
  assert.match(selected.path, /promotion-bundles\//u);
  assert.equal(selected.bundle.candidate.candidateCommit, REAL_CANDIDATE);

  const outputDirectory = mkdtempSync(join(tmpdir(), "native-gate-expired-"));
  const sourceDirectory = join(outputDirectory, "source");
  try {
    const materialized = materializeCandidateBoundRollback({
      repoRoot: process.cwd(),
      candidateCommit: REAL_CANDIDATE,
      sourceRun: REAL_SOURCE_RUN,
      sourceDirectory,
    });
    assert.equal(materialized.source, "committed");
    assert.equal(
      createHash("sha256")
        .update(readFileSync(materialized.candidatePath))
        .digest("hex"),
      createHash("sha256").update(readFileSync(selected.path)).digest("hex"),
    );
    assert.equal(
      createHash("sha256")
        .update(readFileSync(materialized.rollbackPath))
        .digest("hex"),
      selected.bundle.rollback.restoredArtifactSha256,
    );
  } finally {
    rmSync(outputDirectory, { recursive: true, force: true });
  }
});

// Verbatim stderr from release run 32047967821, which lost the v1.0.35 cut on
// the protected rollback artifact download.
const OBSERVED_503 =
  "error downloading domain-core-public-production-rollback-c292cc99244dc716de45d92e47ae74c89f4a1e47-31487272665-1: " +
  "HTTP 503: No server is currently available to service your request. Sorry about that. Please try resubmitting " +
  "your request and contact us if the problem persists. " +
  "(https://api.github.com/repos/Imagine-That-Ai/BurnBar/actions/artifacts/9099629577/zip)";

function recordingRunner(results) {
  const calls = [];
  return {
    calls,
    runner: (command, args) => {
      calls.push([command, ...args]);
      return results[Math.min(calls.length - 1, results.length - 1)];
    },
  };
}

test("transient artifact download failures retry inside the bound", () => {
  const { calls, runner } = recordingRunner([
    { status: 1, stdout: "", stderr: OBSERVED_503 },
    { status: 1, stdout: "", stderr: OBSERVED_503 },
    { status: 0, stdout: "downloaded", stderr: "" },
  ]);
  const delays = [];
  const command = createCommandRunner(runner, {
    baseSleepMs: 1_000,
    sleep: (ms) => delays.push(ms),
    log: () => {},
  });

  assert.equal(
    command("gh", ["run", "download", "31487272665", "--repo"]),
    "downloaded",
  );
  assert.equal(calls.length, 3);
  assert.deepEqual(delays, [1_000, 2_000]);
});

test("transient failures still fail closed once the retry bound is spent", () => {
  const { calls, runner } = recordingRunner([
    { status: 1, stdout: "", stderr: OBSERVED_503 },
  ]);
  const command = createCommandRunner(runner, {
    attempts: 3,
    sleep: () => {},
    log: () => {},
  });

  assert.throws(
    () => command("gh", ["run", "download", "31487272665", "--repo"]),
    /HTTP 503/u,
  );
  assert.equal(calls.length, 3);
});

test("permanent failures fail on the first attempt", () => {
  for (const stderr of [
    "HTTP 404: Not Found",
    "gh: Bad credentials",
    "failed to verify attestation: no matching attestations found",
  ]) {
    const { calls, runner } = recordingRunner([
      { status: 1, stdout: "", stderr },
    ]);
    const command = createCommandRunner(runner, {
      sleep: () => {
        throw new Error("permanent failures must not sleep");
      },
      log: () => {},
    });
    assert.throws(() => command("gh", ["attestation", "verify"]));
    assert.equal(calls.length, 1, stderr);
  }
});

// The expired-artifact path has its own committed-bundle fallback, so it must
// stay a single fast attempt rather than burning the transient retry budget.
test("expired artifact downloads bypass the transient retry budget", () => {
  for (const stderr of [
    "no valid artifacts found to download",
    "artifact domain-core-candidate-bundle-abc has expired",
  ]) {
    assert.equal(isTransientCommandFailure(stderr), false, stderr);
    const { calls, runner } = recordingRunner([
      { status: 1, stdout: "", stderr },
    ]);
    const command = createCommandRunner(runner, {
      sleep: () => {
        throw new Error("expired artifacts must not sleep");
      },
      log: () => {},
    });
    assert.throws(() => command("gh", ["run", "download"]));
    assert.equal(calls.length, 1, stderr);
  }
});

const AUTHORITY_COMMIT = "e".repeat(40);
const EMPTY_CHANGED_PATHS_SHA256 = createHash("sha256")
  .update("[]")
  .digest("hex");

function inactiveGateFixture() {
  const outputDirectory = mkdtempSync(join(tmpdir(), "native-gate-legacy-"));
  const profileCatalogPath = join(outputDirectory, "profiles.json");
  writeFileSync(
    profileCatalogPath,
    readFileSync("config/domain-core-build-profiles.json", "utf8"),
  );
  const activationPath = join(outputDirectory, "domain-core-activation.json");
  // What the resolver actually emits when no domain is on Rust: C = P = the
  // authority commit that last set the modes, which is not the release commit.
  writeFileSync(
    activationPath,
    `${JSON.stringify({
      active: false,
      candidateCommit: AUTHORITY_COMMIT,
      activationCommit: AUTHORITY_COMMIT,
      coreVersion: CANDIDATE.coreVersion,
      abiVersion: CANDIDATE.abiVersion,
      sourceSha256: CANDIDATE.sourceSha256,
      changedPathsSha256: EMPTY_CHANGED_PATHS_SHA256,
      domains: [],
    })}\n`,
  );
  return { outputDirectory, profileCatalogPath, activationPath };
}

function inactiveGateArguments({
  outputDirectory,
  profileCatalogPath,
  activationPath,
  candidateCommit = AUTHORITY_COMMIT,
}) {
  return [
    "--candidate-commit",
    candidateCommit,
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
  ];
}

function releaseBoundInactiveActivation(overrides = {}) {
  return {
    active: false,
    candidateCommit: RELEASE_COMMIT,
    activationCommit: RELEASE_COMMIT,
    coreVersion: CANDIDATE.coreVersion,
    abiVersion: CANDIDATE.abiVersion,
    sourceSha256: CANDIDATE.sourceSha256,
    changedPathsSha256: EMPTY_CHANGED_PATHS_SHA256,
    domains: [],
    ...overrides,
  };
}

test("inactive activation ships legacy without demanding an attested candidate", () => {
  const fixture = inactiveGateFixture();
  const githubOutput = join(fixture.outputDirectory, "github-output.txt");
  writeFileSync(githubOutput, "");
  try {
    const result = run(
      [...inactiveGateArguments(fixture), "--github-output", githubOutput],
      {
        command: (program, args) => {
          throw new Error(
            `inactive gate must not shell out: ${program} ${args.join(" ")}`,
          );
        },
        releaseActivationResolver: (releaseCommit) => {
          assert.equal(releaseCommit, RELEASE_COMMIT);
          return releaseBoundInactiveActivation();
        },
      },
    );
    assert.equal(result.rustActive, false);
    assert.equal(result.profileName, "public-production");
    assert.equal(result.candidate.candidateCommit, RELEASE_COMMIT);
    assert.equal(
      readFileSync(result.profilePath, "utf8").includes('"rust"'),
      false,
    );
    // The uploaded selector is rebound to the release commit so every
    // downstream validateNativeActivationSelector call still binds C and P.
    assert.deepEqual(
      JSON.parse(readFileSync(result.activationPath, "utf8")),
      releaseBoundInactiveActivation(),
    );
    assert.equal(
      JSON.parse(readFileSync(result.gatePath, "utf8")).resolvedActivationCommit,
      AUTHORITY_COMMIT,
    );
    const emitted = readFileSync(githubOutput, "utf8");
    assert.match(emitted, /^rust_active=false$/mu);
    assert.match(emitted, new RegExp(`^candidate_commit=${RELEASE_COMMIT}$`, "mu"));
    assert.doesNotMatch(emitted, /^signer_run_id=/mu);
  } finally {
    rmSync(fixture.outputDirectory, { recursive: true, force: true });
  }
});

test("inactive gate fails closed when the release checkout still activates Rust", () => {
  const fixture = inactiveGateFixture();
  try {
    assert.throws(
      () =>
        run(inactiveGateArguments(fixture), {
          command: () => {
            throw new Error("unexpected command");
          },
          releaseActivationResolver: () =>
            releaseBoundInactiveActivation({ active: true }),
        }),
      /inactive release gate resolved an active Rust activation/u,
    );
  } finally {
    rmSync(fixture.outputDirectory, { recursive: true, force: true });
  }
});

test("inactive gate rejects a candidate commit the resolver did not emit", () => {
  const fixture = inactiveGateFixture();
  try {
    assert.throws(
      () =>
        run(
          inactiveGateArguments({ ...fixture, candidateCommit: COMMIT }),
          {
            command: () => {
              throw new Error("unexpected command");
            },
            releaseActivationResolver: () => releaseBoundInactiveActivation(),
          },
        ),
      /inactive release gate candidate commit must match the resolved activation/u,
    );
  } finally {
    rmSync(fixture.outputDirectory, { recursive: true, force: true });
  }
});
