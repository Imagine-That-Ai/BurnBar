#!/usr/bin/env node

import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { validateDomainCoreCandidateIdentity } from "../lib/domain-core-candidate-receipt.mjs";
import {
  canonicalJson,
  canonicalSha256,
  sha256File,
} from "../lib/domain-core-release-evidence.mjs";

const REPOSITORY = "Imagine-That-Ai/BurnBar";
const STABLE_TAG = /^v\d+\.\d+\.\d+(?:\+[0-9A-Za-z.-]+)?$/u;
const PUBLIC_PROFILES = new Set([
  "public-production",
  "public-production-rollback",
]);

function parseArguments(argv) {
  const allowed = new Set([
    "--consumer",
    "--commit",
    "--tag",
    "--profile-receipt",
    "--release-gate",
    "--domain-core-inactive",
    "--output",
    "--verify",
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag))
      throw new Error(`unknown argument: ${String(flag)}`);
    if (!value || value.startsWith("--"))
      throw new Error(`${flag} requires a value`);
    if (values.has(flag)) throw new Error(`duplicate argument: ${flag}`);
    values.set(flag, value);
  }
  for (const flag of ["--consumer", "--commit", "--profile-receipt"]) {
    if (!values.has(flag)) throw new Error(`${flag} is required`);
  }
  if (
    values.has("--domain-core-inactive") &&
    !new Set(["true", "false"]).has(values.get("--domain-core-inactive"))
  ) {
    throw new Error("--domain-core-inactive must be true or false");
  }
  if (values.has("--output") === values.has("--verify")) {
    throw new Error("exactly one of --output or --verify is required");
  }
  return values;
}

function readJson(path, label) {
  try {
    return JSON.parse(readFileSync(resolve(path), "utf8"));
  } catch (error) {
    throw new Error(`unable to read ${label}: ${error.message}`);
  }
}

function sameCandidate(actual, expected, label) {
  const candidate = validateDomainCoreCandidateIdentity(actual);
  if (canonicalJson(candidate) !== canonicalJson(expected)) {
    throw new Error(`${label} does not match the deployed candidate`);
  }
  return candidate;
}

function validateProfileReceipt(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error("profile receipt must be an object");
  }
  if (!PUBLIC_PROFILES.has(raw.name)) {
    throw new Error(
      "Console production requires an explicit public domain-core profile",
    );
  }
  if (raw.artifactAuthority !== "signed" || raw.distribution !== "public") {
    throw new Error("Console production profile must be signed and public");
  }
  if (raw.rolloutChannel !== null || raw.evidenceEnabled !== false) {
    throw new Error(
      "Console production profile cannot enable rollout diagnostics",
    );
  }
  if (!raw.modes || !new Set(["legacy", "rust"]).has(raw.modes.cloudVault)) {
    throw new Error(
      "Console production profile must declare a legacy or rust cloudVault mode",
    );
  }
  const candidate = validateDomainCoreCandidateIdentity(raw.candidateIdentity);
  if (
    raw.name === "public-production-rollback" &&
    Object.values(raw.modes).some((mode) => mode !== "legacy")
  ) {
    throw new Error("rollback profile must restore every domain to legacy");
  }
  return { profile: raw, candidate };
}

