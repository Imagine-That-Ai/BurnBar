#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import {
  appendFileSync,
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  loadDomainCoreBuildProfiles,
  resolveDomainCoreBuildProfile,
} from "../lib/domain-core-build-profile.mjs";
import {
  DOMAIN_CORE_CANDIDATE_FILE,
  DOMAIN_CORE_PROMOTION_BUNDLE_FILE,
  DOMAIN_CORE_PROMOTION_PREDICATE_TYPE,
  DOMAIN_CORE_PUBLIC_PROFILE,
  DOMAIN_CORE_ROLLBACK_FILE,
  DOMAIN_CORE_ROLLBACK_PROFILE,
  candidateArtifactName,
  publicProfileSha256,
  resolveNativeReleaseProfile,
  resolveProtectedSignerCoordinates,
  resolveSourceCoordinates,
  rollbackArtifactName,
  validateNativeActivationSelector,
  validateResolvedProfile,
} from "../lib/domain-core-native-release.mjs";
import {
  DOMAIN_CORE_PROTECTED_SIGNER_WORKFLOW,
  DOMAIN_CORE_REPOSITORY,
  DOMAIN_CORE_SOURCE_WORKFLOW,
  sha256File,
  verifyDomainCoreReleaseGate,
} from "../lib/domain-core-release-evidence.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const FULL_SHA = /^[0-9a-f]{40}$/u;
const DEFAULT_GH_ATTEMPTS = 5;
const DEFAULT_GH_BASE_SLEEP_SECONDS = 2;

