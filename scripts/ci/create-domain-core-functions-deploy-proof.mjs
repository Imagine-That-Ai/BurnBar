#!/usr/bin/env node

import { createHash } from "node:crypto";
import { lstatSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, resolve } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { fileURLToPath } from "node:url";

import {
  canonicalJson,
  exactObject,
  regularFile,
  validateDomainCoreCandidateIdentity,
} from "../lib/domain-core-release-evidence.mjs";
import { parseDomainCoreFunctionsJavaScript } from "../lib/domain-core-build-profile.mjs";

const FULL_SHA = /^[0-9a-f]{40}$/u;
const POSITIVE_INTEGER = /^[1-9]\d*$/u;
const RELEASE_TAG =
  /^v\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/u;
const PUBLIC_PROFILES = new Set([
  "public-production",
  "public-production-rollback",
]);
const DOMAINS = [
  "quota",
  "cloudVault",
  "cloudVaultRewrap",
  "cloudVaultSearch",
  "hermes",
  "pricing",
];

function parseArguments(argv) {
  const required = new Set([
    "--profile",
    "--compiled-receipt",
    "--runtime-manifest",
    "--release-gate",
    "--tag",
    "--commit",
    "--deploy-run-id",
    "--deploy-run-attempt",
    "--output",
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!required.has(flag))
      throw new Error(`unknown argument: ${String(flag)}`);
    if (!value || value.startsWith("--"))
      throw new Error(`${flag} requires a value`);
    if (values.has(flag)) throw new Error(`duplicate argument: ${flag}`);
    values.set(flag, value);
  }
  for (const flag of required) {
    if (!values.has(flag)) throw new Error(`${flag} is required`);
  }
  return values;
}

function readJson(path, label) {
  try {
    return JSON.parse(readFileSync(regularFile(path, label), "utf8"));
  } catch (error) {
    throw new Error(`unable to read ${label}: ${error.message}`);
  }
}

