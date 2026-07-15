#!/usr/bin/env node

import { randomUUID } from "node:crypto";
import {
  linkSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  buildPromotionBinding,
  DOMAIN_CORE_RELEASE_PREDICATE_TYPE,
  expectedArtifactName,
  exactObject,
  regularFile,
  sha256File,
  validateCandidateBundle,
  validatePublicProfileSha256,
  validateReleaseCoordinates,
  validateRollbackArtifact,
  verifyProtectedPromotionAttestation,
} from "../lib/domain-core-release-evidence.mjs";

const POSITIVE_INTEGER = /^[1-9]\d*$/u;
const FULL_SHA = /^[0-9a-f]{40}$/u;
const SHA256 = /^[0-9a-f]{64}$/u;
const DEPLOYMENT_CONSUMERS = new Set(["console", "functions"]);

function readJson(path, label) {
  try {
    return JSON.parse(readFileSync(resolve(path), "utf8"));
  } catch (error) {
    throw new Error(`unable to read ${label}: ${error.message}`);
  }
}

function parseArguments(argv) {
  const allowed = new Set([
    "--consumer",
    "--domain",
    "--artifact-kind",
    "--target",
    "--version",
    "--tag",
    "--commit",
    "--artifact",
    "--predicate",
    "--public-profile-sha256",
    "--activation",
    "--candidate-bundle",
    "--promotion-attestation",
    "--protected-signer-run-id",
    "--protected-signer-run-attempt",
    "--rollback-artifact",
    "--deployment",
  ]);
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag))
      throw new Error(`unknown argument: ${String(flag)}`);
    if (!value || value.startsWith("--"))
      throw new Error(`${flag} requires a value`);
    if (Object.hasOwn(result, flag))
      throw new Error(`duplicate argument: ${flag}`);
    result[flag] = value;
  }
  const required = [...allowed].filter((flag) => flag !== "--deployment");
  for (const flag of required) {
    if (!Object.hasOwn(result, flag)) throw new Error(`${flag} is required`);
  }
  return result;
}

