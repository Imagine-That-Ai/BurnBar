#!/usr/bin/env node

import { lstatSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { fileURLToPath } from "node:url";

import {
  exactObject,
  regularFile,
} from "../lib/domain-core-release-evidence.mjs";

function parseArguments(argv) {
  const required = new Set(["--deploy-proof", "--health-artifact", "--output"]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!required.has(flag))
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

function readJson(path, label) {
  try {
    return JSON.parse(readFileSync(regularFile(path, label), "utf8"));
  } catch (error) {
    throw new Error(`unable to read ${label}: ${error.message}`);
  }
}

function requireHealthDocument(document, expectedStatus, proof, label) {
  if (document?.status !== expectedStatus)
    throw new Error(`${label} status is not ${expectedStatus}`);
  if (
    document.source?.repository !==
      "https://github.com/Imagine-That-Ai/BurnBar" ||
    document.source?.commit !== proof.release.commit
  ) {
    throw new Error(`${label} does not bind the exact released source commit`);
  }
  const expectedDomainCore = {
    profile: proof.profile.value.name,
    candidateIdentity: proof.profile.value.candidateIdentity,
    pricingMode: proof.profile.value.modes.pricing,
  };
  if (!isDeepStrictEqual(document.domainCore, expectedDomainCore)) {
    throw new Error(
      `${label} does not bind the exact deployed domain-core profile`,
    );
  }
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
    const stat = lstatSync(output);
    if (
      !stat.isFile() ||
      stat.isSymbolicLink() ||
      readFileSync(output, "utf8") !== contents
    ) {
      throw new Error(
        `refusing to replace non-identical Functions deployment evidence: ${output}`,
      );
    }
  }
  return output;
}

export function createFunctionsDeploymentEvidence(proof, health) {
  exactObject(
    proof,
    [
      "schemaVersion",
      "proofKind",
      "repository",
      "workflowPath",
      "deployRun",
      "release",
      "profile",
      "compiledReceipt",
      "releaseGate",
    ],
    "Functions deploy proof",
  );
  if (
    proof.schemaVersion !== 1 ||
    proof.proofKind !== "domain-core-functions-deploy-proof" ||
    proof.repository !== "Imagine-That-Ai/BurnBar" ||
    proof.workflowPath !== ".github/workflows/deploy-production.yml"
  ) {
    throw new Error("Functions deploy proof identity is invalid");
  }
  if (health?.project !== "burnbar" || health?.tag !== proof.release.tag) {
    throw new Error(
      "health artifact does not match the Functions project and release tag",
    );
  }
  requireHealthDocument(health.healthLive, "alive", proof, "healthLive");
  requireHealthDocument(health.healthReady, "ready", proof, "healthReady");
  if (health.healthReady.version !== proof.release.tag) {
    throw new Error("healthReady version does not match the release tag");
  }
  if (
    health.healthReady.sentry?.enabled !== true ||
    health.healthReady.sentry?.environment !== "production"
  ) {
    throw new Error("healthReady does not prove production Sentry enablement");
  }
  return {
    provider: "firebase-functions",
    project: "burnbar",
    environment: "production",
    status: "healthy",
    healthChecks: [
      "healthLive",
      "healthReady",
      "sourceCommit",
      "functionVersion",
      "sentry",
      "domainCoreProfile",
    ],
    deployedArtifact: structuredClone(proof.compiledReceipt),
  };
}

export function run(argv) {
  const args = parseArguments(argv);
  const evidence = createFunctionsDeploymentEvidence(
    readJson(resolve(args.get("--deploy-proof")), "Functions deploy proof"),
    readJson(
      resolve(args.get("--health-artifact")),
      "Functions health artifact",
    ),
  );
  const output = writeCreateOnly(
    args.get("--output"),
    `${JSON.stringify(evidence, null, 2)}\n`,
  );
  process.stdout.write(`${JSON.stringify({ ok: true, output, evidence })}\n`);
  return evidence;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
