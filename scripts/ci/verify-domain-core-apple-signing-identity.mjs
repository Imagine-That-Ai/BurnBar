#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import {
  exactObject,
  regularFile,
} from "../lib/domain-core-release-evidence.mjs";

const TEAM_IDENTIFIER = /^[A-Z0-9]{10}$/u;
const CERTIFICATE_SHA1 = /^[0-9A-F]{40}$/u;
const POLICY_KEYS = [
  "authority",
  "certificateSha1",
  "schemaVersion",
  "teamIdentifier",
];
const JSON_OBJECT_KEY =
  /"(?:\\["\\/bfnrt]|\\u[0-9a-fA-F]{4}|[^"\\\u0000-\u001f])*"\s*:/gu;

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

export function parseAppleSigningPolicy(text) {
  if (typeof text !== "string") {
    throw new Error("Apple signing policy must be JSON text");
  }
  const policy = parseJson(text, "Apple signing policy");
  exactObject(policy, POLICY_KEYS, "Apple signing policy");
  if (policy.schemaVersion !== 2) {
    throw new Error("Apple signing policy schemaVersion must be 2");
  }

  const serializedKeys = [...text.matchAll(JSON_OBJECT_KEY)].map((match) =>
    JSON.parse(match[0].slice(0, match[0].lastIndexOf(":"))),
  );
  if (
    serializedKeys.length !== POLICY_KEYS.length ||
    new Set(serializedKeys).size !== POLICY_KEYS.length
  ) {
    throw new Error(
      "Apple signing policy must declare each protected field exactly once",
    );
  }

  if (
    typeof policy.teamIdentifier !== "string" ||
    !TEAM_IDENTIFIER.test(policy.teamIdentifier)
  ) {
    throw new Error(
      "Apple signing policy teamIdentifier must be 10 uppercase letters or digits",
    );
  }
  if (
    typeof policy.authority !== "string" ||
    !policy.authority.startsWith("Developer ID Application: ")
  ) {
    throw new Error(
      "Apple signing policy authority must be a Developer ID Application identity",
    );
  }
  const authorityTeam = policy.authority.match(/ \(([A-Z0-9]{10})\)$/u)?.[1];
  if (authorityTeam !== policy.teamIdentifier) {
    throw new Error(
      "Apple signing policy authority must end with its exact teamIdentifier",
    );
  }
  if (/[\r\n]/u.test(policy.authority)) {
    throw new Error("Apple signing policy authority must be one line");
  }
  if (
    typeof policy.certificateSha1 !== "string" ||
    !CERTIFICATE_SHA1.test(policy.certificateSha1)
  ) {
    throw new Error(
      "Apple signing policy certificateSha1 must be 40 uppercase hexadecimal characters",
    );
  }
  return structuredClone(policy);
}

export function verifyAppleSigningEnvironment(policyText, environment) {
  const policy = parseAppleSigningPolicy(policyText);
  if (environment?.APPLE_TEAM_ID !== policy.teamIdentifier) {
    throw new Error("APPLE_TEAM_ID does not match committed signing policy");
  }
  if (environment?.APPLE_SIGNING_IDENTITY !== policy.authority) {
    throw new Error(
      "APPLE_SIGNING_IDENTITY does not match committed signing policy",
    );
  }
  if (environment?.APPLE_SIGNING_CERTIFICATE_SHA1 !== policy.certificateSha1) {
    throw new Error(
      "APPLE_SIGNING_CERTIFICATE_SHA1 does not match committed signing policy",
    );
  }
  return structuredClone(policy);
}

function extractCodesignValues(output, field) {
  const prefix = `${field}=`;
  const values = [];
  for (const line of output.split(/\r?\n/u)) {
    if (line.startsWith(prefix)) {
      const value = line.slice(prefix.length);
      if (value.length === 0 || value.trim() !== value) {
        throw new Error(`codesign ${field} is malformed`);
      }
      values.push(value);
    } else if (line.startsWith(field)) {
      throw new Error(`codesign ${field} is malformed`);
    }
  }
  if (values.length === 0) {
    throw new Error(`codesign output is missing ${field}`);
  }
  if (new Set(values).size !== values.length) {
    throw new Error(`codesign output contains duplicate ${field} values`);
  }
  return values;
}

export function verifyAppleCodeSigningIdentity(
  policyText,
  codesignOutput,
  leafCertificate,
) {
  if (typeof codesignOutput !== "string" || codesignOutput.length === 0) {
    throw new Error("codesign output must be nonempty text");
  }
  if (!Buffer.isBuffer(leafCertificate) || leafCertificate.length === 0) {
    throw new Error(
      "codesign leaf certificate must be nonempty DER certificate bytes",
    );
  }
  const policy = parseAppleSigningPolicy(policyText);
  const teams = extractCodesignValues(codesignOutput, "TeamIdentifier");
  if (teams.length !== 1) {
    throw new Error("codesign output must contain exactly one TeamIdentifier");
  }
  if (teams[0] !== policy.teamIdentifier) {
    throw new Error(
      `codesign TeamIdentifier mismatch: expected=${policy.teamIdentifier} actual=${teams[0]}`,
    );
  }

  const authorities = extractCodesignValues(codesignOutput, "Authority");
  if (authorities[0] !== policy.authority) {
    throw new Error(
      `codesign leaf Authority mismatch: expected=${policy.authority} actual=${authorities[0]}`,
    );
  }
  const certificateSha1 = createHash("sha1")
    .update(leafCertificate)
    .digest("hex")
    .toUpperCase();
  if (certificateSha1 !== policy.certificateSha1) {
    throw new Error(
      `codesign leaf certificate SHA-1 mismatch: expected=${policy.certificateSha1} actual=${certificateSha1}`,
    );
  }
  return {
    authority: authorities[0],
    certificateSha1,
    teamIdentifier: teams[0],
  };
}

export function run(argv) {
  if (argv[0] !== "--policy" || argv.length < 3) {
    throw new Error(
      "usage: --policy PATH (--signature PATH --certificate DER_PATH | --environment)",
    );
  }
  const policyPath = regularFile(argv[1], "Apple signing policy");
  const policyText = readFileSync(policyPath, "utf8");
  let identity;
  if (argv.length === 3 && argv[2] === "--environment") {
    identity = verifyAppleSigningEnvironment(policyText, process.env);
  } else if (
    argv.length === 6 &&
    argv[2] === "--signature" &&
    argv[3] &&
    argv[4] === "--certificate" &&
    argv[5]
  ) {
    const outputPath = regularFile(argv[3], "codesign output");
    const certificatePath = regularFile(argv[5], "codesign leaf certificate");
    identity = verifyAppleCodeSigningIdentity(
      policyText,
      readFileSync(outputPath, "utf8"),
      readFileSync(certificatePath),
    );
  } else {
    throw new Error(
      "usage: --policy PATH (--signature PATH --certificate DER_PATH | --environment)",
    );
  }
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