function positiveInteger(value, label) {
  if (!POSITIVE_INTEGER.test(value))
    throw new Error(`${label} must be a positive integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed))
    throw new Error(`${label} exceeds the safe integer range`);
  return parsed;
}

function atomicWrite(path, contents) {
  const destination = resolve(path);
  mkdirSync(dirname(destination), { recursive: true });
  if (lstatExists(destination)) {
    const stat = lstatSync(destination);
    if (!stat.isFile() || stat.isSymbolicLink()) {
      throw new Error(`refusing to replace non-regular output: ${destination}`);
    }
    if (readFileSync(destination, "utf8") === contents) return;
    throw new Error(
      `refusing to replace non-identical immutable output: ${destination}`,
    );
  }
  const temporary = `${destination}.tmp-${process.pid}-${randomUUID()}`;
  writeFileSync(temporary, contents, {
    encoding: "utf8",
    flag: "wx",
    mode: 0o600,
  });
  try {
    linkSync(temporary, destination);
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    const stat = lstatSync(destination);
    if (
      !stat.isFile() ||
      stat.isSymbolicLink() ||
      readFileSync(destination, "utf8") !== contents
    ) {
      throw new Error(
        `refusing to replace non-identical immutable output: ${destination}`,
      );
    }
  } finally {
    rmSync(temporary, { force: true });
  }
}

function lstatExists(path) {
  try {
    lstatSync(path);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

function validateProviderCoordinates(raw, consumer, artifactSha256) {
  if (consumer === "console") {
    const coordinates = exactObject(
      raw,
      ["sites"],
      "Hosting provider coordinates",
    );
    const expected = new Map([
      ["marketing", "burnbar"],
      ["console", "burnbar-console"],
    ]);
    if (
      !Array.isArray(coordinates.sites) ||
      coordinates.sites.length !== expected.size
    ) {
      throw new Error(
        "Hosting provider coordinates must contain both exact production sites",
      );
    }
    const seen = new Set();
    for (const rawSite of coordinates.sites) {
      const site = exactObject(
        rawSite,
        ["target", "site", "versionName", "releaseName"],
        "Hosting site coordinate",
      );
      if (
        seen.has(site.target) ||
        expected.get(site.target) !== site.site ||
        typeof site.versionName !== "string" ||
        !site.versionName.startsWith(`sites/${site.site}/versions/`) ||
        typeof site.releaseName !== "string" ||
        !site.releaseName.startsWith(
          `sites/${site.site}/channels/live/releases/`,
        )
      ) {
        throw new Error(
          "Hosting provider coordinate is not an exact immutable production release",
        );
      }
      seen.add(site.target);
    }
    if ([...expected.keys()].some((target) => !seen.has(target))) {
      throw new Error("Hosting provider coordinates omit a production target");
    }
    return;
  }

  const coordinates = exactObject(
    raw,
    ["buildArtifactSha256", "sharedSource", "targets"],
    "Functions provider coordinates",
  );
  const source = exactObject(
    coordinates.sharedSource,
    ["bucket", "object", "generation"],
    "Functions provider source",
  );
  if (
    coordinates.buildArtifactSha256 !== artifactSha256 ||
    typeof source.bucket !== "string" ||
    source.bucket.length === 0 ||
    typeof source.object !== "string" ||
    source.object.length === 0 ||
    typeof source.generation !== "string" ||
    !/^[1-9]\d*$/u.test(source.generation) ||
    !Array.isArray(coordinates.targets) ||
    coordinates.targets.length === 0
  ) {
    throw new Error(
      "Functions provider coordinates do not bind one immutable build artifact",
    );
  }
  const seen = new Set();
  for (const rawTarget of coordinates.targets) {
    const target = exactObject(
      rawTarget,
      ["target", "function", "build", "service", "revision"],
      "Functions target coordinate",
    );
    if (
      !/^[A-Za-z][A-Za-z0-9]*$/u.test(target.target) ||
      seen.has(target.target) ||
      [target.function, target.build, target.service, target.revision].some(
        (value) => typeof value !== "string" || value.length === 0,
      )
    ) {
      throw new Error(
        "Functions provider coordinates contain an invalid or duplicate target",
      );
    }
    seen.add(target.target);
  }
}

function validateDeployment(raw, consumer, release) {
  const value = exactObject(
    raw,
    [
      "provider",
      "project",
      "environment",
      "status",
      "healthChecks",
      "deployedArtifact",
      "providerCoordinates",
      "deployRun",
      "healthArtifactSha256",
    ],
    "deployment evidence",
  );
  if (value.status !== "healthy")
    throw new Error("deployment status must be healthy");
  if (typeof value.provider !== "string" || value.provider.length === 0) {
    throw new Error("deployment provider must be nonempty");
  }
  if (typeof value.project !== "string" || value.project.length === 0) {
    throw new Error("deployment project must be nonempty");
  }
  if (typeof value.environment !== "string" || value.environment.length === 0) {
    throw new Error("deployment environment must be nonempty");
  }
  if (
    !Array.isArray(value.healthChecks) ||
    value.healthChecks.length === 0 ||
    value.healthChecks.some(
      (item) => typeof item !== "string" || item.length === 0,
    ) ||
    new Set(value.healthChecks).size !== value.healthChecks.length
  ) {
    throw new Error(
      "deployment health checks must be a unique nonempty string array",
    );
  }
  const deployedArtifact = exactObject(
    value.deployedArtifact,
    ["fileName", "sha256"],
    "deployment evidence deployedArtifact",
  );
  if (
    typeof deployedArtifact.fileName !== "string" ||
    deployedArtifact.fileName.length === 0
  ) {
    throw new Error("deployed artifact filename must be nonempty");
  }
  if (!/^[0-9a-f]{64}$/u.test(deployedArtifact.sha256)) {
    throw new Error("deployed artifact SHA-256 must be lowercase SHA-256");
  }
  validateProviderCoordinates(
    value.providerCoordinates,
    consumer,
    deployedArtifact.sha256,
  );
  const expectedProvider =
    consumer === "console" ? "firebase-hosting" : "firebase-functions";
  if (value.provider !== expectedProvider) {
    throw new Error(
      `${consumer} deployment provider must be ${expectedProvider}`,
    );
  }
  const deployRun = exactObject(
    value.deployRun,
    [
      "repository",
      "workflowPath",
      "runId",
      "runAttempt",
      "event",
      "ref",
      "headSha",
      "jobSetSha256",
    ],
    "deployment evidence deployRun",
  );
  const expectedWorkflow =
    consumer === "console"
      ? ".github/workflows/deploy-hosting.yml"
      : ".github/workflows/deploy-production.yml";
  if (
    deployRun.repository !== "Imagine-That-Ai/BurnBar" ||
    deployRun.workflowPath !== expectedWorkflow ||
    !Number.isSafeInteger(deployRun.runId) ||
    deployRun.runId < 1 ||
    !Number.isSafeInteger(deployRun.runAttempt) ||
    deployRun.runAttempt < 1 ||
    !new Set(["push", "workflow_dispatch"]).has(deployRun.event) ||
    deployRun.ref !== `refs/tags/${release.tag}` ||
    !FULL_SHA.test(deployRun.headSha) ||
    deployRun.headSha !== release.commit ||
    !SHA256.test(deployRun.jobSetSha256)
  ) {
    throw new Error("deployment run does not bind the exact release attempt");
  }
  if (!SHA256.test(value.healthArtifactSha256)) {
    throw new Error("deployment health artifact must be bound by SHA-256");
  }
  return structuredClone(value);
}

export function buildReleaseEvidence({
  consumer,
  domain,
  artifactKind,
  target,
  version,
  tag,
  commit,
  artifactPath,
  candidateBundlePath,
  promotionAttestationPath,
  protectedSignerRunId,
  protectedSignerRunAttempt,
  rollbackArtifactPath,
  publicProfileSha256,
  activation,
  deployment,
  promotionVerifier = verifyProtectedPromotionAttestation,
}) {
  const candidateBundle = readJson(candidateBundlePath, "candidate bundle");
  const { candidate, sourceRun } = validateCandidateBundle(candidateBundle);
  const contract = validateReleaseCoordinates({
    consumer,
    domain,
    artifactKind,
    target,
    version,
    tag,
    commit,
    candidate,
    activation,
  });
  promotionVerifier({
    candidateBundlePath,
    promotionAttestationPath,
    signerRunId: protectedSignerRunId,
    signerRunAttempt: protectedSignerRunAttempt,
  });
  const promotionProof = buildPromotionBinding({
    candidateBundlePath,
    promotionAttestationPath,
    signerRunId: protectedSignerRunId,
    signerRunAttempt: protectedSignerRunAttempt,
  });
  const rollbackPath = regularFile(rollbackArtifactPath, "rollback artifact");
  validateRollbackArtifact(
    readJson(rollbackPath, "rollback artifact"),
    candidate,
  );
  const rollbackArtifact = {
    fileName: basename(rollbackPath),
    sha256: sha256File(rollbackPath),
    candidate,
  };
  const release = {
    version,
    tag,
    commit,
    publicProfileSha256: validatePublicProfileSha256(publicProfileSha256),
  };
  const publicProfile = {
    profile: "public-production",
    domain,
    mode: "rust",
    sha256: release.publicProfileSha256,
  };
  const common = {
    schemaVersion: 2,
    consumer,
    domain,
    artifactKind,
    target,
    candidate,
    sourceRun,
    promotionProof,
    rollbackArtifact,
    activation: contract.activation,
    publicProfile,
    release,
  };

  let deploymentReceipt;
  if (DEPLOYMENT_CONSUMERS.has(consumer)) {
    if (!deployment)
      throw new Error(`${consumer} requires deployment evidence`);
    if (basename(artifactPath) !== contract.fileName(version)) {
      throw new Error(
        `deployment receipt must be named ${contract.fileName(version)}`,
      );
    }
    deploymentReceipt = {
      ...common,
      deployment: validateDeployment(deployment, consumer, release),
    };
  } else {
    if (deployment)
      throw new Error(`${consumer} must not provide deployment evidence`);
    const nativeArtifact = regularFile(artifactPath, "release artifact");
    if (basename(nativeArtifact) !== expectedArtifactName(consumer, version)) {
      throw new Error(
        `release artifact must be named ${expectedArtifactName(consumer, version)}`,
      );
    }
  }
  return { common, deploymentReceipt };
}

export function run(argv, { promotionVerifier } = {}) {
  const args = parseArguments(argv);
  const artifactPath = resolve(args["--artifact"]);
  const deployment = args["--deployment"]
    ? readJson(args["--deployment"], "deployment evidence")
    : undefined;
  const { common, deploymentReceipt } = buildReleaseEvidence({
    consumer: args["--consumer"],
    domain: args["--domain"],
    artifactKind: args["--artifact-kind"],
    target: args["--target"],
    version: args["--version"],
    tag: args["--tag"],
    commit: args["--commit"],
    artifactPath,
    candidateBundlePath: resolve(args["--candidate-bundle"]),
    promotionAttestationPath: resolve(args["--promotion-attestation"]),
    protectedSignerRunId: positiveInteger(
      args["--protected-signer-run-id"],
      "protected signer run ID",
    ),
    protectedSignerRunAttempt: positiveInteger(
      args["--protected-signer-run-attempt"],
      "protected signer run attempt",
    ),
    rollbackArtifactPath: resolve(args["--rollback-artifact"]),
    publicProfileSha256: args["--public-profile-sha256"],
    activation: readJson(args["--activation"], "release activation"),
    deployment,
    promotionVerifier,
  });
  if (deploymentReceipt) {
    atomicWrite(
      artifactPath,
      `${JSON.stringify(deploymentReceipt, null, 2)}\n`,
    );
  }
  const artifact = regularFile(artifactPath, "release evidence subject");
  const predicate = {
    ...common,
    predicateType: DOMAIN_CORE_RELEASE_PREDICATE_TYPE,
    artifact: { fileName: basename(artifact), sha256: sha256File(artifact) },
  };
  atomicWrite(args["--predicate"], `${JSON.stringify(predicate, null, 2)}\n`);
  process.stdout.write(
    `${JSON.stringify({
      schemaVersion: 2,
      artifactPath,
      artifactSha256: predicate.artifact.sha256,
      predicatePath: resolve(args["--predicate"]),
      candidate: predicate.candidate,
    })}\n`,
  );
  return { predicate, deploymentReceipt };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
