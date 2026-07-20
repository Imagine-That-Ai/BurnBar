#!/usr/bin/env node

import { isDeepStrictEqual } from "node:util";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import {
  exactObject,
  regularFile,
  sha256File,
  validateDomainCoreCandidateIdentity,
} from "../lib/domain-core-release-evidence.mjs";

const SHA256 = /^[0-9a-f]{64}$/u;
const EMBEDDED_IDENTITY =
  /openburnbar-domain-core-identity-v1\|candidateCommit=([0-9a-f]{40})\|coreVersion=([0-9A-Za-z.+-]+)\|abiVersion=([1-9][0-9]*)\|sourceSha256=([0-9a-f]{64})/gu;
const OBSERVED_IDENTITY_KEYS = [
  "abiVersion",
  "binarySha256",
  "candidateCommit",
  "coreVersion",
  "sourceSha256",
];

function readJson(path, label) {
  try {
    return JSON.parse(readFileSync(regularFile(path, label), "utf8"));
  } catch (error) {
    throw new Error(`unable to read ${label}: ${error.message}`);
  }
}

export function readEmbeddedIdentity(binaryPath) {
  const binary = regularFile(binaryPath, "observed Rust binary");
  const contents = readFileSync(binary).toString("latin1");
  const matches = [...contents.matchAll(EMBEDDED_IDENTITY)];
  if (matches.length !== 1) {
    throw new Error(
      `observed Rust binary must contain exactly one canonical embedded identity; found ${matches.length}`,
    );
  }
  const [, candidateCommit, coreVersion, abiVersion, sourceSha256] = matches[0];
  return validateDomainCoreCandidateIdentity({
    candidateCommit,
    coreVersion,
    abiVersion: Number(abiVersion),
    sourceSha256,
  });
}

export function verifyObservedIdentity(profile, observed, binaryPath) {
  if (
    profile?.artifactAuthority !== "signed" ||
    profile?.distribution !== "public" ||
    profile?.candidateIdentity === null ||
    profile?.candidateIdentity === undefined
  ) {
    throw new Error(
      "observed identity requires a candidate-bound signed public profile",
    );
  }
  const expected = validateDomainCoreCandidateIdentity(
    profile.candidateIdentity,
  );
  exactObject(observed, OBSERVED_IDENTITY_KEYS, "observed Rust identity");
  if (
    typeof observed.binarySha256 !== "string" ||
    !SHA256.test(observed.binarySha256)
  ) {
    throw new Error(
      "observed Rust identity binarySha256 must be a lowercase SHA-256 digest",
    );
  }
  const reported = validateDomainCoreCandidateIdentity({
    candidateCommit: observed.candidateCommit,
    coreVersion: observed.coreVersion,
    abiVersion: observed.abiVersion,
    sourceSha256: observed.sourceSha256,
  });
  if (!isDeepStrictEqual(reported, expected)) {
    throw new Error(
      `reported Rust identity does not match selected signed profile\nexpected=${JSON.stringify(expected)}\nactual=${JSON.stringify(reported)}`,
    );
  }
  const binary = regularFile(binaryPath, "observed Rust binary");
  const embedded = readEmbeddedIdentity(binary);
  if (!isDeepStrictEqual(embedded, expected)) {
    throw new Error(
      `embedded Rust identity does not match selected signed profile\nexpected=${JSON.stringify(expected)}\nactual=${JSON.stringify(embedded)}`,
    );
  }
  if (!isDeepStrictEqual(reported, embedded)) {
    throw new Error(
      `reported Rust identity does not match embedded binary identity\nreported=${JSON.stringify(reported)}\nembedded=${JSON.stringify(embedded)}`,
    );
  }
  const actualBinarySha256 = sha256File(binary);
  if (observed.binarySha256 !== actualBinarySha256) {
    throw new Error(
      `loaded Rust binary digest does not match observed identity\nexpected=${observed.binarySha256}\nactual=${actualBinarySha256}`,
    );
  }
  return { ...embedded, binarySha256: actualBinarySha256 };
}

export function run(argv) {
  if (
    argv.length !== 6 ||
    argv[0] !== "--profile" ||
    argv[2] !== "--observed-identity" ||
    argv[4] !== "--binary"
  ) {
    throw new Error(
      "usage: --profile PATH --observed-identity PATH --binary PATH",
    );
  }
  const identity = verifyObservedIdentity(
    readJson(argv[1], "selected public profile"),
    readJson(argv[3], "observed Rust identity"),
    argv[5],
  );
  process.stdout.write(`${JSON.stringify({ ok: true, identity })}\n`);
  return identity;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
