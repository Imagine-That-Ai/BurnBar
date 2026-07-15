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

export function validateProtectedSignerRun(raw, coordinates, candidateCommit) {
  const expectedPath = `${DOMAIN_CORE_PROTECTED_SIGNER_WORKFLOW}@refs/heads/main`;
  if (
    raw?.id !== coordinates.runId ||
    raw?.run_attempt !== coordinates.runAttempt ||
    raw?.event !== "workflow_dispatch" ||
    raw?.status !== "completed" ||
    raw?.conclusion !== "success" ||
    raw?.head_branch !== "main" ||
    raw?.path !== expectedPath
  ) {
    throw new Error(
      `protected signer run does not match the exact successful main workflow for ${candidateCommit}`,
    );
  }
  return coordinates;
}

export function createCommandRunner(runner = spawnSync) {
  return (command, args, options = {}) => {
    const result = runner(command, args, {
      encoding: "utf8",
      env: process.env,
      maxBuffer: 32 * 1024 * 1024,
      ...options,
    });
    if (result.error) throw result.error;
    if (result.status !== 0) {
      const detail = (
        result.stderr ||
        result.stdout ||
        "command failed"
      ).trim();
      throw new Error(
        `${command} ${args.slice(0, 4).join(" ")} failed: ${detail}`,
      );
    }
    return result.stdout;
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
  const candidatePath = exactFile(
    join(sourceDirectory, DOMAIN_CORE_CANDIDATE_FILE),
    "candidate bundle",
  );
  const rollbackPath = exactFile(
    join(sourceDirectory, DOMAIN_CORE_ROLLBACK_FILE),
    "rollback artifact",
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
    expectedCandidate: resolvedSource.candidate,
    expectedSourceRunId: sourceRun.runId,
    expectedSourceRunAttempt: sourceRun.runAttempt,
    protectedSignerRunId: signerRun.runId,
    protectedSignerRunAttempt: signerRun.runAttempt,
    expectedRollbackSha256: sha256File(rollbackPath),
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