function validateReleaseGate(raw, candidate, commit) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error("release gate must be an object");
  }
  if (
    raw.schemaVersion !== 2 ||
    raw.verificationKind !== "domain-core-release-gate"
  ) {
    throw new Error("release gate must use the deterministic v2 contract");
  }
  sameCandidate(raw.candidate, candidate, "release gate candidate");
  sameCandidate(
    raw.rollbackArtifact?.candidate,
    candidate,
    "release gate rollback candidate",
  );
  // The gate re-derives activation P from the committed authority files, so
  // activationCommit is P (an ancestor of the deployment commit R) and the
  // deployment commit binds through activation.releaseCommit.
  if (
    raw.activation?.candidateCommit !== candidate.candidateCommit ||
    raw.activation?.releaseCommit !== commit ||
    !/^[0-9a-f]{40}$/u.test(raw.activation?.activationCommit ?? "") ||
    raw.activation?.coreVersion !== candidate.coreVersion ||
    raw.activation?.abiVersion !== candidate.abiVersion ||
    raw.activation?.sourceSha256 !== candidate.sourceSha256 ||
    !/^[0-9a-f]{64}$/u.test(raw.activation?.changedPathsSha256 ?? "") ||
    canonicalJson(raw.rollbackArtifact?.activation) !==
      canonicalJson(raw.activation)
  ) {
    throw new Error(
      "release gate does not bind candidate C to deployment activation P",
    );
  }
  if (
    raw.sourceRun?.headSha !== candidate.candidateCommit ||
    raw.sourceRun?.workflowPath !== ".github/workflows/domain-core.yml" ||
    raw.promotionProof?.signerWorkflow !==
      ".github/workflows/domain-core-promotion-proof.yml"
  ) {
    throw new Error(
      "release gate does not bind the exact source and protected signer",
    );
  }
  return structuredClone(raw);
}

export function buildDeploymentIdentity({
  consumer,
  commit,
  tag = null,
  profileReceiptPath,
  releaseGatePath,
  domainCoreInactive = false,
}) {
  if (consumer !== "console")
    throw new Error("only the console deployment identity is supported");
  if (!/^[0-9a-f]{40}$/u.test(commit)) {
    throw new Error("commit must be a full lowercase Git SHA-1");
  }
  if (tag !== null && !STABLE_TAG.test(tag)) {
    throw new Error("tag must be a stable semantic v* release tag");
  }
  const profilePath = resolve(profileReceiptPath);
  const { profile, candidate } = validateProfileReceipt(
    readJson(profilePath, "profile receipt"),
  );
  const gate = releaseGatePath
    ? validateReleaseGate(
        readJson(releaseGatePath, "release gate"),
        candidate,
        commit,
      )
    : null;
  const requiresGate =
    (!domainCoreInactive && tag !== null) ||
    profile.name === "public-production-rollback" ||
    profile.modes.cloudVault === "rust";
  if (
    domainCoreInactive &&
    (profile.name === "public-production-rollback" ||
      profile.modes.cloudVault !== "legacy")
  ) {
    throw new Error(
      "inactive domain-core mode is only valid for the legacy public-production profile",
    );
  }
  if (requiresGate && gate === null) {
    throw new Error(
      "tagged, rollback, and Rust-authoritative Console deploys require a protected release gate",
    );
  }
  if (
    gate === null &&
    candidate.candidateCommit !== commit &&
    !domainCoreInactive
  ) {
    throw new Error(
      "ungated legacy deployment candidate must equal the deployment commit",
    );
  }
  return {
    schemaVersion: 2,
    consumer: "console",
    target: "firebase-hosting-production",
    repository: REPOSITORY,
    commit,
    tag,
    profile: {
      name: profile.name,
      sha256: canonicalSha256({
        artifactAuthority: profile.artifactAuthority,
        distribution: profile.distribution,
        rolloutChannel: profile.rolloutChannel,
        evidenceEnabled: profile.evidenceEnabled,
        domain: "cloudVault",
        mode: profile.modes.cloudVault,
      }),
      receiptSha256: sha256File(profilePath),
      cloudVaultMode: profile.modes.cloudVault,
      candidate,
    },
    releaseGate: gate,
  };
}

export function run(argv) {
  const args = parseArguments(argv);
  const identity = buildDeploymentIdentity({
    consumer: args.get("--consumer"),
    commit: args.get("--commit"),
    tag: args.get("--tag") ?? null,
    profileReceiptPath: args.get("--profile-receipt"),
    releaseGatePath: args.get("--release-gate"),
    domainCoreInactive: args.get("--domain-core-inactive") === "true",
  });
  if (args.has("--verify")) {
    assert.deepEqual(
      readJson(args.get("--verify"), "deployed identity"),
      identity,
      "deployed identity does not match the exact source profile, candidate, proof, commit, and tag",
    );
    return identity;
  }
  const output = resolve(args.get("--output"));
  mkdirSync(dirname(output), { recursive: true });
  writeFileSync(output, `${JSON.stringify(identity, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  return identity;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
