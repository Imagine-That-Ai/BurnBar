#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

import { NATIVE_RELEASE_CONSUMERS } from "./create-domain-core-native-release-evidence.mjs";

const CONSUMERS = new Set(["apple", "android"]);
const VERSION = /^\d+\.\d+\.\d+(?:\+[0-9A-Za-z.-]+)?$/;
const SHA256 = /^[0-9a-f]{64}$/;
const COMMIT = /^[0-9a-f]{40}$/;

function exactObject(value, keys, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (
    actual.length !== expected.length ||
    actual.some((key, index) => key !== expected[index])
  ) {
    throw new Error(`${label} must contain exactly: ${expected.join(", ")}`);
  }
  return value;
}

export function resolveNativePublicationMode(raw, expectedConsumer) {
  if (!CONSUMERS.has(expectedConsumer)) {
    throw new Error("expected consumer must be apple or android");
  }
  const manifest = exactObject(
    raw,
    [
      "schemaVersion",
      "consumer",
      "artifactKind",
      "target",
      "artifact",
      "release",
      "domains",
    ],
    "native evidence manifest",
  );
  if (manifest.schemaVersion !== 1) {
    throw new Error("native evidence manifest schemaVersion must be 1");
  }
  if (manifest.consumer !== expectedConsumer) {
    throw new Error("native evidence manifest consumer mismatch");
  }
  const identity = NATIVE_RELEASE_CONSUMERS[expectedConsumer];
  if (
    manifest.artifactKind !== identity.artifactKind ||
    manifest.target !== identity.target
  ) {
    throw new Error("native evidence manifest artifact identity mismatch");
  }
  const release = exactObject(
    manifest.release,
    ["version", "tag", "commit"],
    "native evidence manifest release",
  );
  if (
    typeof release.version !== "string" ||
    !VERSION.test(release.version) ||
    release.tag !== `v${release.version}` ||
    typeof release.commit !== "string" ||
    !COMMIT.test(release.commit)
  ) {
    throw new Error("native evidence manifest release identity is invalid");
  }
  const artifact = exactObject(
    manifest.artifact,
    ["fileName", "sha256"],
    "native evidence manifest artifact",
  );
  if (
    artifact.fileName !== identity.artifactName(release.version) ||
    typeof artifact.sha256 !== "string" ||
    !SHA256.test(artifact.sha256)
  ) {
    throw new Error("native evidence manifest artifact identity is invalid");
  }
  if (!Array.isArray(manifest.domains)) {
    throw new Error("native evidence manifest domains must be an array");
  }
  const seenDomains = new Set();
  for (const [index, domain] of manifest.domains.entries()) {
    exactObject(
      domain,
      ["domain", "publicProfileSha256", "predicateFileName", "bundleFileName"],
      `native evidence manifest domains[${index}]`,
    );
    if (
      !identity.domains.includes(domain.domain) ||
      seenDomains.has(domain.domain) ||
      typeof domain.publicProfileSha256 !== "string" ||
      !SHA256.test(domain.publicProfileSha256) ||
      domain.predicateFileName !==
        `${expectedConsumer}-${domain.domain}.predicate.json` ||
      domain.bundleFileName !==
        identity.bundleName(release.version, domain.domain)
    ) {
      throw new Error(
        `native evidence manifest domains[${index}] identity is invalid`,
      );
    }
    seenDomains.add(domain.domain);
  }
  return manifest.domains.length > 0 ? "shared-rust" : "legacy";
}

function parseArguments(argv) {
  const values = {};
  for (let index = 2; index < argv.length; index += 1) {
    const argument = argv[index];
    const value = argv[++index];
    if (!value || value.startsWith("--")) {
      throw new Error(`${argument} requires a value`);
    }
    if (argument === "--manifest") values.manifest = value;
    else if (argument === "--consumer") values.consumer = value;
    else throw new Error(`unknown argument: ${argument}`);
  }
  if (!values.manifest) throw new Error("--manifest is required");
  if (!values.consumer) throw new Error("--consumer is required");
  return values;
}

export function main(argv = process.argv) {
  const args = parseArguments(argv);
  const manifest = JSON.parse(readFileSync(args.manifest, "utf8"));
  process.stdout.write(
    `${resolveNativePublicationMode(manifest, args.consumer)}\n`,
  );
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  try {
    main();
  } catch (error) {
    console.error(
      `ERROR: ${error instanceof Error ? error.message : String(error)}`,
    );
    process.exitCode = 1;
  }
}
