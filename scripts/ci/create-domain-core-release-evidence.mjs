#!/usr/bin/env node
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { loadDomainCoreBuildProfiles } from "../lib/domain-core-build-profile.mjs";

export const RELEASE_PREDICATE_TYPE =
  "https://openburnbar.dev/attestations/domain-core-release-artifact/v1";

const CONSUMERS = Object.freeze({
  apple: {
    artifactKind: "macos-dmg",
    target: "macos-universal",
    domains: [
      "quota",
      "cloudVault",
      "cloudVaultRewrap",
      "cloudVaultSearch",
      "hermes",
      "pricing",
    ],
    fileName: (version) => `OpenBurnBar-${version}-macOS.dmg`,
  },
  android: {
    artifactKind: "android-aab",
    target: "android-universal",
    domains: ["cloudVault", "cloudVaultRewrap", "cloudVaultSearch", "hermes"],
    fileName: (version) => `OpenBurnBar-${version}-Android.aab`,
  },
  windows: {
    artifactKind: "windows-release-bundle",
    target: "windows-x64-arm64",
    domains: ["quota", "cloudVault"],
    fileName: (version) => `OpenBurnBar-${version}-windows-release.zip`,
  },
  console: {
    artifactKind: "console-deployment-receipt",
    target: "firebase-hosting-production",
    domains: ["cloudVault"],
    fileName: (version) => `OpenBurnBar-${version}-console-deployment.json`,
    deployment: {
      provider: "firebase-hosting",
      project: "burnbar",
      environment: "production",
    },
  },
  functions: {
    artifactKind: "functions-deployment-receipt",
    target: "firebase-functions-production",
    domains: ["pricing"],
    fileName: (version) => `OpenBurnBar-${version}-functions-deployment.json`,
    deployment: {
      provider: "firebase-functions",
      project: "burnbar",
      environment: "production",
    },
  },
});

function plainObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error(`${label} must be an object`);
  return value;
}

function requireExactKeys(value, expected, label) {
  const actual = Object.keys(value).sort();
  const required = [...expected].sort();
  if (
    actual.length !== required.length ||
    actual.some((key, index) => key !== required[index])
  ) {
    throw new Error(`${label} must contain exactly: ${required.join(", ")}`);
  }
}

export function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

export function canonicalSha256(value) {
  return createHash("sha256").update(canonicalJson(value)).digest("hex");
}

