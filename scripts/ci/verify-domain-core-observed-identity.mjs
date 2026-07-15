#!/usr/bin/env node

import { isDeepStrictEqual } from "node:util";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { validateDomainCoreCandidateIdentity } from "../lib/domain-core-release-evidence.mjs";

function readJson(path, label) {
  try {
    return JSON.parse(readFileSync(resolve(path), "utf8"));
  } catch (error) {
    throw new Error(`unable to read ${label}: ${error.message}`);
  }
}

export function verifyObservedIdentity(profile, observed) {
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
  const actual = validateDomainCoreCandidateIdentity(observed);
  if (!isDeepStrictEqual(actual, expected)) {
    throw new Error(
      `loaded Rust identity does not match selected signed profile\nexpected=${JSON.stringify(expected)}\nactual=${JSON.stringify(actual)}`,
    );
  }
  return actual;
}

export function run(argv) {
  if (
    argv.length !== 4 ||
    argv[0] !== "--profile" ||
    argv[2] !== "--observed-identity"
  ) {
    throw new Error("usage: --profile PATH --observed-identity PATH");
  }
  const identity = verifyObservedIdentity(
    readJson(argv[1], "selected public profile"),
    readJson(argv[3], "observed Rust identity"),
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