// Transient GitHub transport failures (5xx, throttling, socket/DNS/TLS faults)
// must not invalidate an otherwise immutable candidate, so `gh` reads retry with
// the same bounded backoff the protected signer uses via
// scripts/ci/gh-api-with-retry.sh. Everything else — expired artifacts,
// permission denials, missing runs, attestation verification failures — stays
// terminal on the first attempt.
const TRANSIENT_GH_FAILURE_PATTERNS = [
  /\bHTTP (?:408|425|429|500|502|503|504)\b/u,
  /\b(?:ECONNRESET|ECONNREFUSED|ECONNABORTED|EPIPE|ETIMEDOUT|EAI_AGAIN|ENOTFOUND|EHOSTUNREACH|ENETUNREACH|ENETDOWN)\b/u,
  /connection reset by peer/iu,
  /\b(?:TLS|SSL) handshake (?:timeout|failure)/iu,
  /\bunexpected EOF\b/iu,
  /\b(?:i\/o timeout|context deadline exceeded|request timed out|timeout awaiting response)\b/iu,
  /\bserver error\b/iu,
  /\bservice unavailable\b/iu,
  /\bsecondary rate limit\b/iu,
];

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${label} returned invalid JSON: ${error.message}`);
  }
}

function exactFile(path, label) {
  if (!existsSync(path)) throw new Error(`${label} is missing: ${path}`);
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size === 0) {
    throw new Error(`${label} must be a nonempty regular file: ${path}`);
  }
  return path;
}

function writeCreateOnly(path, value) {
  const contents = `${JSON.stringify(value, null, 2)}\n`;
  mkdirSync(dirname(path), { recursive: true });
  try {
    writeFileSync(path, contents, {
      encoding: "utf8",
      flag: "wx",
      mode: 0o600,
    });
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    exactFile(path, "immutable release gate output");
    if (readFileSync(path, "utf8") !== contents) {
      throw new Error(
        `refusing to replace non-identical release gate output: ${path}`,
      );
    }
  }
}

export function selectExactSourceRun(rawPages, candidateCommit) {
  if (!Array.isArray(rawPages) || rawPages.length === 0) {
    throw new Error("source run lookup must return paginated GitHub API pages");
  }
  const runs = rawPages.flatMap((page) => {
    if (!page || !Array.isArray(page.workflow_runs)) {
      throw new Error("source run lookup returned an invalid GitHub API page");
    }
    return page.workflow_runs;
  });
  const matches = runs.filter(
    (run) =>
      run?.event === "push" &&
      run?.head_branch === "main" &&
      run?.head_sha === candidateCommit &&
      run?.status === "completed" &&
      run?.conclusion === "success",
  );
  if (matches.length !== 1) {
    throw new Error(
      `expected exactly one successful deterministic main push run for ${candidateCommit}, found ${matches.length}`,
    );
  }
  const run = matches[0];
  if (
    !Number.isSafeInteger(run.id) ||
    run.id < 1 ||
    !Number.isSafeInteger(run.run_attempt) ||
    run.run_attempt < 1
  ) {
    throw new Error("deterministic source run has invalid run coordinates");
  }
  return { runId: run.id, runAttempt: run.run_attempt };
}

export function normalizeProtectedSignerWorkflowPath(path) {
  // GitHub Actions run metadata returns the bare workflow path
  // (`.github/workflows/….yml`). Older fixtures and some attestation identities
  // append `@refs/heads/<branch>`; keep accepting that form when the suffix is
  // exactly `refs/heads/main`.
  const text = typeof path === "string" ? path : "";
  const separator = text.indexOf("@");
  if (separator < 0) {
    return { workflowPath: text, sourceRef: null };
  }
  return {
    workflowPath: text.slice(0, separator),
    sourceRef: text.slice(separator + 1),
  };
}

export function validateProtectedSignerRun(raw, coordinates, candidateCommit) {
  const { workflowPath, sourceRef } = normalizeProtectedSignerWorkflowPath(
    raw?.path,
  );
  if (
    raw?.id !== coordinates.runId ||
    raw?.run_attempt !== coordinates.runAttempt ||
    raw?.event !== "workflow_dispatch" ||
    raw?.status !== "completed" ||
    raw?.conclusion !== "success" ||
    raw?.head_branch !== "main" ||
    workflowPath !== DOMAIN_CORE_PROTECTED_SIGNER_WORKFLOW ||
    (sourceRef !== null && sourceRef !== "refs/heads/main")
  ) {
    throw new Error(
      `protected signer run does not match the exact successful main workflow for ${candidateCommit}`,
    );
  }
  return coordinates;
}

export function isTransientGitHubFailure(detail) {
  const text = detail instanceof Error ? detail.message : String(detail ?? "");
  if (isExpiredArtifactDownloadError(text)) return false;
  return TRANSIENT_GH_FAILURE_PATTERNS.some((pattern) => pattern.test(text));
}

export function resolveGhRetryPolicy(env = process.env) {
  const attempts =
    env.OPENBURNBAR_GH_API_ATTEMPTS ?? String(DEFAULT_GH_ATTEMPTS);
  const baseSleepSeconds =
    env.OPENBURNBAR_GH_API_BASE_SLEEP_SECONDS ??
    String(DEFAULT_GH_BASE_SLEEP_SECONDS);
  if (!/^[1-9][0-9]*$/u.test(String(attempts))) {
    throw new Error("OPENBURNBAR_GH_API_ATTEMPTS must be a positive integer");
  }
  if (!/^[0-9]+$/u.test(String(baseSleepSeconds))) {
    throw new Error(
      "OPENBURNBAR_GH_API_BASE_SLEEP_SECONDS must be a non-negative integer",
    );
  }
  return {
    attempts: Number(attempts),
    baseSleepSeconds: Number(baseSleepSeconds),
  };
}

function sleepSecondsSync(seconds) {
  if (!(seconds > 0)) return;
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, seconds * 1000);
}

export function createCommandRunner(runner = spawnSync, options = {}) {
  // `policyEnv` only tunes the retry budget; spawned commands always inherit the
  // real process environment so `gh` keeps its authenticated token.
  const { attempts, baseSleepSeconds } = resolveGhRetryPolicy(
    options.policyEnv ?? process.env,
  );
  const sleep = options.sleep ?? sleepSecondsSync;
  const log = options.log ?? ((message) => process.stderr.write(message));
  return (command, args, spawnOptions = {}) => {
    const label = `${command} ${args.slice(0, 4).join(" ")}`;
    const maxAttempts = command === "gh" ? attempts : 1;
    for (let attempt = 1; ; attempt += 1) {
      const result = runner(command, args, {
        encoding: "utf8",
        env: process.env,
        maxBuffer: 32 * 1024 * 1024,
        ...spawnOptions,
      });
      const detail = result.error
        ? result.error.message
        : result.status === 0
          ? null
          : (result.stderr || result.stdout || "command failed").trim();
      if (detail === null) return result.stdout;
      const retryable =
        attempt < maxAttempts && isTransientGitHubFailure(detail);
      if (!retryable) {
        if (result.error) throw result.error;
        throw new Error(
          attempt > 1
            ? `${label} failed after ${attempt} attempts: ${detail}`
            : `${label} failed: ${detail}`,
        );
      }
      const sleepSeconds = baseSleepSeconds * attempt;
      log(
        `${label} attempt ${attempt}/${maxAttempts} failed transiently; retrying in ${sleepSeconds}s: ${detail}\n`,
      );
      sleep(sleepSeconds);
    }
  };
}

function parseArguments(argv) {
  const required = new Set([
    "--candidate-commit",
    "--release-commit",
    "--activation",
    "--event-name",
    "--requested-profile",
    "--output-dir",
  ]);
  const optional = new Set([
    "--repository",
    "--github-output",
    "--profile-catalog",
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!required.has(flag) && !optional.has(flag)) {
      throw new Error(`unknown argument: ${String(flag)}`);
    }
    if (value === undefined || value.startsWith("--")) {
      throw new Error(`${flag} requires a value`);
    }
    if (values.has(flag)) throw new Error(`duplicate argument: ${flag}`);
    values.set(flag, value);
  }
  for (const flag of required) {
    if (!values.has(flag)) throw new Error(`${flag} is required`);
  }
  return values;
}

function isExpiredArtifactDownloadError(error) {
  const detail = error instanceof Error ? error.message : String(error);
  return (
    /no valid artifacts found to download/u.test(detail) ||
    /artifact .+ has expired/iu.test(detail) ||
    /expired artifact/iu.test(detail)
  );
}

function downloadRunArtifact(run, repository, name, directory, command) {
  mkdirSync(directory, { recursive: true });
  command("gh", [
    "run",
    "download",
    String(run.runId),
    "--repo",
    repository,
    "--name",
    name,
    "--dir",
    directory,
  ]);
}

function listPromotionBundlePaths(repoRoot) {
  const root = join(repoRoot, "config/domain-core-promotion-bundles");
  if (!existsSync(root)) return [];
  const paths = [];
  for (const scope of readdirSync(root)) {
    const scopeDirectory = join(root, scope);
    if (!lstatSync(scopeDirectory).isDirectory()) continue;
    for (const entry of readdirSync(scopeDirectory)) {
      if (!/^\d+\.json$/u.test(entry)) continue;
      paths.push(join(scopeDirectory, entry));
    }
  }
  return paths.sort();
}

export function selectCommittedCandidateBundle({
  repoRoot,
  candidateCommit,
  sourceRun,
}) {
  const matches = [];
  for (const path of listPromotionBundlePaths(repoRoot)) {
    const bundle = parseJson(
      readFileSync(path, "utf8"),
      `committed promotion bundle ${path}`,
    );
    if (
      bundle?.candidate?.candidateCommit === candidateCommit &&
      bundle?.workflow?.runId === sourceRun.runId &&
      bundle?.workflow?.runAttempt === sourceRun.runAttempt
    ) {
      matches.push({ path, bundle });
    }
  }
  if (matches.length === 0) {
    throw new Error(
      `no committed promotion bundle matches candidate ${candidateCommit} source run ${sourceRun.runId}/${sourceRun.runAttempt}`,
    );
  }
  const digests = new Set(matches.map(({ path }) => sha256File(path)));
  if (digests.size !== 1) {
    throw new Error(
      `committed promotion bundles for ${candidateCommit} disagree on bytes`,
    );
  }
  return matches[0];
}

export function materializeCandidateBoundRollback({
  repoRoot,
  candidateCommit,
  sourceRun,
  sourceDirectory,
  command = createCommandRunner(),
}) {
  mkdirSync(sourceDirectory, { recursive: true });
  const { path: bundlePath, bundle } = selectCommittedCandidateBundle({
    repoRoot,
    candidateCommit,
    sourceRun,
  });
  const candidatePath = join(sourceDirectory, DOMAIN_CORE_CANDIDATE_FILE);
  const rollbackPath = join(sourceDirectory, DOMAIN_CORE_ROLLBACK_FILE);
  copyFileSync(bundlePath, candidatePath);
  exactFile(candidatePath, "committed candidate bundle");
  if (sha256File(candidatePath) !== sha256File(bundlePath)) {
    throw new Error("committed candidate bundle copy drifted during materialize");
  }

  const restoredSha256 = bundle?.rollback?.restoredArtifactSha256;
  if (
    typeof restoredSha256 !== "string" ||
    !/^[0-9a-f]{64}$/u.test(restoredSha256)
  ) {
    throw new Error(
      "committed candidate bundle is missing rollback.restoredArtifactSha256",
    );
  }

  const catalogText = command("git", [
    "-C",
    repoRoot,
    "show",
    `${candidateCommit}:config/domain-core-build-profiles.json`,
  ]);
  const catalogDirectory = join(sourceDirectory, "candidate-catalog");
  mkdirSync(catalogDirectory, { recursive: true });
  const catalogPath = join(
    catalogDirectory,
    "domain-core-build-profiles.json",
  );
  writeFileSync(catalogPath, catalogText, { encoding: "utf8", mode: 0o600 });
  const catalog = loadDomainCoreBuildProfiles(catalogPath);
  const candidateIdentity = {
    candidateCommit: bundle.candidate.candidateCommit,
    coreVersion: bundle.candidate.coreVersion,
    abiVersion: bundle.candidate.abiVersion,
    sourceSha256: bundle.candidate.sourceSha256,
  };
  const rollbackProfile = resolveDomainCoreBuildProfile(
    catalog,
    DOMAIN_CORE_ROLLBACK_PROFILE,
    candidateIdentity,
  );
  writeFileSync(
    rollbackPath,
    `${JSON.stringify(rollbackProfile, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  exactFile(rollbackPath, "regenerated rollback artifact");
  if (sha256File(rollbackPath) !== restoredSha256) {
    throw new Error(
      `regenerated rollback artifact digest mismatch for ${candidateCommit}`,
    );
  }
  return { candidatePath, rollbackPath, bundlePath, source: "committed" };
}

function downloadOrMaterializeSourceArtifacts({
  repoRoot,
  candidateCommit,
  sourceRun,
  repository,
  sourceDirectory,
  command,
}) {
  try {
    downloadRunArtifact(
      sourceRun,
      repository,
      candidateArtifactName(candidateCommit, sourceRun),
      sourceDirectory,
      command,
    );
    downloadRunArtifact(
      sourceRun,
      repository,
      rollbackArtifactName(candidateCommit, sourceRun),
      sourceDirectory,
      command,
    );
    return { source: "actions" };
  } catch (error) {
    if (!isExpiredArtifactDownloadError(error)) throw error;
    return materializeCandidateBoundRollback({
      repoRoot,
      candidateCommit,
      sourceRun,
      sourceDirectory,
      command,
    });
  }
}

function promotionVerificationArguments(
  candidatePath,
  attestationPath,
  repository,
) {
  return [
    "attestation",
    "verify",
    candidatePath,
    "--bundle",
    attestationPath,
    "--repo",
    repository,
    "--signer-workflow",
    `${repository}/${DOMAIN_CORE_PROTECTED_SIGNER_WORKFLOW}`,
    "--source-ref",
    "refs/heads/main",
    "--cert-oidc-issuer",
    "https://token.actions.githubusercontent.com",
    "--deny-self-hosted-runners",
    "--predicate-type",
    DOMAIN_CORE_PROMOTION_PREDICATE_TYPE,
    "--format",
    "json",
  ];
}

export function run(
  argv,
  { command = createCommandRunner(), activationVerifier } = {},
) {
  const args = parseArguments(argv);
  const candidateCommit = args.get("--candidate-commit");
  if (!FULL_SHA.test(candidateCommit)) {
    throw new Error("candidate commit must be a full lowercase Git SHA-1");
  }
  const releaseCommit = args.get("--release-commit");
  if (!FULL_SHA.test(releaseCommit)) {
    throw new Error("release commit must be a full lowercase Git SHA-1");
  }
  const repository = args.get("--repository") ?? DOMAIN_CORE_REPOSITORY;
  if (repository !== DOMAIN_CORE_REPOSITORY) {
    throw new Error(`native releases must use ${DOMAIN_CORE_REPOSITORY}`);
  }
  const profileName = resolveNativeReleaseProfile({
    eventName: args.get("--event-name"),
    requestedProfile: args.get("--requested-profile"),
  });
  const outputDirectory = resolve(args.get("--output-dir"));
  mkdirSync(outputDirectory, { recursive: true });

  const sourceQuery = `/repos/${repository}/actions/workflows/${basename(DOMAIN_CORE_SOURCE_WORKFLOW)}/runs?event=push&status=completed&head_sha=${candidateCommit}&per_page=100`;
  const sourceRun = selectExactSourceRun(
    parseJson(
      command("gh", ["api", "--paginate", "--slurp", sourceQuery]),
      "deterministic source run lookup",
    ),
    candidateCommit,
  );

  const sourceDirectory = join(outputDirectory, "source");
  downloadOrMaterializeSourceArtifacts({
    repoRoot,
    candidateCommit,
    sourceRun,
    repository,
    sourceDirectory,
    command,
  });
  const candidatePath = exactFile(
    join(sourceDirectory, DOMAIN_CORE_CANDIDATE_FILE),
    "candidate bundle",
  );
  const candidateRollbackPath = exactFile(
    join(sourceDirectory, DOMAIN_CORE_ROLLBACK_FILE),
    "candidate rollback proof",
  );
  const bundle = parseJson(
    readFileSync(candidatePath, "utf8"),
    "candidate bundle",
  );
  const resolvedSource = resolveSourceCoordinates(bundle, candidateCommit);
  if (
    resolvedSource.sourceRun.runId !== sourceRun.runId ||
    resolvedSource.sourceRun.runAttempt !== sourceRun.runAttempt
  ) {
    throw new Error(
      "downloaded candidate bundle source coordinates do not match its artifact run",
    );
  }

  // Preserve the candidate-bound rollback proof byte-identically, then mint a
  // separate release-bound profile for verifyDomainCoreReleaseGate (which
  // requires {version,tag,commit} on the profile path while still hashing the
  // candidate proof against the protected bundle rollback digest).
  const releaseVersion = resolvedSource.candidate.coreVersion;
  const releaseTag = `v${releaseVersion}`;
  const releaseBoundRollbackPath = join(
    sourceDirectory,
    "domain-core-public-production-rollback-release.json",
  );
  const releaseBoundRollback = resolveDomainCoreBuildProfile(
    loadDomainCoreBuildProfiles(
      resolve(
        args.get("--profile-catalog") ??
          join(repoRoot, "config/domain-core-build-profiles.json"),
      ),
    ),
    DOMAIN_CORE_ROLLBACK_PROFILE,
    resolvedSource.candidate,
    {
      version: releaseVersion,
      tag: releaseTag,
      commit: releaseCommit,
    },
  );
  writeFileSync(
    releaseBoundRollbackPath,
    `${JSON.stringify(releaseBoundRollback, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  exactFile(releaseBoundRollbackPath, "release-bound rollback profile");
  const rollbackPath = candidateRollbackPath;

  const attestationDirectory = join(outputDirectory, "promotion");
  mkdirSync(attestationDirectory, { recursive: true });
  command(
    "gh",
    [
      "attestation",
      "download",
      candidatePath,
      "--repo",
      repository,
      "--predicate-type",
      DOMAIN_CORE_PROMOTION_PREDICATE_TYPE,
      "--limit",
      "30",
    ],
    { cwd: attestationDirectory },
  );
  const downloadedBundles = readdirSync(attestationDirectory)
    .filter((name) => /^sha256[:-][0-9a-f]{64}\.jsonl$/u.test(name))
    .map((name) => join(attestationDirectory, name));
  if (downloadedBundles.length !== 1) {
    throw new Error(
      `expected exactly one downloaded attestation bundle file, found ${downloadedBundles.length}`,
    );
  }
  const promotionPath = join(
    attestationDirectory,
    DOMAIN_CORE_PROMOTION_BUNDLE_FILE,
  );
  if (!existsSync(promotionPath))
    copyFileSync(downloadedBundles[0], promotionPath);
  exactFile(promotionPath, "protected promotion attestation bundle");
  if (sha256File(promotionPath) !== sha256File(downloadedBundles[0])) {
    throw new Error(
      "existing protected promotion bundle differs from downloaded bytes",
    );
  }

  const verified = parseJson(
    command(
      "gh",
      promotionVerificationArguments(candidatePath, promotionPath, repository),
    ),
    "protected promotion verifier",
  );
  const signerRun = resolveProtectedSignerCoordinates(
    verified,
    resolvedSource.candidate,
  );
  const signerMetadata = parseJson(
    command("gh", [
      "api",
      `/repos/${repository}/actions/runs/${signerRun.runId}/attempts/${signerRun.runAttempt}`,
    ]),
    "protected signer run lookup",
  );
  validateProtectedSignerRun(signerMetadata, signerRun, candidateCommit);

  const catalogPath = resolve(
    args.get("--profile-catalog") ??
      join(repoRoot, "config/domain-core-build-profiles.json"),
  );
  const catalog = loadDomainCoreBuildProfiles(catalogPath);
  const profile = resolveDomainCoreBuildProfile(
    catalog,
    profileName,
    resolvedSource.candidate,
  );
  validateResolvedProfile(profile, profileName, resolvedSource.candidate);
  const activationProfile = resolveDomainCoreBuildProfile(
    catalog,
    DOMAIN_CORE_PUBLIC_PROFILE,
    resolvedSource.candidate,
  );
  validateResolvedProfile(
    activationProfile,
    DOMAIN_CORE_PUBLIC_PROFILE,
    resolvedSource.candidate,
  );
  const activationPath = exactFile(
    resolve(args.get("--activation")),
    "canonical release activation",
  );
  const activationSelector = validateNativeActivationSelector(
    parseJson(
      readFileSync(activationPath, "utf8"),
      "canonical release activation",
    ),
    {
      candidate: resolvedSource.candidate,
      releaseCommit,
      profile: activationProfile,
      profileName: DOMAIN_CORE_PUBLIC_PROFILE,
    },
  );
  const profileSha256 = publicProfileSha256(
    profile,
    profileName,
    resolvedSource.candidate,
  );
  const gate = verifyDomainCoreReleaseGate({
    candidateBundlePath: candidatePath,
    promotionAttestationPath: promotionPath,
    rollbackArtifactPath: rollbackPath,
    candidateRollbackArtifactPath: candidateRollbackPath,
    rollbackProfilePath: releaseBoundRollbackPath,
    expectedCandidate: resolvedSource.candidate,
    expectedSourceRunId: sourceRun.runId,
    expectedSourceRunAttempt: sourceRun.runAttempt,
    protectedSignerRunId: signerRun.runId,
    protectedSignerRunAttempt: signerRun.runAttempt,
    expectedRollbackSha256: sha256File(rollbackPath),
    expectedReleaseCommit: releaseCommit,
    expectedReleaseVersion: releaseVersion,
    expectedReleaseTag: releaseTag,
    promotionVerifier: () => verified,
    activationVerifier,
  });

  const profilePath = join(
    outputDirectory,
    "domain-core-selected-public-profile.json",
  );
  const gatePath = join(
    outputDirectory,
    "domain-core-native-release-gate.json",
  );
  writeCreateOnly(profilePath, profile);
  writeCreateOnly(gatePath, gate);
  const result = {
    schemaVersion: 2,
    profileName,
    publicProfileSha256: profileSha256,
    candidate: resolvedSource.candidate,
    sourceRun,
    protectedSignerRun: signerRun,
    candidateBundlePath: candidatePath,
    promotionAttestationPath: promotionPath,
    rollbackArtifactPath: rollbackPath,
    candidateRollbackArtifactPath: candidateRollbackPath,
    releaseBoundRollbackProfilePath: releaseBoundRollbackPath,
    rollbackSha256: sha256File(rollbackPath),
    activation: activationSelector.activation,
    activationPath,
    profilePath,
    gatePath,
  };
  const coordinatesPath = join(
    outputDirectory,
    "domain-core-native-release-inputs.json",
  );
  writeCreateOnly(coordinatesPath, result);
  result.coordinatesPath = coordinatesPath;

  const githubOutput = args.get("--github-output");
  if (githubOutput) {
    appendFileSync(
      githubOutput,
      Object.entries({
        profile_name: profileName,
        public_profile_sha256: profileSha256,
        candidate_commit: resolvedSource.candidate.candidateCommit,
        activation_commit: releaseCommit,
        core_version: resolvedSource.candidate.coreVersion,
        abi_version: resolvedSource.candidate.abiVersion,
        source_sha256: resolvedSource.candidate.sourceSha256,
        source_run_id: sourceRun.runId,
        source_run_attempt: sourceRun.runAttempt,
        signer_run_id: signerRun.runId,
        signer_run_attempt: signerRun.runAttempt,
        rollback_sha256: result.rollbackSha256,
        coordinates_path: coordinatesPath,
      })
        .map(([key, value]) => `${key}=${value}`)
        .join("\n") + "\n",
      "utf8",
    );
  }
  process.stdout.write(`${JSON.stringify({ ok: true, ...result })}\n`);
  return result;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
