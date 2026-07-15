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

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const args = parseDomainCoreBuildProfileResolverArgs(process.argv.slice(2));
const profileName = args.get("--profile");
const format = args.get("--format") ?? "json";
const output = args.get("--output");
const expectedCandidateCommit = args.get("--expected-candidate-commit");

const catalog = loadDomainCoreBuildProfiles(
  resolve(repoRoot, "config/domain-core-build-profiles.json"),
);
const catalogProfile = catalog.profiles[profileName];
if (!catalogProfile)
  throw new Error(`unknown domain-core build profile: ${profileName}`);
const candidateIdentity =
  catalogProfile.artifactAuthority === "signed"
    ? resolveDomainCoreCandidateIdentity({
        repoRoot,
        expectedCandidateCommit,
        requireClean: true,
      })
    : undefined;
if (
  catalogProfile.artifactAuthority === "development" &&
  expectedCandidateCommit !== undefined
) {
  throw new Error(
    "--expected-candidate-commit is only valid for signed profiles",
  );
}
const profile = resolveDomainCoreBuildProfile(
  catalog,
  profileName,
  candidateIdentity,
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
