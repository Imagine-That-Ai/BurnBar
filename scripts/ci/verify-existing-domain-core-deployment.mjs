#!/usr/bin/env node

import { createHash } from "node:crypto";
import { isDeepStrictEqual } from "node:util";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { readRegularFileSync } from "../lib/atomic-regular-file.mjs";
import { validateDomainCoreCandidateIdentity } from "../lib/domain-core-candidate-receipt.mjs";

const FULL_SHA = /^[0-9a-f]{40}$/u;
const SHA256 = /^[0-9a-f]{64}$/u;
const ACTIVATION_KEYS = [
  "abiVersion",
  "activationCommit",
  "candidateCommit",
  "changedPathsSha256",
  "coreVersion",
  "sourceSha256",
];

function bytes(path, label) {
  return readRegularFileSync(resolve(path), { label });
}

function json(path, label) {
  return JSON.parse(bytes(path, label));
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function exactTargetSet(targets, expected, label) {
  if (
    !Array.isArray(targets) ||
    targets.length !== expected.length ||
    new Set(targets.map((item) => item?.target)).size !== expected.length ||
    expected.some((target) => !targets.some((item) => item?.target === target))
  ) {
    throw new Error(
      `${label} does not exactly match the protected target inventory`,
    );
  }
}

function canonicalJson(value) {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJson).join(",")}]`;
  }
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function sameCandidate(actual, expected, label) {
  let candidate;
  try {
    candidate = validateDomainCoreCandidateIdentity(actual);
  } catch (error) {
    throw new Error(`${label} is invalid: ${error.message}`);
  }
  if (canonicalJson(candidate) !== canonicalJson(expected)) {
    throw new Error(`${label} does not match candidate C`);
  }
  return candidate;
}

function runtimeManifest(artifactBytes, consumer, candidate) {
  let manifest;
  try {
    manifest = JSON.parse(artifactBytes.toString("utf8"));
  } catch (error) {
    throw new Error(
      `runtime artifact manifest is not valid JSON: ${error.message}`,
    );
  }
  if (
    manifest?.schemaVersion !== 1 ||
    manifest?.manifestKind !== "domain-core-runtime-artifact" ||
    manifest?.consumer !== consumer
  ) {
    throw new Error("runtime artifact manifest contract is invalid");
  }
  sameCandidate(manifest.candidate, candidate, "runtime artifact candidate");
  return manifest;
}

function validateActivation(value, candidate) {
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    !isDeepStrictEqual(Object.keys(value).sort(), ACTIVATION_KEYS) ||
    value.candidateCommit !== candidate.candidateCommit ||
    value.coreVersion !== candidate.coreVersion ||
    value.abiVersion !== candidate.abiVersion ||
    value.sourceSha256 !== candidate.sourceSha256 ||
    !FULL_SHA.test(value.activationCommit ?? "") ||
    value.activationCommit === candidate.candidateCommit ||
    !SHA256.test(value.changedPathsSha256 ?? "")
  ) {
    throw new Error("release activation P does not bind candidate C");
  }
  return structuredClone(value);
}

function validateReleaseGate(receipt, releaseCommit, artifactBytes, consumer) {
  const candidate = validateDomainCoreCandidateIdentity(receipt?.candidate);
  const activation = validateActivation(receipt?.activation, candidate);
  runtimeManifest(artifactBytes, consumer, candidate);
  sameCandidate(
    receipt?.rollbackArtifact?.candidate,
    candidate,
    "rollback artifact candidate",
  );
  if (
    canonicalJson(receipt?.rollbackArtifact?.activation) !==
      canonicalJson(activation) ||
    typeof receipt?.rollbackArtifact?.fileName !== "string" ||
    receipt.rollbackArtifact.fileName.length === 0 ||
    !SHA256.test(receipt?.rollbackArtifact?.sha256 ?? "")
  ) {
    throw new Error("rollback artifact does not bind activation P");
  }
  if (
    receipt?.sourceRun?.repository !== "Imagine-That-Ai/BurnBar" ||
    receipt?.sourceRun?.workflowPath !== ".github/workflows/domain-core.yml" ||
    receipt?.sourceRun?.event !== "push" ||
    receipt?.sourceRun?.ref !== "refs/heads/main" ||
    receipt?.sourceRun?.headSha !== candidate.candidateCommit ||
    !Number.isSafeInteger(receipt?.sourceRun?.runId) ||
    receipt.sourceRun.runId < 1 ||
    !Number.isSafeInteger(receipt?.sourceRun?.runAttempt) ||
    receipt.sourceRun.runAttempt < 1
  ) {
    throw new Error("source run does not bind candidate C");
  }
  if (
    receipt?.promotionProof?.signerWorkflow !==
      ".github/workflows/domain-core-promotion-proof.yml" ||
    receipt?.promotionProof?.predicateType !==
      "https://slsa.dev/provenance/v1" ||
    !Number.isSafeInteger(receipt?.promotionProof?.signerRun?.runId) ||
    receipt.promotionProof.signerRun.runId < 1 ||
    !Number.isSafeInteger(receipt?.promotionProof?.signerRun?.runAttempt) ||
    receipt.promotionProof.signerRun.runAttempt < 1
  ) {
    throw new Error("promotion proof does not bind the protected gate");
  }
  return { candidate, activation };
}

function validateFunctionsRuntimeIdentity(
  document,
  candidate,
  releaseCommit,
  label,
) {
  let liveCandidate;
  try {
    liveCandidate = validateDomainCoreCandidateIdentity(
      document?.domainCore?.candidateIdentity,
    );
  } catch (error) {
    throw new Error(`${label} live candidate C is invalid: ${error.message}`);
  }
  const loaded = document.domainCore.loadedCore;
  if (
    document?.source?.repository !==
      "https://github.com/Imagine-That-Ai/BurnBar" ||
    document.source.commit !== releaseCommit ||
    canonicalJson(liveCandidate) !== canonicalJson(candidate) ||
    loaded?.version !== candidate.coreVersion ||
    loaded?.abiVersion !== candidate.abiVersion ||
    loaded?.sourceSha256 !== candidate.sourceSha256 ||
    !SHA256.test(loaded?.wasmSha256 ?? "")
  ) {
    throw new Error(
      `${label} live runtime does not bind candidate C and release D`,
    );
  }
}

export function verifyExistingDeployment({
  consumer,
  receipt,
  tag,
  commit,
  artifactBytes,
  live,
  providerCoordinates,
  inventory,
}) {
  if (
    receipt?.schemaVersion !== 2 ||
    receipt?.consumer !== consumer ||
    receipt?.release?.tag !== tag ||
    receipt?.release?.commit !== commit ||
    receipt?.deployment?.status !== "healthy" ||
    receipt?.deployment?.deployedArtifact?.sha256 !== sha256(artifactBytes)
  ) {
    throw new Error(
      "existing evidence does not match the exact stable deployment artifact",
    );
  }
  const authority = validateReleaseGate(
    receipt,
    commit,
    artifactBytes,
    consumer,
  );
  const coordinates = receipt.deployment.providerCoordinates;
  if (!isDeepStrictEqual(providerCoordinates, coordinates)) {
    throw new Error(
      `current ${consumer} provider coordinates differ from existing evidence`,
    );
  }
  if (consumer === "console") {
    if (!Buffer.from(live).equals(artifactBytes))
      throw new Error(
        "live Console runtime manifest differs from existing evidence",
      );
    const expectedSites = ["console", "marketing"];
    exactTargetSet(coordinates?.sites, expectedSites, "Hosting coordinates");
  } else if (consumer === "functions") {
    if (
      inventory?.schemaVersion !== 1 ||
      !Array.isArray(inventory.targets) ||
      inventory.targets.length === 0 ||
      new Set(inventory.targets).size !== inventory.targets.length ||
      inventory.targets.some(
        (target) => !/^[A-Za-z][A-Za-z0-9]*$/u.test(target),
      )
    ) {
      throw new Error("protected Functions target inventory is invalid");
    }
    exactTargetSet(
      coordinates?.targets,
      inventory.targets,
      "Functions receipt coordinates",
    );
    exactTargetSet(
      providerCoordinates?.targets,
      inventory.targets,
      "current Functions coordinates",
    );
    const healthTargets = ["healthLive", "healthReady"];
    if (
      !live ||
      Object.keys(live).length !== healthTargets.length ||
      healthTargets.some((target) => !Object.hasOwn(live, target))
    ) {
      throw new Error(
        "live Functions health documents are incomplete or unexpected",
      );
    }
    for (const target of healthTargets) {
      const document = live[target];
      validateFunctionsRuntimeIdentity(
        document,
        authority.candidate,
        commit,
        target,
      );
      if (
        document?.domainCore?.artifactManifest?.sha256 !== sha256(artifactBytes)
      ) {
        throw new Error(
          `${target} live artifact manifest differs from existing evidence`,
        );
      }
      const expected = coordinates?.targets?.find(
        (item) => item.target === target,
      );
      if (
        !expected ||
        expected.revision !== document.domainCore.runtime?.revision ||
        !expected.service.endsWith(`/${document.domainCore.runtime?.service}`)
      ) {
        throw new Error(
          `${target} live revision differs from existing evidence`,
        );
      }
    }
    if (coordinates?.buildArtifactSha256 !== sha256(artifactBytes)) {
      throw new Error(
        "existing Functions build coordinate differs from runtime artifact",
      );
    }
  } else {
    throw new Error("consumer must be console or functions");
  }
  return {
    reused: true,
    providerCoordinates: receipt.deployment.providerCoordinates,
  };
}

function args(argv) {
  const values = new Map();
  const allowed = new Set([
    "--consumer",
    "--receipt",
    "--tag",
    "--commit",
    "--artifact",
    "--live",
    "--provider-coordinates",
    "--inventory",
  ]);
  for (let index = 0; index < argv.length; index += 2) {
    if (
      !allowed.has(argv[index]) ||
      !argv[index + 1] ||
      values.has(argv[index])
    ) {
      throw new Error(`invalid or duplicate argument ${String(argv[index])}`);
    }
    values.set(argv[index], argv[index + 1]);
  }
  for (const flag of [
    "--consumer",
    "--receipt",
    "--tag",
    "--commit",
    "--artifact",
    "--live",
    "--provider-coordinates",
  ]) {
    if (!values.get(flag)) throw new Error(`${flag} is required`);
  }
  if (values.get("--consumer") === "functions" && !values.get("--inventory")) {
    throw new Error(
      "--inventory is required for Functions replay verification",
    );
  }
  return values;
}

export function run(argv) {
  const values = args(argv);
  const consumer = values.get("--consumer");
  const live =
    consumer === "console"
      ? bytes(values.get("--live"), "live Console runtime manifest")
      : json(values.get("--live"), "live Functions health documents");
  const result = verifyExistingDeployment({
    consumer,
    receipt: json(values.get("--receipt"), "existing deployment receipt"),
    tag: values.get("--tag"),
    commit: values.get("--commit"),
    artifactBytes: bytes(
      values.get("--artifact"),
      "local runtime artifact manifest",
    ),
    live,
    providerCoordinates: json(
      values.get("--provider-coordinates"),
      "current provider coordinates",
    ),
    inventory: values.get("--inventory")
      ? json(values.get("--inventory"), "protected Functions target inventory")
      : undefined,
  });
  process.stdout.write(`${JSON.stringify(result)}\n`);
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
