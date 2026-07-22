#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { buildReleaseEvidence } from "./create-domain-core-release-evidence.mjs";
import { loadDomainCoreBuildProfiles } from "../lib/domain-core-build-profile.mjs";

export const NATIVE_RELEASE_CONSUMERS = Object.freeze({
  apple: Object.freeze({
    artifactKind: "macos-dmg",
    target: "macos-arm64",
    domains: Object.freeze([
      "quota",
      "cloudVault",
      "cloudVaultRewrap",
      "cloudVaultSearch",
      "hermes",
      "pricing",
    ]),
    artifactName: (version) => `OpenBurnBar-${version}-macOS.dmg`,
    bundleName: (version, domain) =>
      `OpenBurnBar-${version}-macOS-${domain}-domain-core-attestation.sigstore.json`,
  }),
  android: Object.freeze({
    artifactKind: "android-aab",
    target: "android-universal",
    domains: Object.freeze([
      "cloudVault",
      "cloudVaultRewrap",
      "cloudVaultSearch",
      "hermes",
    ]),
    artifactName: (version) => `OpenBurnBar-${version}-Android.aab`,
    bundleName: (version, domain) =>
      `OpenBurnBar-${version}-Android-${domain}-domain-core-attestation.sigstore.json`,
  }),
});

const OUTPUT_KEYS = Object.freeze({
  quota: "quota",
  cloudVault: "cloud_vault",
  cloudVaultRewrap: "cloud_vault_rewrap",
  cloudVaultSearch: "cloud_vault_search",
  hermes: "hermes",
  pricing: "pricing",
});

function parseArguments(argv) {
  const values = {};
  const allowed = new Set([
    "consumer",
    "version",
    "tag",
    "commit",
    "artifact",
    "output-dir",
    "profile-catalog",
  ]);
  for (let index = 2; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith("--") || !allowed.has(argument.slice(2))) {
      throw new Error(`unknown argument: ${argument}`);
    }
    const value = argv[++index];
    if (!value || value.startsWith("--"))
      throw new Error(`${argument} requires a value`);
    values[argument.slice(2)] = value;
  }
  for (const key of [
    "consumer",
    "version",
    "tag",
    "commit",
    "artifact",
    "output-dir",
    "profile-catalog",
  ]) {
    if (!values[key]) throw new Error(`--${key} is required`);
  }
  return values;
}

export function buildNativeReleaseEvidencePlan({
  catalog,
  consumer,
  version,
  tag,
  commit,
  artifactPath,
}) {
  const identity = NATIVE_RELEASE_CONSUMERS[consumer];
  if (!identity)
    throw new Error(`unknown native release consumer: ${consumer}`);
  const expectedArtifactName = identity.artifactName(version);
  if (basename(artifactPath) !== expectedArtifactName) {
    throw new Error(`artifact filename must be ${expectedArtifactName}`);
  }
  const artifactSha256 = execFileSync("shasum", ["-a", "256", artifactPath], {
    encoding: "utf8",
  })
    .trim()
    .split(/\s+/, 1)[0];
  if (!/^[0-9a-f]{64}$/.test(artifactSha256))
    throw new Error("unable to compute native artifact SHA-256");
  const domains = [];
  for (const domain of identity.domains) {
    const evidence = buildReleaseEvidence({
      catalog,
      consumer,
      domain,
      version,
      tag,
      commit,
      artifactPath,
    });
    if (!evidence.enabled) continue;
    domains.push({
      domain,
      publicProfileSha256: evidence.publicProfileSha256,
      predicate: evidence.predicateFor(artifactSha256),
      predicateFileName: `${consumer}-${domain}.predicate.json`,
      bundleFileName: identity.bundleName(version, domain),
    });
  }
  return {
    schemaVersion: 1,
    consumer,
    artifactKind: identity.artifactKind,
    target: identity.target,
    artifact: { fileName: expectedArtifactName, sha256: artifactSha256 },
    release: { version, tag, commit },
    domains,
  };
}

export function writeNativeReleaseEvidencePlan(plan, outputDirectory) {
  const directory = resolve(outputDirectory);
  mkdirSync(directory, { recursive: true });
  for (const domain of plan.domains) {
    writeFileSync(
      join(directory, domain.predicateFileName),
      `${JSON.stringify(domain.predicate, null, 2)}\n`,
    );
  }
  const manifestPath = join(directory, `${plan.consumer}-manifest.json`);
  const manifest = {
    ...plan,
    domains: plan.domains.map(({ predicate, ...domain }) => domain),
  };
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  return manifestPath;
}

function appendGitHubOutputs(plan, manifestPath, outputPath) {
  if (!outputPath) return;
  const byDomain = new Map(
    plan.domains.map((domain) => [domain.domain, domain]),
  );
  const lines = [
    `any_enabled=${plan.domains.length > 0 ? "true" : "false"}`,
    `manifest=${manifestPath}`,
  ];
  for (const domain of NATIVE_RELEASE_CONSUMERS[plan.consumer].domains) {
    const evidence = byDomain.get(domain);
    const key = OUTPUT_KEYS[domain];
    lines.push(`${key}_enabled=${evidence ? "true" : "false"}`);
    lines.push(
      `${key}_predicate=${evidence ? join(dirname(manifestPath), evidence.predicateFileName) : ""}`,
    );
    lines.push(`${key}_bundle=${evidence?.bundleFileName ?? ""}`);
  }
  writeFileSync(outputPath, `${lines.join("\n")}\n`, { flag: "a" });
}

export function main(argv = process.argv) {
  const args = parseArguments(argv);
  const artifactPath = resolve(args.artifact);
  const catalog = loadDomainCoreBuildProfiles(resolve(args["profile-catalog"]));
  const plan = buildNativeReleaseEvidencePlan({
    catalog,
    consumer: args.consumer,
    version: args.version,
    tag: args.tag,
    commit: args.commit,
    artifactPath,
  });
  const manifestPath = writeNativeReleaseEvidencePlan(
    plan,
    resolve(args["output-dir"]),
  );
  appendGitHubOutputs(plan, manifestPath, process.env.GITHUB_OUTPUT);
  process.stdout.write(
    `${plan.consumer} native domain-core evidence: ${plan.domains.length} enabled domain(s)\n`,
  );
  return plan;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) main();