export function sha256File(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function validateFunctionsHealthEvidence(healthEvidence, { commit, tag }) {
  const health = plainObject(healthEvidence, "health evidence");
  if (health.project !== "burnbar" || health.tag !== tag) {
    throw new Error(
      "Functions health evidence must bind the burnbar project and exact release tag",
    );
  }
  const expectedRepository = "https://github.com/Imagine-That-Ai/BurnBar";
  const live = plainObject(health.healthLive, "health evidence.healthLive");
  const ready = plainObject(health.healthReady, "health evidence.healthReady");
  for (const [label, document, status] of [
    ["healthLive", live, "alive"],
    ["healthReady", ready, "ready"],
  ]) {
    const source = plainObject(
      document.source,
      `health evidence.${label}.source`,
    );
    if (
      document.status !== status ||
      source.repository !== expectedRepository ||
      source.commit !== commit
    ) {
      throw new Error(
        `health evidence ${label} does not bind the healthy release commit`,
      );
    }
  }
  if (
    ready.version !== tag ||
    ready.sentry?.enabled !== true ||
    ready.sentry?.environment !== "production"
  ) {
    throw new Error(
      "health evidence healthReady does not bind the release version and production Sentry state",
    );
  }
}

function validateConsoleHealthEvidence(
  healthEvidence,
  { commit, tag, publicProfileSha256 },
) {
  const health = plainObject(healthEvidence, "health evidence");
  requireExactKeys(
    health,
    [
      "schemaVersion",
      "project",
      "tag",
      "commit",
      "checks",
      "deploymentIdentity",
    ],
    "Console health evidence",
  );
  if (
    health.schemaVersion !== 1 ||
    health.project !== "burnbar" ||
    health.tag !== tag ||
    health.commit !== commit
  ) {
    throw new Error(
      "Console health evidence must bind the burnbar project, release tag, and commit",
    );
  }
  const checks = plainObject(health.checks, "health evidence.checks");
  requireExactKeys(
    checks,
    ["marketing", "console", "deploymentIdentity"],
    "Console health evidence checks",
  );
  if (
    checks.marketing !== "ok" ||
    checks.console !== "ok" ||
    checks.deploymentIdentity !== "ok"
  ) {
    throw new Error(
      "Console health evidence must contain successful marketing, console, and identity checks",
    );
  }
  const identity = plainObject(
    health.deploymentIdentity,
    "health evidence.deploymentIdentity",
  );
  requireExactKeys(
    identity,
    [
      "schemaVersion",
      "consumer",
      "target",
      "repository",
      "commit",
      "tag",
      "profile",
    ],
    "Console deployment identity",
  );
  const profile = plainObject(
    identity.profile,
    "health evidence.deploymentIdentity.profile",
  );
  requireExactKeys(
    profile,
    ["domain", "mode", "publicProfileSha256"],
    "Console deployment profile",
  );
  if (
    identity.schemaVersion !== 1 ||
    identity.consumer !== "console" ||
    identity.target !== "firebase-hosting-production" ||
    identity.repository !== "https://github.com/Imagine-That-Ai/BurnBar" ||
    identity.commit !== commit ||
    identity.tag !== tag ||
    profile.domain !== "cloudVault" ||
    profile.mode !== "rust" ||
    profile.publicProfileSha256 !== publicProfileSha256
  ) {
    throw new Error(
      "Console health evidence does not bind the live Rust deployment identity",
    );
  }
}

export function buildReleaseEvidence({
  catalog,
  consumer,
  domain,
  version,
  tag,
  commit,
  artifactPath,
  healthEvidence,
}) {
  const identity = CONSUMERS[consumer];
  if (!identity) throw new Error(`unknown release consumer: ${consumer}`);
  if (!identity.domains.includes(domain))
    throw new Error(`${consumer} does not ship domain-core domain ${domain}`);
  if (!/^\d+\.\d+\.\d+(?:\+[0-9A-Za-z.-]+)?$/.test(version))
    throw new Error(
      "stable release version must be X.Y.Z with optional build metadata",
    );
  const expectedTag =
    consumer === "windows" ? `windows-v${version}` : `v${version}`;
  if (tag !== expectedTag) throw new Error(`tag must be ${expectedTag}`);
  if (!/^[0-9a-f]{40}$/.test(commit))
    throw new Error("commit must be a full lowercase Git SHA");
  const expectedFileName = identity.fileName(version);
  if (basename(artifactPath) !== expectedFileName)
    throw new Error(`artifact filename must be ${expectedFileName}`);

  const publicProfile = plainObject(
    plainObject(catalog.profiles, "profiles")["public-production"],
    "public-production",
  );
  const modes = plainObject(publicProfile.modes, "public-production.modes");
  if (
    publicProfile.artifactAuthority !== "signed" ||
    publicProfile.distribution !== "public" ||
    publicProfile.rolloutChannel !== null ||
    publicProfile.evidenceEnabled !== false
  ) {
    throw new Error(
      `public-production ${domain} must be signed, public, and evidence-disabled`,
    );
  }
  if (modes[domain] === "legacy") {
    return { enabled: false, expectedFileName };
  }
  if (modes[domain] !== "rust") {
    throw new Error(
      `public-production ${domain} must select legacy or rust authority`,
    );
  }
  const publicProfileSha256 = canonicalSha256({
    artifactAuthority: publicProfile.artifactAuthority,
    distribution: publicProfile.distribution,
    rolloutChannel: publicProfile.rolloutChannel,
    evidenceEnabled: publicProfile.evidenceEnabled,
    domain,
    mode: "rust",
  });

  let deploymentReceipt;
  if (identity.deployment) {
    if (consumer === "functions")
      validateFunctionsHealthEvidence(healthEvidence, { commit, tag });
    if (consumer === "console")
      validateConsoleHealthEvidence(healthEvidence, {
        commit,
        tag,
        publicProfileSha256,
      });
    deploymentReceipt = {
      schemaVersion: 1,
      consumer,
      artifactKind: identity.artifactKind,
      target: identity.target,
      release: { version, tag, commit, publicProfileSha256 },
      deployment:
        consumer === "functions"
          ? {
              ...identity.deployment,
              status: "healthy",
              healthChecks: ["healthLive", "healthReady"],
            }
          : consumer === "console"
            ? {
                ...identity.deployment,
                status: "healthy",
                healthChecks: ["marketing", "console", "deploymentIdentity"],
              }
            : { ...identity.deployment, status: "healthy" },
    };
  }
  return {
    enabled: true,
    expectedFileName,
    publicProfileSha256,
    deploymentReceipt,
    predicateFor(artifactSha256) {
      if (!/^[0-9a-f]{64}$/.test(artifactSha256))
        throw new Error("artifactSha256 must be lowercase SHA-256");
      return {
        schemaVersion: 1,
        consumer,
        artifactKind: identity.artifactKind,
        target: identity.target,
        artifact: { fileName: expectedFileName, sha256: artifactSha256 },
        release: { version, tag, commit, publicProfileSha256 },
      };
    },
  };
}

function parseArguments(argv) {
  const result = {};
  for (let index = 2; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith("--"))
      throw new Error(`unexpected argument: ${argument}`);
    const key = argument.slice(2);
    if (
      !new Set([
        "consumer",
        "domain",
        "version",
        "tag",
        "commit",
        "artifact",
        "predicate",
        "profile-catalog",
        "health-artifact",
      ]).has(key)
    ) {
      throw new Error(`unknown argument: ${argument}`);
    }
    const value = argv[++index];
    if (!value || value.startsWith("--"))
      throw new Error(`${argument} requires a value`);
    result[key] = value;
  }
  for (const key of [
    "consumer",
    "domain",
    "version",
    "tag",
    "commit",
    "artifact",
    "predicate",
  ]) {
    if (!result[key]) throw new Error(`--${key} is required`);
  }
  return result;
}

