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
import { readEmbeddedIdentity } from "../ci/verify-domain-core-observed-identity.mjs";

const COMMIT = /^[0-9a-f]{40}$/u;
const SHA256 = /^[0-9a-f]{64}$/u;
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

export function verifyLocalDomainCoreIdentity(
  expectedCommit,
  observed,
  binaryPath,
) {
  if (typeof expectedCommit !== "string" || !COMMIT.test(expectedCommit)) {
    throw new Error("expected candidate commit must be a lowercase 40-character Git SHA");
  }

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
  if (reported.candidateCommit !== expectedCommit) {
    throw new Error(
      `loaded Rust identity is not bound to the local candidate\nexpected=${expectedCommit}\nactual=${reported.candidateCommit}`,
    );
  }

  const binary = regularFile(binaryPath, "observed Rust binary");
  const embedded = readEmbeddedIdentity(binary);
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
    argv[0] !== "--expected-commit" ||
    argv[2] !== "--observed-identity" ||
    argv[4] !== "--binary"
  ) {
    throw new Error(
      "usage: --expected-commit SHA --observed-identity PATH --binary PATH",
    );
  }
  const identity = verifyLocalDomainCoreIdentity(
    argv[1],
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
