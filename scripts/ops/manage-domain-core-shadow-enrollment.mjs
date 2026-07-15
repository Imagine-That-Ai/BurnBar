#!/usr/bin/env node
import { createRequire } from "node:module";
import { resolve } from "node:path";
import {
  clearDomainCoreShadowClaims,
  enrollmentMatches,
  mergeDomainCoreShadowClaims,
  normalizeDomainCoreShadowEnrollment,
  readDomainCoreShadowEnrollmentClaims,
} from "../lib/domain-core-shadow-enrollment.mjs";

const USAGE = `Usage:
  manage-domain-core-shadow-enrollment.mjs --uid UID --channel internal|beta \\
    --consumers apple,windows --candidate-commit FULL_GIT_SHA \\
    --core-version SEMVER --core-abi-version UINT32 \\
    --core-source-sha256 SHA256 [--project PROJECT] [--apply]

  manage-domain-core-shadow-enrollment.mjs --uid UID --channel internal|beta \\
    --consumers apple,windows --candidate-commit FULL_GIT_SHA \\
    --core-version SEMVER --core-abi-version UINT32 \\
    --core-source-sha256 SHA256 [--project PROJECT] --verify

  manage-domain-core-shadow-enrollment.mjs --uid UID [--project PROJECT] --clear [--apply]

Consumers: apple, windows, android, console, functions, local-mcp, remote-mcp.

The command is a dry run unless --apply is supplied. Enrollment binds uploads to
one exact app commit and loaded Rust version/ABI/source tuple. --clear revokes all
domain-core shadow claims even when an existing enrollment is partial or invalid.`;

const VALUE_OPTIONS = new Set([
  "--uid",
  "--project",
  "--channel",
  "--consumers",
  "--candidate-commit",
  "--core-version",
  "--core-abi-version",
  "--core-source-sha256",
]);
const FLAG_OPTIONS = new Set(["--apply", "--clear", "--verify"]);
const args = new Map();
const flags = new Set();

if (process.argv.slice(2).some((arg) => arg === "--help" || arg === "-h")) {
  console.log(USAGE);
  process.exit(0);
}

for (let index = 2; index < process.argv.length; index += 1) {
  const arg = process.argv[index];
  if (FLAG_OPTIONS.has(arg)) {
    if (flags.has(arg)) throw new Error(`duplicate argument: ${arg}`);
    flags.add(arg);
  } else if (VALUE_OPTIONS.has(arg)) {
    if (args.has(arg)) throw new Error(`duplicate argument: ${arg}`);
    const value = process.argv[index + 1];
    if (value === undefined || value.startsWith("--"))
      throw new Error(`${arg} requires a value`);
    args.set(arg, value);
    index += 1;
  } else {
    throw new Error(`unknown argument: ${arg}\n\n${USAGE}`);
  }
}

const uid = args.get("--uid");
if (!uid) throw new Error(`--uid is required\n\n${USAGE}`);
if (flags.has("--clear") && flags.has("--verify"))
  throw new Error("--clear and --verify are mutually exclusive");
if (flags.has("--verify") && flags.has("--apply"))
  throw new Error("--verify and --apply are mutually exclusive");

const enrollmentOptions = [
  "--channel",
  "--consumers",
  "--candidate-commit",
  "--core-version",
  "--core-abi-version",
  "--core-source-sha256",
];
if (
  flags.has("--clear") &&
  enrollmentOptions.some((option) => args.has(option))
) {
  throw new Error(
    "--clear cannot be combined with enrollment identity arguments",
  );
}

let enrollment;
if (!flags.has("--clear")) {
  enrollment = normalizeDomainCoreShadowEnrollment(
    args.get("--channel"),
    (args.get("--consumers") ?? "").split(","),
    args.get("--candidate-commit"),
    {
      version: args.get("--core-version"),
      abiVersion: args.get("--core-abi-version"),
      sourceSha256: args.get("--core-source-sha256"),
    },
  );
}

const requireFromFunctions = createRequire(resolve("functions/package.json"));
const { applicationDefault, getApps, initializeApp } =
  requireFromFunctions("firebase-admin/app");
const { getAuth } = requireFromFunctions("firebase-admin/auth");
if (getApps().length === 0)
  initializeApp({
    credential: applicationDefault(),
    projectId: args.get("--project"),
  });
const auth = getAuth();
const user = await auth.getUser(uid);
const existing = user.customClaims ?? {};

if (flags.has("--clear")) {
  const next = clearDomainCoreShadowClaims(existing);
  if (flags.has("--apply")) await auth.setCustomUserClaims(uid, next);
  console.log(
    JSON.stringify(
      {
        uid,
        action: flags.has("--apply") ? "cleared" : "would-clear",
        claims: next,
      },
      null,
      2,
    ),
  );
  process.exit(0);
}

if (flags.has("--verify")) {
  if (!enrollmentMatches(existing, enrollment)) {
    let currentEnrollment = null;
    let currentEnrollmentError = null;
    try {
      currentEnrollment = readDomainCoreShadowEnrollmentClaims(existing);
    } catch (error) {
      currentEnrollmentError =
        error instanceof Error ? error.message : "invalid enrollment claims";
    }
    console.error(
      JSON.stringify(
        {
          uid,
          status: "mismatch",
          expected: enrollment,
          currentEnrollment,
          currentEnrollmentError,
        },
        null,
        2,
      ),
    );
    process.exit(2);
  }
  console.log(JSON.stringify({ uid, status: "verified", enrollment }, null, 2));
  process.exit(0);
}

const next = mergeDomainCoreShadowClaims(existing, enrollment);
if (Buffer.byteLength(JSON.stringify(next), "utf8") > 900)
  throw new Error(
    "merged custom claims exceed the 900-byte operator safety limit",
  );
if (flags.has("--apply")) await auth.setCustomUserClaims(uid, next);
console.log(
  JSON.stringify(
    {
      uid,
      action: flags.has("--apply") ? "merged" : "would-merge",
      claims: next,
    },
    null,
    2,
  ),
);
