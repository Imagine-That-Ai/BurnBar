#!/usr/bin/env node
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  loadDomainCoreBuildProfiles,
  profileAppleEnvironment,
  profileEnvironment,
  profileFunctionsJavaScript,
  profileWebEnvironment,
  profileMSBuildProperties,
  resolveDomainCoreBuildProfile,
} from "../lib/domain-core-build-profile.mjs";
import {
  parseDomainCoreBuildProfileResolverArgs,
  resolveDomainCoreCandidateIdentity,
} from "../lib/domain-core-candidate-receipt.mjs";
import { validateDomainCoreActivation } from "../lib/domain-core-activation.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const args = parseDomainCoreBuildProfileResolverArgs(process.argv.slice(2));
const profileName = args.get("--profile");
const format = args.get("--format") ?? "json";
const output = args.get("--output");
const expectedCandidateCommit = args.get("--expected-candidate-commit");
const expectedReleaseCommit = args.get("--expected-release-commit");
const expectedReleaseVersion = args.get("--expected-release-version");
const expectedReleaseTag = args.get("--expected-release-tag");

const catalog = loadDomainCoreBuildProfiles(
  resolve(repoRoot, "config/domain-core-build-profiles.json"),
);
const catalogProfile = catalog.profiles[profileName];
if (!catalogProfile)
  throw new Error(`unknown domain-core build profile: ${profileName}`);
let candidateIdentity;
if (catalogProfile.artifactAuthority === "signed") {
  if (expectedReleaseCommit !== undefined) {
    if (expectedCandidateCommit === undefined) {
      throw new Error(
        "--expected-release-commit requires --expected-candidate-commit",
      );
    }
    const hasActiveRust = Object.values(catalogProfile.modes).includes("rust");
    if (!hasActiveRust && expectedCandidateCommit === expectedReleaseCommit) {
      candidateIdentity = resolveDomainCoreCandidateIdentity({
        repoRoot,
        expectedCandidateCommit,
        requireClean: true,
      });
    } else {
      const activation = validateDomainCoreActivation({
        repoRoot,
        candidateCommit: expectedCandidateCommit,
        activationCommit: expectedReleaseCommit,
      });
      candidateIdentity = {
        candidateCommit: activation.candidateCommit,
        coreVersion: activation.coreVersion,
        abiVersion: activation.abiVersion,
        sourceSha256: activation.sourceSha256,
      };
    }
  } else {
    candidateIdentity = resolveDomainCoreCandidateIdentity({
      repoRoot,
      expectedCandidateCommit,
      requireClean: true,
    });
  }
}
const releaseFlags = [
  expectedReleaseCommit,
  expectedReleaseVersion,
  expectedReleaseTag,
];
const presentReleaseFlags = releaseFlags.filter(
  (value) => value !== undefined,
).length;
if (presentReleaseFlags !== 0 && presentReleaseFlags !== 3) {
  throw new Error(
    "release coordinates must be all-or-none: --expected-release-commit, --expected-release-version, --expected-release-tag",
  );
}
if (
  catalogProfile.artifactAuthority === "development" &&
  expectedCandidateCommit !== undefined
) {
  throw new Error(
    "--expected-candidate-commit is only valid for signed profiles",
  );
}
if (
  catalogProfile.artifactAuthority === "development" &&
  presentReleaseFlags > 0
) {
  throw new Error(
    "release coordinates are only valid for signed profiles",
  );
}
const release =
  presentReleaseFlags === 3
    ? {
        commit: expectedReleaseCommit,
        version: expectedReleaseVersion,
        tag: expectedReleaseTag,
      }
    : undefined;
const profile = resolveDomainCoreBuildProfile(
  catalog,
  profileName,
  candidateIdentity,
  release,
);
let rendered;
if (format === "json") {
  rendered = `${JSON.stringify(profile, null, 2)}\n`;
} else if (format === "github-env") {
  rendered = `${Object.entries(profileEnvironment(profile))
    .map(([key, value]) => `${key}=${value}`)
    .join("\n")}\n`;
} else if (format === "github-env-web") {
  rendered = `${Object.entries(profileWebEnvironment(profile))
    .map(([key, value]) => `${key}=${value}`)
    .join("\n")}\n`;
} else if (format === "github-env-apple") {
  rendered = `${Object.entries(profileAppleEnvironment(profile))
    .map(([key, value]) => `${key}=${value}`)
    .join("\n")}\n`;
} else if (format === "msbuild-props") {
  const escape = (value) =>
    String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;");
  const properties = profileMSBuildProperties(profile);
  rendered = `<?xml version="1.0" encoding="utf-8"?>\n<Project>\n  <PropertyGroup>\n${Object.entries(
    properties,
  )
    .map(([key, value]) => `    <${key}>${escape(value)}</${key}>`)
    .join("\n")}\n  </PropertyGroup>\n</Project>\n`;
} else if (format === "functions-js") {
  rendered = profileFunctionsJavaScript(profile);
} else {
  throw new Error(`unsupported format: ${format}`);
}

if (output) {
  const path = resolve(output);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, rendered);
} else {
  process.stdout.write(rendered);
}
