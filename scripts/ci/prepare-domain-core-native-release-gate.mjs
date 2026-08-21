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

import { validateDomainCoreActivation } from "../lib/domain-core-activation.mjs";
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
  inactiveCandidateIdentity,
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

// Every command this gate shells out to is a read-only GitHub or git query, so
// a transient GitHub 5xx must not invalidate an otherwise immutable candidate.
// Protected release workflows already encode that contract for `gh api` in
// `scripts/ci/gh-api-with-retry.sh`; this gate downloads artifacts from Node,
// so it carries the same bounded retry here. Permanent failures still fail on
// the first attempt — retrying cannot fix a bad token, a missing run, or a
// failed attestation verification, and an expired artifact must fail the
// Actions fallback in `materializeOrDownloadSourceArtifacts` immediately
// rather than burning the retry budget on a download that can never succeed.
export function isTransientCommandFailure(detail) {
  if (isExpiredArtifactDownloadError(detail)) return false;
  return (
    /HTTP (?:408|429|5\d{2})\b/u.test(detail) ||
    /no server is currently available/iu.test(detail) ||
    /\b(?:ECONNRESET|ECONNREFUSED|ETIMEDOUT|ENETUNREACH|EAI_AGAIN|EPIPE)\b/u.test(
      detail,
    ) ||
    /(?:connection reset|connection refused|i\/o timeout|unexpected EOF|TLS handshake timeout|temporary failure in name resolution|server error)/iu.test(
      detail,
    )
  );
}