function positiveInteger(value, label) {
  if (!POSITIVE_INTEGER.test(value))
    throw new Error(`${label} must be a positive integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed))
    throw new Error(`${label} exceeds the safe integer range`);
  return parsed;
}

function sha256File(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function validateProfile(raw) {
  const profile = exactObject(
    raw,
    [
      "schemaVersion",
      "name",
      "artifactAuthority",
      "distribution",
      "rolloutChannel",
      "evidenceEnabled",
      "modes",
      "candidateIdentity",
    ],
    "Functions profile",
  );
  if (
    profile.schemaVersion !== 1 ||
    !PUBLIC_PROFILES.has(profile.name) ||
    profile.artifactAuthority !== "signed" ||
    profile.distribution !== "public" ||
    profile.rolloutChannel !== null ||
    profile.evidenceEnabled !== false
  ) {
    throw new Error(
      "Functions release requires an exact signed public profile",
    );
  }
  const modes = exactObject(profile.modes, DOMAINS, "Functions profile modes");
  if (
    Object.values(modes).some((mode) => mode !== "legacy" && mode !== "rust")
  ) {
    throw new Error(
      "Functions release profiles may contain only legacy or rust modes",
    );
  }
  if (
    profile.name === "public-production-rollback" &&
    Object.values(modes).some((mode) => mode !== "legacy")
  ) {
    throw new Error(
      "Functions rollback profile must restore every domain to legacy",
    );
  }
  return {
    ...structuredClone(profile),
    candidateIdentity: validateDomainCoreCandidateIdentity(
      profile.candidateIdentity,
    ),
  };
}

function validateReleaseGate(raw, profile, releaseCommit) {
  const gate = exactObject(
    raw,
    [
      "schemaVersion",
      "verificationKind",
      "candidate",
      "activation",
      "sourceRun",
      "promotionProof",
      "rollbackArtifact",
    ],
    "release gate",
  );
  if (
    gate.schemaVersion !== 2 ||
    gate.verificationKind !== "domain-core-release-gate"
  ) {
    throw new Error("release gate is not a v2 domain-core release gate");
  }
  const gateCandidate = validateDomainCoreCandidateIdentity(gate.candidate);
  if (!isDeepStrictEqual(gateCandidate, profile.candidateIdentity)) {
    throw new Error(
      "release gate candidate does not match the Functions profile",
    );
  }
  if (
    gate.activation?.candidateCommit !== gateCandidate.candidateCommit ||
    gate.activation?.activationCommit !== releaseCommit ||
    gate.activation?.coreVersion !== gateCandidate.coreVersion ||
    gate.activation?.abiVersion !== gateCandidate.abiVersion ||
    gate.activation?.sourceSha256 !== gateCandidate.sourceSha256 ||
    !/^[0-9a-f]{64}$/u.test(gate.activation?.changedPathsSha256 ?? "")
  ) {
    throw new Error(
      "release gate activation does not bind candidate C to release activation P",
    );
  }
  if (
    !isDeepStrictEqual(
      validateDomainCoreCandidateIdentity(gate.rollbackArtifact?.candidate),
      profile.candidateIdentity,
    ) ||
    !isDeepStrictEqual(gate.rollbackArtifact?.activation, gate.activation)
  ) {
    throw new Error(
      "release gate rollback candidate does not match the Functions profile",
    );
  }
  return structuredClone(gate);
}

function writeCreateOnly(path, contents) {
  const output = resolve(path);
  mkdirSync(dirname(output), { recursive: true });
  try {
    writeFileSync(output, contents, {
      encoding: "utf8",
      flag: "wx",
      mode: 0o600,
    });
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    const stat = lstatSync(output);
    if (
      !stat.isFile() ||
      stat.isSymbolicLink() ||
      readFileSync(output, "utf8") !== contents
    ) {
      throw new Error(
        `refusing to replace non-identical Functions deploy proof: ${output}`,
      );
    }
  }
  return output;
}

export function buildFunctionsDeployProof({
  profilePath,
  compiledReceiptPath,
  runtimeManifestPath,
  releaseGatePath,
  tag,
  commit,
  deployRunId,
  deployRunAttempt,
}) {
  const resolvedProfilePath = regularFile(profilePath, "Functions profile");
  const resolvedReceiptPath = regularFile(
    compiledReceiptPath,
    "compiled Functions receipt",
  );
  const resolvedGatePath = regularFile(releaseGatePath, "release gate");
  const resolvedManifestPath = regularFile(
    runtimeManifestPath,
    "Functions runtime manifest",
  );
  const profile = validateProfile(
    readJson(resolvedProfilePath, "Functions profile"),
  );
  const compiledReceipt = validateProfile(
    parseDomainCoreFunctionsJavaScript(
      readFileSync(resolvedReceiptPath, "utf8"),
    ),
  );
  if (!isDeepStrictEqual(profile, compiledReceipt)) {
    throw new Error(
      "compiled Functions receipt does not match the selected profile",
    );
  }
  if (!RELEASE_TAG.test(tag))
    throw new Error("Functions release tag is invalid");
  if (!FULL_SHA.test(commit)) {
    throw new Error(
      "Functions release commit must be a full lowercase Git SHA-1",
    );
  }
  validateReleaseGate(readJson(resolvedGatePath, "release gate"), profile);
  const runtimeManifest = readJson(
    resolvedManifestPath,
    "Functions runtime manifest",
  );
  if (
    runtimeManifest?.schemaVersion !== 1 ||
    runtimeManifest?.manifestKind !== "domain-core-runtime-artifact" ||
    runtimeManifest?.consumer !== "functions" ||
    runtimeManifest?.profile !== profile.name ||
    !isDeepStrictEqual(runtimeManifest?.candidate, profile.candidateIdentity) ||
    !Array.isArray(runtimeManifest?.files) ||
    !runtimeManifest.files.some(
      (file) =>
        file?.path ===
          "vendor/openburnbar/domain-core-wasm/openburnbar_domain_core_bg.wasm" &&
        /^[0-9a-f]{64}$/u.test(file.sha256),
    )
  ) {
    throw new Error(
      "Functions runtime manifest is not bound to the selected candidate and WASM",
    );
  }
  return {
    schemaVersion: 1,
    proofKind: "domain-core-functions-deploy-proof",
    repository: "Imagine-That-Ai/BurnBar",
    workflowPath: ".github/workflows/deploy-production.yml",
    deployRun: {
      runId: positiveInteger(String(deployRunId), "deploy run ID"),
      runAttempt: positiveInteger(
        String(deployRunAttempt),
        "deploy run attempt",
      ),
    },
    release: { tag, commit },
    profile: {
      value: profile,
      sha256: sha256File(resolvedProfilePath),
      canonicalSha256: createHash("sha256")
        .update(canonicalJson(profile))
        .digest("hex"),
    },
    compiledReceipt: {
      fileName: basename(resolvedReceiptPath),
      sha256: sha256File(resolvedReceiptPath),
    },
    runtimeArtifact: {
      fileName: basename(resolvedManifestPath),
      sha256: sha256File(resolvedManifestPath),
      value: runtimeManifest,
    },
    releaseGate: {
      fileName: basename(resolvedGatePath),
      sha256: sha256File(resolvedGatePath),
    },
  };
}

export function run(argv) {
  const args = parseArguments(argv);
  const proof = buildFunctionsDeployProof({
    profilePath: resolve(args.get("--profile")),
    compiledReceiptPath: resolve(args.get("--compiled-receipt")),
    runtimeManifestPath: resolve(args.get("--runtime-manifest")),
    releaseGatePath: resolve(args.get("--release-gate")),
    tag: args.get("--tag"),
    commit: args.get("--commit"),
    deployRunId: args.get("--deploy-run-id"),
    deployRunAttempt: args.get("--deploy-run-attempt"),
  });
  const output = writeCreateOnly(
    args.get("--output"),
    `${JSON.stringify(proof, null, 2)}\n`,
  );
  process.stdout.write(`${JSON.stringify({ ok: true, output, proof })}\n`);
  return proof;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
