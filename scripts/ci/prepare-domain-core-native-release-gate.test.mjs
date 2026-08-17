import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  createCommandRunner,
  isTransientGitHubFailure,
  materializeCandidateBoundRollback,
  normalizeProtectedSignerWorkflowPath,
  resolveGhRetryPolicy,
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

// Builds the exact fixture surface `run` reads: a profile catalog, a canonical
// activation, and a spawnSync-shaped `gh` stub so tests exercise the real
// command runner (including its bounded transient retry) instead of bypassing it.
function createGateFixture(outputDirectory) {
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
  const ok = (stdout = "") => ({ status: 0, stdout, stderr: "" });
  const ghRunner = (program, args, options = {}) => {
    assert.equal(program, "gh");
    if (args[0] === "api" && args.includes("--paginate")) {
      return ok(JSON.stringify([{ workflow_runs: [sourceRun()] }]));
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
      return ok();
    }
    if (args[0] === "attestation" && args[1] === "download") {
      writeFileSync(
        join(options.cwd, `sha256-${candidateDigest}.jsonl`),
        "protected-attestation",
      );
      return ok();
    }
    if (args[0] === "attestation" && args[1] === "verify") {
      return ok(JSON.stringify(verified));
    }
    if (args[0] === "api" && args[1].includes("/actions/runs/987/attempts/3")) {
      return ok(
        JSON.stringify({
          id: 987,
          run_attempt: 3,
          event: "workflow_dispatch",
          status: "completed",
          conclusion: "success",
          head_branch: "main",
          path: ".github/workflows/domain-core-promotion-proof.yml@refs/heads/main",
        }),
      );
    }
    return {
      status: 1,
      stdout: "",
      stderr: `unexpected command: ${program} ${args.join(" ")}`,
    };
  };

  return {
    activationPath,
    profileCatalogPath,
    ghRunner,
    gateArguments: [
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
    activationVerifier: () => ({
      ...JSON.parse(readFileSync(activationPath, "utf8")),
      releaseCommit: RELEASE_COMMIT,
    }),
  };
}

test("full gate resolves the signed public profile against the exact candidate", () => {
  const outputDirectory = mkdtempSync(join(tmpdir(), "native-gate-run-"));
  const fixture = createGateFixture(outputDirectory);
  try {
    const result = run(fixture.gateArguments, {
      command: createCommandRunner(fixture.ghRunner, {
        sleep: () => {},
        log: () => {},
      }),
      activationVerifier: fixture.activationVerifier,
    });
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

// Verbatim failure that broke the v1.0.35 native candidate gate
// (OpenBurnBar Release run 32047967821).
const ARTIFACT_503 =
  "error downloading domain-core-public-production-rollback-" +
  "c292cc99244dc716de45d92e47ae74c89f4a1e47-31487272665-1: HTTP 503: " +
  "No server is currently available to service your request. Sorry about " +
  "that. Please try resubmitting your request and contact us if the problem " +
  "persists. (https://api.github.com/repos/Imagine-That-Ai/BurnBar/actions/" +
  "artifacts/9099629577/zip)";

test("transient GitHub transport failures are separated from terminal ones", () => {
  for (const detail of [
    ARTIFACT_503,
    "HTTP 502: Bad gateway",
    "HTTP 429: You have exceeded a secondary rate limit",
    "dial tcp: lookup api.github.com: ECONNRESET",
    "read tcp 10.1.0.4:443: connection reset by peer",
    "Post \"https://api.github.com/graphql\": net/http: TLS handshake timeout",
    "Get \"https://api.github.com\": context deadline exceeded",
    "GraphQL: something went wrong (server error)",
  ]) {
    assert.equal(isTransientGitHubFailure(detail), true, detail);
  }
  for (const detail of [
    "no valid artifacts found to download",
    "artifact domain-core-candidate-bundle-abc has expired",
    "HTTP 404: Not Found",
    "HTTP 403: Resource not accessible by integration",
    "HTTP 422: Validation Failed",
    "✗ verification failed: no matching attestations found",
    "spawnSync gh ENOENT",
  ]) {
    assert.equal(isTransientGitHubFailure(detail), false, detail);
  }
});

test("gh retry policy defaults to bounded attempts and rejects bad overrides", () => {
  assert.deepEqual(resolveGhRetryPolicy({}), {
    attempts: 5,
    baseSleepSeconds: 2,
  });
  assert.deepEqual(
    resolveGhRetryPolicy({
      OPENBURNBAR_GH_API_ATTEMPTS: "3",
      OPENBURNBAR_GH_API_BASE_SLEEP_SECONDS: "0",
    }),
    { attempts: 3, baseSleepSeconds: 0 },
  );
  assert.throws(
    () => resolveGhRetryPolicy({ OPENBURNBAR_GH_API_ATTEMPTS: "0" }),
    /positive integer/u,
  );
  assert.throws(
    () => resolveGhRetryPolicy({ OPENBURNBAR_GH_API_BASE_SLEEP_SECONDS: "-1" }),
    /non-negative integer/u,
  );
});

test("command runner retries transient gh failures with bounded backoff", () => {
  const calls = [];
  const sleeps = [];
  const command = createCommandRunner(
    (program, args) => {
      calls.push(`${program} ${args[0]} ${args[1]}`);
      if (calls.length < 3) {
        return { status: 1, stdout: "", stderr: ARTIFACT_503 };
      }
      return { status: 0, stdout: "downloaded", stderr: "" };
    },
    { sleep: (seconds) => sleeps.push(seconds), log: () => {} },
  );
  assert.equal(command("gh", ["run", "download", "1", "--repo"]), "downloaded");
  assert.equal(calls.length, 3);
  assert.deepEqual(sleeps, [2, 4]);
});

test("command runner fails closed after exhausting bounded gh attempts", () => {
  let calls = 0;
  const notices = [];
  const command = createCommandRunner(
    () => {
      calls += 1;
      return { status: 1, stdout: "", stderr: ARTIFACT_503 };
    },
    {
      policyEnv: { OPENBURNBAR_GH_API_ATTEMPTS: "4" },
      sleep: () => {},
      log: (message) => notices.push(message),
    },
  );
  assert.throws(
    () => command("gh", ["run", "download", "1", "--repo"]),
    (error) =>
      /failed after 4 attempts/u.test(error.message) &&
      /HTTP 503/u.test(error.message),
  );
  assert.equal(calls, 4);
  assert.equal(notices.length, 3);
  assert.match(notices[0], /attempt 1\/4 failed transiently; retrying in 2s/u);
});

test("command runner never retries terminal failures or local commands", () => {
  let expiredCalls = 0;
  const expired = createCommandRunner(
    () => {
      expiredCalls += 1;
      return {
        status: 1,
        stdout: "",
        stderr: "no valid artifacts found to download",
      };
    },
    { sleep: () => {}, log: () => {} },
  );
  assert.throws(
    () => expired("gh", ["run", "download", "1", "--repo"]),
    /no valid artifacts found to download/u,
  );
  assert.equal(expiredCalls, 1, "expiry must reach the committed-evidence path");

  let gitCalls = 0;
  const git = createCommandRunner(
    () => {
      gitCalls += 1;
      return { status: 1, stdout: "", stderr: ARTIFACT_503 };
    },
    { sleep: () => {}, log: () => {} },
  );
  assert.throws(() => git("git", ["-C", ".", "show", "HEAD"]));
  assert.equal(gitCalls, 1, "local commands must not inherit gh retries");
});

test("full gate survives a transient 503 on the rollback artifact download", () => {
  const outputDirectory = mkdtempSync(join(tmpdir(), "native-gate-503-"));
  const fixture = createGateFixture(outputDirectory);
  const sleeps = [];
  let rollbackAttempts = 0;
  try {
    const result = run(fixture.gateArguments, {
      command: createCommandRunner(
        (program, args, options) => {
          const isRollbackDownload =
            args[0] === "run" &&
            args[1] === "download" &&
            String(args[args.indexOf("--name") + 1]).startsWith(
              "domain-core-public-production-rollback-",
            );
          if (isRollbackDownload) {
            rollbackAttempts += 1;
            if (rollbackAttempts === 1) {
              return { status: 1, stdout: "", stderr: ARTIFACT_503 };
            }
          }
          return fixture.ghRunner(program, args, options);
        },
        { sleep: (seconds) => sleeps.push(seconds), log: () => {} },
      ),
      activationVerifier: fixture.activationVerifier,
    });
    assert.equal(rollbackAttempts, 2);
    assert.deepEqual(sleeps, [2]);
    assert.deepEqual(result.candidate, CANDIDATE);
    assert.equal(result.activation.activationCommit, RELEASE_COMMIT);
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