// `Atomics.wait` is the only reliable synchronous sleep available to this
// synchronous `spawnSync` pipeline; tests inject their own `sleep` so the
// retry bound is exercised without real delay.
function sleepSync(milliseconds) {
  if (!(milliseconds > 0)) return;
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

export function createCommandRunner(runner = spawnSync, options = {}) {
  const attempts = options.attempts ?? 5;
  const baseSleepMs = options.baseSleepMs ?? 2_000;
  const wait = options.sleep ?? sleepSync;
  const log = options.log ?? ((message) => console.warn(message));
  return (command, args, commandOptions = {}) => {
    for (let attempt = 1; ; attempt += 1) {
      const result = runner(command, args, {
        encoding: "utf8",
        env: process.env,
        maxBuffer: 32 * 1024 * 1024,
        ...commandOptions,
      });
      if (result.error) throw result.error;
      if (result.status === 0) return result.stdout;
      const detail = (
        result.stderr ||
        result.stdout ||
        "command failed"
      ).trim();
      const failure = new Error(
        `${command} ${args.slice(0, 4).join(" ")} failed: ${detail}`,
      );
      if (attempt >= attempts || !isTransientCommandFailure(detail)) {
        throw failure;
      }
      const delayMs = baseSleepMs * attempt;
      log(
        `Transient ${command} failure (attempt ${attempt}/${attempts}), retrying in ${delayMs / 1000}s: ${failure.message}`,
      );
      wait(delayMs);
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

function materializeOrDownloadSourceArtifacts({
  repoRoot,
  candidateCommit,
  sourceRun,
  repository,
  sourceDirectory,
  command,
}) {
  try {
    return materializeCandidateBoundRollback({
      repoRoot,
      candidateCommit,
      sourceRun,
      sourceDirectory,
      command,
    });
  } catch (materializeError) {
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
    } catch (downloadError) {
      throw new Error(
        `${materializeError.message}; Actions artifact fallback also failed: ${downloadError.message}`,
      );
    }
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

function catalogPath(args) {
  return resolve(
    args.get("--profile-catalog") ??
      join(repoRoot, "config/domain-core-build-profiles.json"),
  );
}

// Derive the canonical release-bound empty C=P selector straight from the
// release checkout. validateDomainCoreActivation re-reads the working-tree
// build profiles and throws when any public-production domain is still
// "rust", so an active release can never reach the legacy lane through here.
function defaultReleaseActivationResolver(releaseCommit) {
  return {
    ...validateDomainCoreActivation({
      repoRoot,
      candidateCommit: releaseCommit,
      activationCommit: releaseCommit,
      requireHead: false,
    }),
    domains: [],
  };
}

// Rust is not activated for the public profile: there is no protected
// candidate to download, no promotion attestation to verify, and no protected
// signer run to pin, so demanding any of them would block every legacy
// release. Bind the release to its own commit instead and ship the legacy
// closure. Both the authority-derived resolver verdict and this release-bound
// selector must agree that Rust is off, and each fails closed on its own.
function prepareLegacyNativeRelease({
  args,
  activationPath,
  candidateCommit,
  releaseCommit,
  profileName,
  outputDirectory,
  resolvedActivation,
  releaseActivationResolver,
}) {
  if (candidateCommit !== resolvedActivation.candidateCommit) {
    throw new Error(
      "inactive release gate candidate commit must match the resolved activation",
    );
  }
  const activation = releaseActivationResolver(releaseCommit);
  if (activation.active !== false) {
    throw new Error("inactive release gate resolved an active Rust activation");
  }
  const candidate = inactiveCandidateIdentity(activation);
  const catalog = loadDomainCoreBuildProfiles(catalogPath(args));
  const profile = resolveDomainCoreBuildProfile(catalog, profileName, candidate);
  validateResolvedProfile(profile, profileName, candidate);
  const activationProfile = resolveDomainCoreBuildProfile(
    catalog,
    DOMAIN_CORE_PUBLIC_PROFILE,
    candidate,
  );
  validateResolvedProfile(
    activationProfile,
    DOMAIN_CORE_PUBLIC_PROFILE,
    candidate,
  );
  validateNativeActivationSelector(activation, {
    candidate,
    releaseCommit,
    profile: activationProfile,
    profileName: DOMAIN_CORE_PUBLIC_PROFILE,
  });
  const profileSha256 = publicProfileSha256(profile, profileName, candidate);
  const profilePath = join(
    outputDirectory,
    "domain-core-selected-public-profile.json",
  );
  const gatePath = join(
    outputDirectory,
    "domain-core-native-release-gate.json",
  );
  // The resolver binds P to the authority commit that last set the modes,
  // which is right for its own drift check but is not what release consumers
  // verify against. Replace it in place with the release-bound selector this
  // lane just proved, so the uploaded artifact is the one downstream
  // validateNativeActivationSelector calls accept.
  writeFileSync(activationPath, `${JSON.stringify(activation, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  writeCreateOnly(profilePath, profile);
  writeCreateOnly(gatePath, {
    schemaVersion: 2,
    rustActive: false,
    profileName,
    publicProfileSha256: profileSha256,
    candidate,
    releaseCommit,
    resolvedActivationCommit: resolvedActivation.activationCommit,
  });
  const result = {
    schemaVersion: 2,
    rustActive: false,
    profileName,
    publicProfileSha256: profileSha256,
    candidate,
    activation,
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
        rust_active: "false",
        profile_name: profileName,
        public_profile_sha256: profileSha256,
        candidate_commit: candidate.candidateCommit,
        activation_commit: releaseCommit,
        core_version: candidate.coreVersion,
        abi_version: candidate.abiVersion,
        source_sha256: candidate.sourceSha256,
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

export function run(
  argv,
  {
    command = createCommandRunner(),
    activationVerifier,
    releaseActivationResolver = defaultReleaseActivationResolver,
  } = {},
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

  const activationPath = exactFile(
    resolve(args.get("--activation")),
    "canonical release activation",
  );
  const resolvedActivation = parseJson(
    readFileSync(activationPath, "utf8"),
    "canonical release activation",
  );
  if (resolvedActivation.active === false) {
    return prepareLegacyNativeRelease({
      args,
      activationPath,
      candidateCommit,
      releaseCommit,
      profileName,
      outputDirectory,
      resolvedActivation,
      releaseActivationResolver,
    });
  }

  const sourceQuery = `/repos/${repository}/actions/workflows/${basename(DOMAIN_CORE_SOURCE_WORKFLOW)}/runs?event=push&status=completed&head_sha=${candidateCommit}&per_page=100`;
  const sourceRun = selectExactSourceRun(
    parseJson(
      command("gh", ["api", "--paginate", "--slurp", sourceQuery]),
      "deterministic source run lookup",
    ),
    candidateCommit,
  );

  const sourceDirectory = join(outputDirectory, "source");
  materializeOrDownloadSourceArtifacts({
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
    loadDomainCoreBuildProfiles(catalogPath(args)),
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

  const catalog = loadDomainCoreBuildProfiles(catalogPath(args));
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
  const activationSelector = validateNativeActivationSelector(
    resolvedActivation,
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
    rustActive: true,
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
        rust_active: "true",
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
