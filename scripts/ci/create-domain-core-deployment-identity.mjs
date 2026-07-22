#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { loadDomainCoreBuildProfiles } from "../lib/domain-core-build-profile.mjs";
import { canonicalSha256 } from "./create-domain-core-release-evidence.mjs";

const REPOSITORY = "https://github.com/Imagine-That-Ai/BurnBar";

function parseArguments(argv) {
  const result = {};
  const allowed = new Set([
    "consumer",
    "commit",
    "tag",
    "output",
    "verify",
    "profile-catalog",
  ]);
  for (let index = 2; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith("--"))
      throw new Error(`unexpected argument: ${argument}`);
    const key = argument.slice(2);
    if (!allowed.has(key)) throw new Error(`unknown argument: ${argument}`);
    const value = argv[++index];
    if (!value || value.startsWith("--"))
      throw new Error(`${argument} requires a value`);
    result[key] = value;
  }
  for (const key of ["consumer", "commit"]) {
    if (!result[key]) throw new Error(`--${key} is required`);
  }
  if (Boolean(result.output) === Boolean(result.verify)) {
    throw new Error("exactly one of --output or --verify is required");
  }
  return result;
}

export function buildDeploymentIdentity({
  catalog,
  consumer,
  commit,
  tag = null,
}) {
  if (consumer !== "console")
    throw new Error("only the console deployment identity is supported");
  if (!/^[0-9a-f]{40}$/.test(commit))
    throw new Error("commit must be a full lowercase Git SHA");
  if (tag !== null && !/^v\d+\.\d+\.\d+(?:\+[0-9A-Za-z.-]+)?$/.test(tag)) {
    throw new Error("tag must be a stable semantic v* release tag");
  }
  const profile = catalog?.profiles?.["public-production"];
  if (!profile || typeof profile !== "object" || Array.isArray(profile)) {
    throw new Error("public-production profile is missing");
  }
  const mode = profile.modes?.cloudVault;
  if (!new Set(["legacy", "rust"]).has(mode)) {
    throw new Error("public-production cloudVault mode must be legacy or rust");
  }
  const publicProfileSha256 = canonicalSha256({
    artifactAuthority: profile.artifactAuthority,
    distribution: profile.distribution,
    rolloutChannel: profile.rolloutChannel,
    evidenceEnabled: profile.evidenceEnabled,
    domain: "cloudVault",
    mode,
  });
  return {
    schemaVersion: 1,
    consumer: "console",
    target: "firebase-hosting-production",
    repository: REPOSITORY,
    commit,
    tag,
    profile: {
      domain: "cloudVault",
      mode,
      publicProfileSha256,
    },
  };
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
  const expected = buildDeploymentIdentity({
    catalog,
    consumer: arguments_.consumer,
    commit: arguments_.commit,
    tag: arguments_.tag ?? null,
  });
  if (arguments_.verify) {
    const actual = JSON.parse(readFileSync(resolve(arguments_.verify), "utf8"));
    assert.deepEqual(
      actual,
      expected,
      "deployed identity does not match the exact source profile, commit, and tag",
    );
    return;
  }
  const output = resolve(arguments_.output);
  mkdirSync(dirname(output), { recursive: true });
  writeFileSync(output, `${JSON.stringify(expected, null, 2)}\n`);
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