export function main(argv = process.argv) {
  const arguments_ = parseArguments(argv);
  const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
  const catalog = loadDomainCoreBuildProfiles(
    resolve(
      arguments_["profile-catalog"] ??
        resolve(repoRoot, "config/domain-core-build-profiles.json"),
    ),
  );
  const artifactPath = resolve(arguments_.artifact);
  const predicatePath = resolve(arguments_.predicate);
  const evidence = buildReleaseEvidence({
    catalog,
    consumer: arguments_.consumer,
    domain: arguments_.domain,
    version: arguments_.version,
    tag: arguments_.tag,
    commit: arguments_.commit,
    artifactPath,
    healthEvidence: arguments_["health-artifact"]
      ? JSON.parse(readFileSync(resolve(arguments_["health-artifact"]), "utf8"))
      : undefined,
  });
  if (!evidence.enabled) {
    process.stdout.write(
      `${JSON.stringify({
        enabled: false,
        reason: `public-production ${arguments_.domain} remains legacy-authoritative`,
      })}\n`,
    );
    return;
  }
  if (evidence.deploymentReceipt) {
    mkdirSync(dirname(artifactPath), { recursive: true });
    writeFileSync(
      artifactPath,
      `${JSON.stringify(evidence.deploymentReceipt, null, 2)}\n`,
    );
  } else {
    readFileSync(artifactPath);
  }
  const predicate = evidence.predicateFor(sha256File(artifactPath));
  mkdirSync(dirname(predicatePath), { recursive: true });
  writeFileSync(predicatePath, `${JSON.stringify(predicate, null, 2)}\n`);
  process.stdout.write(
    `${JSON.stringify({
      enabled: true,
      predicateType: RELEASE_PREDICATE_TYPE,
      artifactPath,
      predicatePath,
      publicProfileSha256: evidence.publicProfileSha256,
    })}\n`,
  );
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (error) {
    console.error(
      `ERROR: ${error instanceof Error ? error.message : String(error)}`,
    );
    process.exitCode = 1;
  }
}
