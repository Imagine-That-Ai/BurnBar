#!/usr/bin/env node

import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  resolveActiveDomainCoreActivation,
  validateDomainCoreActivation,
} from "../lib/domain-core-activation.mjs";
import { validateDomainCoreCandidateIdentity } from "../lib/domain-core-candidate-receipt.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const FULL_SHA = /^[0-9a-f]{40}$/u;
const RELEASE_TAG =
  /^v\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/u;

function args(argv) {
  const allowed = new Set([
    "--release-commit",
    "--release-tag",
    "--profile",
    "--output",
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (
      !allowed.has(flag) ||
      !value ||
      value.startsWith("--") ||
      values.has(flag)
    ) {
      throw new Error(`invalid or duplicate argument ${String(flag)}`);
    }
    values.set(flag, value);
  }
  for (const flag of allowed) {
    if (!values.has(flag)) throw new Error(`${flag} is required`);
  }
  return values;
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
    const existing = readFileSync(output, "utf8");
    if (existing !== contents) {
      throw new Error(
        `refusing to replace non-identical inactive release gate: ${output}`,
      );
    }
  }
}

export function prepareInactiveFunctionsReleaseGate({
  releaseCommit,
  releaseTag,
  profilePath,
  outputPath,
  repoRoot = ROOT,
  activationResolver = resolveActiveDomainCoreActivation,
  releaseActivationResolver = validateDomainCoreActivation,
}) {
  if (!FULL_SHA.test(releaseCommit)) {
    throw new Error("release commit must be a full lowercase Git SHA-1");
  }
  if (!RELEASE_TAG.test(releaseTag)) {
    throw new Error("release tag is not a valid SemVer tag");
  }

  const resolved = activationResolver({
    repoRoot,
    activationCommit: releaseCommit,
  });
  if (resolved.active !== false) {
    throw new Error(
      "inactive Functions lane requested while domain core is active",
    );
  }

  // With no active Rust domains there is no candidate bundle, promotion
  // attestation, or signer run to download. Bind the legacy profile and gate
  // directly to the exact release commit instead. This is the same C=P=R
  // closure used by the native and hosting lanes and fails closed if Rust is
  // reactivated in the release checkout.
  const releaseActivation = releaseActivationResolver({
    repoRoot,
    candidateCommit: releaseCommit,
    activationCommit: releaseCommit,
    requireHead: true,
  });
  if (releaseActivation.active !== false) {
    throw new Error(
      "release-bound inactive Functions selector resolved active",
    );
  }
  const profile = JSON.parse(readFileSync(resolve(profilePath), "utf8"));
  const candidate = validateDomainCoreCandidateIdentity(
    profile.candidateIdentity,
  );
  if (candidate.candidateCommit !== releaseCommit) {
    throw new Error(
      "inactive Functions profile must bind candidate C to release R",
    );
  }
  if (
    candidate.coreVersion !== releaseActivation.coreVersion ||
    candidate.abiVersion !== releaseActivation.abiVersion ||
    candidate.sourceSha256 !== releaseActivation.sourceSha256
  ) {
    throw new Error(
      "inactive Functions profile does not match release-bound domain-core identity",
    );
  }

  const activation = {
    candidateCommit: candidate.candidateCommit,
    activationCommit: candidate.candidateCommit,
    coreVersion: candidate.coreVersion,
    abiVersion: candidate.abiVersion,
    sourceSha256: candidate.sourceSha256,
    changedPathsSha256: createHash("sha256").update("[]").digest("hex"),
    releaseCommit,
  };
  const gate = {
    schemaVersion: 2,
    verificationKind: "domain-core-release-gate-inactive",
    candidate,
    activation,
    release: { tag: releaseTag, commit: releaseCommit },
  };
  const serialized = `${JSON.stringify(gate, null, 2)}\n`;
  writeCreateOnly(outputPath, serialized);
  return gate;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const values = args(process.argv.slice(2));
    const gate = prepareInactiveFunctionsReleaseGate({
      releaseCommit: values.get("--release-commit"),
      releaseTag: values.get("--release-tag"),
      profilePath: values.get("--profile"),
      outputPath: values.get("--output"),
    });
    process.stdout.write(`${JSON.stringify({ ok: true, ...gate })}\n`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
