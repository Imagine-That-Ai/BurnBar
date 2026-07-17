#!/usr/bin/env node

import { createHash, randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { linkSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, resolve } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { fileURLToPath } from "node:url";
import { validateDomainCoreActivation } from "../lib/domain-core-activation.mjs";
import {
  readRegularFileIfExistsSync,
  readRegularFileSync,
} from "../lib/atomic-regular-file.mjs";

import {
  buildPromotionBinding,
  canonicalSha256,
  DOMAIN_CORE_RELEASE_PREDICATE_TYPE,
  expectedArtifactName,
  exactObject,
  regularFile,
  validateCandidateBundle,
  validatePublicProfileSha256,
  validateReleaseCoordinates,
  validateRollbackArtifact,
  verifyProtectedPromotionAttestation,
} from "../lib/domain-core-release-evidence.mjs";
import { validateAndroidUniversalManifest } from "./verify-domain-core-android-universal-artifact.mjs";

const POSITIVE_INTEGER = /^[1-9]\d*$/u;
const FULL_SHA = /^[0-9a-f]{40}$/u;
const SHA256 = /^[0-9a-f]{64}$/u;
const DEPLOYMENT_CONSUMERS = new Set(["console", "functions"]);

function readJson(path, label) {
  try {
    return JSON.parse(
      readRegularFileSync(resolve(path), { encoding: "utf8", label }),
    );
  } catch (error) {
    throw new Error(`unable to read ${label}: ${error.message}`);
  }
}

function sha256RegularFile(path, label) {
  return createHash("sha256")
    .update(readRegularFileSync(resolve(path), { label }))
    .digest("hex");
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
    "--candidate-rollback-profile",
    "--profile-name",
    "--rollback-profile",
    "--app-store-connect-receipt",
    "--deployment",
    "--android-abi-manifest",
    "--legacy-absence-scan",
    "--legacy-absence-root",
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
  const required = [...allowed].filter(
    (flag) =>
      flag !== "--deployment" &&
      flag !== "--android-abi-manifest" &&
      flag !== "--rollback-profile" &&
      flag !== "--candidate-rollback-profile" &&
      flag !== "--profile-name" &&
      flag !== "--app-store-connect-receipt" &&
      flag !== "--legacy-absence-scan" &&
      flag !== "--legacy-absence-root",
  );
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
  let existing;
  try {
    existing = readRegularFileIfExistsSync(destination, {
      encoding: "utf8",
      label: "immutable output",
    });
  } catch {
    throw new Error(`refusing to replace non-regular output: ${destination}`);
  }
  if (existing !== undefined) {
    if (existing === contents) return;
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
    let concurrent;
    try {
      concurrent = readRegularFileSync(destination, {
        encoding: "utf8",
        label: "immutable output",
      });
    } catch {
      throw new Error(`refusing to replace non-regular output: ${destination}`);
    }
    if (concurrent !== contents) {
      throw new Error(
        `refusing to replace non-identical immutable output: ${destination}`,
      );
    }
  } finally {
    rmSync(temporary, { force: true });
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
  rollbackProfilePath,
  candidateRollbackProfilePath,
  profileName = "public-production",
  appStoreConnectReceipt,
  publicProfileSha256,
  activation: suppliedActivation,
  deployment,
  androidAbiManifest,
  androidAbiManifestSha256,
  promotionVerifier = verifyProtectedPromotionAttestation,
  activationVerifier = validateDomainCoreActivation,
}) {
  const candidateBundle = readJson(candidateBundlePath, "candidate bundle");
  const { candidate, sourceRun, restoredArtifactSha256 } =
    validateCandidateBundle(candidateBundle);
  if (
    !["public-production", "public-production-rollback"].includes(profileName)
  ) {
    throw new Error("release evidence profile name is not governed");
  }
  if (
    profileName === "public-production-rollback" &&
    !DEPLOYMENT_CONSUMERS.has(consumer)
  ) {
    throw new Error("rollback completion evidence requires an actual deployment consumer");
  }
  const absenceAuthority =
    profileName === "public-production-rollback"
      ? null
      : JSON.parse(
          execFileSync(
            "python3",
            [
              "scripts/ci/inspect-domain-core-release-legacy-absence.py",
              "--consumer",
              consumer,
              "--domain",
              domain,
              "--commit",
              commit,
              "--candidate-json",
              JSON.stringify(candidate),
            ],
            { encoding: "utf8" },
          ),
        );
  const rawActivation =
    absenceAuthority?.activation ??
    activationVerifier({
      repoRoot: resolve(dirname(fileURLToPath(import.meta.url)), "../.."),
      candidateCommit: candidate.candidateCommit,
      activationCommit: commit,
    });
  const activation = Object.fromEntries(
    [
      "candidateCommit",
      "activationCommit",
      "coreVersion",
      "abiVersion",
      "sourceSha256",
      "changedPathsSha256",
    ].map((field) => [field, rawActivation[field]]),
  );
  if (!isDeepStrictEqual(suppliedActivation, activation)) {
    throw new Error(
      "supplied release activation does not match repository-derived activation",
    );
  }
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
  const rollbackPath = regularFile(rollbackArtifactPath, "retained rollback artifact");
  const restoredRollbackPath = regularFile(
    rollbackProfilePath ?? rollbackPath,
    "release-bound rollback profile",
  );
  const candidateRollbackPath = regularFile(
    candidateRollbackProfilePath ?? restoredRollbackPath,
    "candidate rollback proof",
  );
  validateRollbackArtifact(
    readJson(restoredRollbackPath, "release-bound rollback profile"),
    candidate,
    { version, tag, commit },
  );
  validateRollbackArtifact(
    readJson(candidateRollbackPath, "candidate rollback proof"),
    candidate,
  );
  if (sha256RegularFile(candidateRollbackPath, "candidate rollback proof") !== restoredArtifactSha256) {
    throw new Error(
      "release evidence restored rollback artifact digest does not match the protected candidate bundle rollback proof",
    );
  }
  const rollbackArtifact = {
    fileName: basename(rollbackPath),
    sha256: sha256RegularFile(rollbackPath, "retained rollback artifact"),
    candidate,
    activation,
  };
  const release = {
    version,
    tag,
    commit,
    publicProfileSha256: validatePublicProfileSha256(publicProfileSha256),
  };
  const publicProfile = {
    profile: profileName,
    domain,
    mode: profileName === "public-production-rollback" ? "legacy" : "rust",
    sha256: release.publicProfileSha256,
  };
  if (
    profileName === "public-production-rollback" &&
    publicProfile.sha256 !==
      sha256RegularFile(restoredRollbackPath, "release-bound rollback profile")
  ) {
    throw new Error(
      "rollback completion profile digest does not match the exact retained rollback profile",
    );
  }
  const common = {
    schemaVersion: 2,
    consumer,
    domain,
    artifactKind,
    target,
    publicProfile,
    candidate,
    activation,
    sourceRun,
    promotionProof,
    rollbackArtifact,
    release,
  };
  if (absenceAuthority !== null) {
    common.legacyAbsence = absenceAuthority.absence;
  }
  if (consumer === "ios") {
    const receipt = exactObject(
      appStoreConnectReceipt,
      [
        "schemaVersion",
        "status",
        "processedStatus",
        "deliveryId",
        "archiveSha256",
        "ipaSha256",
        "uploadResponseSha256",
        "statusResponseSha256",
        "release",
        "candidate",
        "activation",
        "loadedRustIdentity",
      ],
      "App Store Connect receipt",
    );
    const loaded = exactObject(
      receipt.loadedRustIdentity,
      [
        "schemaVersion",
        "verificationKind",
        "bundleId",
        "version",
        "buildNumber",
        "executable",
        "architectures",
        "executableSha256",
        "identitySectionSha256",
        "identitySymbols",
        "candidate",
        "observed",
      ],
      "loaded Rust slice identity",
    );
    const expectedSymbols = [
      "OPENBURNBAR_DOMAIN_CORE_IDENTITY_V1",
      "uniffi_openburnbar_domain_ffi_fn_func_domain_core_abi_version",
      "uniffi_openburnbar_domain_ffi_fn_func_domain_core_candidate_commit",
      "uniffi_openburnbar_domain_ffi_fn_func_domain_core_source_fingerprint",
      "uniffi_openburnbar_domain_ffi_fn_func_domain_core_version",
    ];
    if (
      receipt.schemaVersion !== 1 ||
      receipt.status !== "processed" ||
      ![
        "complete",
        "completed",
        "processed",
        "processing complete",
        "success",
        "succeeded",
      ].includes(receipt.processedStatus) ||
      typeof receipt.deliveryId !== "string" ||
      receipt.deliveryId.length === 0 ||
      receipt.archiveSha256 !== sha256RegularFile(artifactPath, "iOS release archive") ||
      !SHA256.test(receipt.ipaSha256) ||
      !SHA256.test(receipt.uploadResponseSha256) ||
      !SHA256.test(receipt.statusResponseSha256) ||
      !isDeepStrictEqual(receipt.release, {
        version: release.version,
        tag: release.tag,
        commit: release.commit,
      }) ||
      !isDeepStrictEqual(receipt.candidate, candidate) ||
      !isDeepStrictEqual(receipt.activation, activation) ||
      loaded.schemaVersion !== 1 ||
      loaded.verificationKind !== "ios-loaded-rust-slice-identity" ||
      typeof loaded.bundleId !== "string" ||
      loaded.bundleId.length === 0 ||
      loaded.version !== release.version ||
      typeof loaded.buildNumber !== "string" ||
      loaded.buildNumber.length === 0 ||
      loaded.executable !== "OpenBurnBarMobile" ||
      !isDeepStrictEqual(loaded.architectures, ["arm64"]) ||
      !SHA256.test(loaded.executableSha256) ||
      !SHA256.test(loaded.identitySectionSha256) ||
      !isDeepStrictEqual(loaded.identitySymbols, expectedSymbols) ||
      !isDeepStrictEqual(loaded.candidate, candidate) ||
      !isDeepStrictEqual(loaded.observed, candidate)
    ) {
      throw new Error(
        "App Store Connect receipt must bind the processed IPA, archive, activation, and loaded Rust slice",
      );
    }
    common.appStoreConnectReceipt = structuredClone(receipt);
  } else if (appStoreConnectReceipt !== undefined) {
    throw new Error(
      `${consumer} must not provide an App Store Connect receipt`,
    );
  }
  if (consumer === "android") {
    if (!androidAbiManifest) {
      throw new Error("android requires a universal ABI manifest");
    }
    if (!/^[0-9a-f]{64}$/u.test(androidAbiManifestSha256)) {
      throw new Error("android universal ABI manifest SHA-256 is invalid");
    }
    common.androidUniversal = {
      manifestSha256: androidAbiManifestSha256,
      ...validateAndroidUniversalManifest(androidAbiManifest),
    };
  } else if (androidAbiManifest) {
    throw new Error(`${consumer} must not provide an Android ABI manifest`);
  }

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

export function run(argv, { promotionVerifier, activationVerifier } = {}) {
  const args = parseArguments(argv);
  const artifactPath = resolve(args["--artifact"]);
  const deployment = args["--deployment"]
    ? readJson(args["--deployment"], "deployment evidence")
    : undefined;
  const androidAbiManifest = args["--android-abi-manifest"]
    ? readJson(args["--android-abi-manifest"], "Android universal ABI manifest")
    : undefined;
  const androidAbiManifestPath = args["--android-abi-manifest"]
    ? resolve(args["--android-abi-manifest"])
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
    rollbackProfilePath: args["--rollback-profile"]
      ? resolve(args["--rollback-profile"])
      : undefined,
    candidateRollbackProfilePath: args["--candidate-rollback-profile"]
      ? resolve(args["--candidate-rollback-profile"])
      : undefined,
    profileName: args["--profile-name"] ?? "public-production",
    appStoreConnectReceipt: args["--app-store-connect-receipt"]
      ? readJson(
          args["--app-store-connect-receipt"],
          "App Store Connect receipt",
        )
      : undefined,
    publicProfileSha256: args["--public-profile-sha256"],
    activation: readJson(args["--activation"], "release activation"),
    deployment,
    androidAbiManifest,
    androidAbiManifestSha256: androidAbiManifestPath
      ? sha256RegularFile(
          androidAbiManifestPath,
          "Android universal ABI manifest",
        )
      : undefined,
    promotionVerifier,
    activationVerifier,
  });
  if (deploymentReceipt) {
    const receiptBytes = `${JSON.stringify(deploymentReceipt, null, 2)}\n`;
    atomicWrite(artifactPath, receiptBytes);
    const writtenBytes = readRegularFileSync(artifactPath, {
      encoding: "utf8",
      label: "deployment receipt",
    });
    if (writtenBytes !== receiptBytes) {
      throw new Error(
        "deployment receipt was altered after writing; refusing to bind modified bytes",
      );
    }
  }
  const artifact = regularFile(artifactPath, "release evidence subject");
  const scanPath = args["--legacy-absence-scan"]
    ? resolve(args["--legacy-absence-scan"])
    : resolve(
        dirname(args["--predicate"]),
        `${basename(args["--predicate"])}.legacy-scan.json`,
      );
  if (common.legacyAbsence) {
    if (!args["--legacy-absence-scan"]) {
      const scanArgs = [
        "scripts/ci/scan-domain-core-final-artifact-legacy.py",
        "--consumer",
        args["--consumer"],
        "--artifact",
        artifact,
        "--output",
        scanPath,
      ];
      if (args["--legacy-absence-root"]) {
        scanArgs.push(
          "--extracted-root",
          resolve(args["--legacy-absence-root"]),
        );
      }
      execFileSync("python3", scanArgs, { stdio: "inherit" });
    }
    const report = exactObject(
      readJson(scanPath, "final-artifact legacy-absence scan"),
      [
        "schemaVersion",
        "consumer",
        "artifact",
        "ruleSetSha256",
        "inspectedMembers",
        "matches",
        "result",
      ],
      "final-artifact legacy-absence scan",
    );
    if (
      report.schemaVersion !== 1 ||
      report.consumer !== args["--consumer"] ||
      report.result !== "absent" ||
      !Array.isArray(report.matches) ||
      report.matches.length !== 0 ||
      !Array.isArray(report.inspectedMembers) ||
      report.inspectedMembers.length === 0 ||
      report.artifact?.sha256 !== sha256RegularFile(artifact, "final-artifact legacy-absence scan subject") ||
      !SHA256.test(report.ruleSetSha256)
    ) {
      throw new Error(
        "final-artifact legacy-absence scan does not bind exact clean release bytes",
      );
    }
    common.legacyAbsence.artifactScan = {
      reportSha256: canonicalSha256(report),
      artifactSha256: report.artifact.sha256,
      ruleSetSha256: report.ruleSetSha256,
      inspectedMemberCount: report.inspectedMembers.length,
      report,
    };
  } else if (args["--legacy-absence-scan"]) {
    throw new Error("release A must not attach post-deletion absence evidence");
  }
  const predicate = {
    ...common,
    predicateType: DOMAIN_CORE_RELEASE_PREDICATE_TYPE,
    artifact: { fileName: basename(artifact), sha256: sha256RegularFile(artifact, "release evidence subject") },
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
