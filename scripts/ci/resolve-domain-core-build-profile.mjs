#!/usr/bin/env node
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  loadDomainCoreBuildProfiles,
  profileAppleEnvironment,
  profileEnvironment,
  profileWebEnvironment,
  profileMSBuildProperties,
  resolveDomainCoreBuildProfile,
} from "../lib/domain-core-build-profile.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
let profileName;
let format = "json";
let output;
for (let index = 2; index < process.argv.length; index += 1) {
  const arg = process.argv[index];
  if (arg === "--profile") profileName = process.argv[++index];
  else if (arg === "--format") format = process.argv[++index];
  else if (arg === "--output") output = process.argv[++index];
  else throw new Error(`unknown argument: ${arg}`);
}
if (!profileName) throw new Error("--profile is required");

const catalog = loadDomainCoreBuildProfiles(resolve(repoRoot, "config/domain-core-build-profiles.json"));
const profile = resolveDomainCoreBuildProfile(catalog, profileName);
let rendered;
if (format === "json") {
  rendered = `${JSON.stringify(profile, null, 2)}\n`;
} else if (format === "github-env") {
  rendered = `${Object.entries(profileEnvironment(profile)).map(([key, value]) => `${key}=${value}`).join("\n")}\n`;
} else if (format === "github-env-web") {
  rendered = `${Object.entries(profileWebEnvironment(profile)).map(([key, value]) => `${key}=${value}`).join("\n")}\n`;
} else if (format === "github-env-apple") {
  rendered = `${Object.entries(profileAppleEnvironment(profile)).map(([key, value]) => `${key}=${value}`).join("\n")}\n`;
} else if (format === "msbuild-props") {
  const escape = (value) => String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
  const properties = profileMSBuildProperties(profile);
  rendered = `<?xml version="1.0" encoding="utf-8"?>\n<Project>\n  <PropertyGroup>\n${Object.entries(properties).map(([key, value]) => `    <${key}>${escape(value)}</${key}>`).join("\n")}\n  </PropertyGroup>\n</Project>\n`;
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
