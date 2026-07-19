#!/usr/bin/env node

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { verifyDomainCoreReleaseGate } from "../lib/domain-core-release-evidence.mjs";
import { readRegularFileSync } from "../lib/atomic-regular-file.mjs";

const POSITIVE_INTEGER = /^[1-9]\d*$/u;

function parseArguments(argv) {
  const required = new Set([
    "--candidate-bundle",
    "--promotion-attestation",
    "--rollback-artifact",
    "--candidate-commit",
    "--release-commit",
    "--release-version",
    "--release-tag",
    "--core-version",
    "--abi-version",
    "--source-sha256",
    "--source-run-id",
    "--source-run-attempt",
    "--protected-signer-run-id",
    "--protected-signer-run-attempt",
    "--rollback-sha256",
    "--output",
  ]);
  const optional = new Set([
    "--candidate-rollback-artifact",
    "--rollback-profile",
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!required.has(flag) && !optional.has(flag))
      throw new Error(`unknown argument: ${String(flag)}`);
    if (!value || value.startsWith("--"))
      throw new Error(`${flag} requires a value`);
    if (values.has(flag)) throw new Error(`duplicate argument: ${flag}`);
    values.set(flag, value);
  }
  for (const flag of required) {
    if (!values.has(flag)) throw new Error(`${flag} is required`);
  }
  return values;
}

function positiveInteger(value, label) {
  if (!POSITIVE_INTEGER.test(value))
    throw new Error(`${label} must be a positive integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed))
    throw new Error(`${label} exceeds the safe integer range`);
  return parsed;
}

function writeCreateOnly(path, contents) {
  const output = resolve(path);
  mkdirSync(dirname(output), { recursive: true });
  try {
    writeFileSync(output, contents, {
      encoding: "utf8",
      flag: "wx",
      mode: 0o600,
    });
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    let existing;
    try {
      existing = readRegularFileSync(output, {
        encoding: "utf8",
        label: "release gate receipt",
      });
    } catch {
      throw new Error(`release gate receipt must be a regular file: ${output}`);
    }
    if (existing !== contents) {
      throw new Error(
        `refusing to replace non-identical release gate receipt: ${output}`,
      );
    }
  }
  return output;
}

export function run(argv, { promotionVerifier, activationVerifier } = {}) {
  const args = parseArguments(argv);
  const receipt = verifyDomainCoreReleaseGate({
    candidateBundlePath: resolve(args.get("--candidate-bundle")),
    promotionAttestationPath: resolve(args.get("--promotion-attestation")),
    rollbackArtifactPath: resolve(args.get("--rollback-artifact")),
    candidateRollbackArtifactPath: args.has("--candidate-rollback-artifact")
      ? resolve(args.get("--candidate-rollback-artifact"))
      : undefined,
    rollbackProfilePath: args.has("--rollback-profile")
      ? resolve(args.get("--rollback-profile"))
      : undefined,
    expectedCandidate: {
      candidateCommit: args.get("--candidate-commit"),
      coreVersion: args.get("--core-version"),
      abiVersion: positiveInteger(args.get("--abi-version"), "ABI version"),
      sourceSha256: args.get("--source-sha256"),
    },
    expectedSourceRunId: positiveInteger(
      args.get("--source-run-id"),
      "source run ID",
    ),
    expectedSourceRunAttempt: positiveInteger(
      args.get("--source-run-attempt"),
      "source run attempt",
    ),
    protectedSignerRunId: positiveInteger(
      args.get("--protected-signer-run-id"),
      "protected signer run ID",
    ),
    protectedSignerRunAttempt: positiveInteger(
      args.get("--protected-signer-run-attempt"),
      "protected signer run attempt",
    ),
    expectedRollbackSha256: args.get("--rollback-sha256"),
    expectedReleaseCommit: args.get("--release-commit"),
    expectedReleaseVersion: args.get("--release-version"),
    expectedReleaseTag: args.get("--release-tag"),
    promotionVerifier,
    activationVerifier,
  });
  const output = writeCreateOnly(
    args.get("--output"),
    `${JSON.stringify(receipt, null, 2)}\n`,
  );
  process.stdout.write(`${JSON.stringify({ ok: true, output, ...receipt })}\n`);
  return receipt;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}