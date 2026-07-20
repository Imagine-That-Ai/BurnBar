#!/usr/bin/env node

import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { fileURLToPath } from "node:url";

import {
  exactObject,
  regularFile,
} from "../lib/domain-core-release-evidence.mjs";
import { readRegularFileSync } from "../lib/atomic-regular-file.mjs";

function parseArguments(argv) {
  const required = new Set([
    "--deploy-proof",
    "--health-artifact",
    "--deploy-run-verification",
    "--provider-coordinates",
    "--inventory",
    "--output",
  ]);
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
    return JSON.parse(
      readRegularFileSync(regularFile(path, label), {
        encoding: "utf8",
        label,
      }),
    );
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
  const domainCore = document.domainCore;
  const candidate = proof.profile.value.candidateIdentity;
  const wasm = proof.runtimeArtifact.value.files.find(
    (file) =>
      file.path ===
      "vendor/openburnbar/domain-core-wasm/openburnbar_domain_core_bg.wasm",
  );
  if (
    domainCore?.profile !== proof.profile.value.name ||
    !isDeepStrictEqual(domainCore?.candidateIdentity, candidate) ||
    domainCore?.pricingMode !== proof.profile.value.modes.pricing ||
    !isDeepStrictEqual(domainCore?.loadedCore, {
      version: candidate.coreVersion,
      abiVersion: candidate.abiVersion,
      sourceSha256: candidate.sourceSha256,
      wasmSha256: wasm?.sha256,
    }) ||
    !isDeepStrictEqual(domainCore?.artifactManifest, {
      fileName: proof.runtimeArtifact.fileName,
      sha256: proof.runtimeArtifact.sha256,
    }) ||
    !domainCore?.runtime ||
    !["service", "revision", "configuration", "functionTarget"].every(
      (key) =>
        typeof domainCore.runtime[key] === "string" &&
        domainCore.runtime[key].length > 0,
    )
  ) {
    throw new Error(
      `${label} does not bind the exact loaded WASM, runtime manifest, and immutable revision`,
    );
  }
}

function requireDeployRunVerification(raw, proof) {
  const verification = exactObject(
    raw,
    ["schemaVersion", "verificationKind", "deployRun"],
    "Functions deploy-run verification",
  );
  if (
    verification.schemaVersion !== 1 ||
    verification.verificationKind !== "domain-core-functions-deploy-run"
  ) {
    throw new Error("Functions deploy-run verification identity is invalid");
  }
  const deployRun = exactObject(
    verification.deployRun,
    [
      "repository",
      "workflowPath",
      "runId",
      "runAttempt",
      "event",
      "ref",
      "headSha",
      "jobSetSha256",
    ],
    "Functions deploy run",
  );
  const expectedEvent =
    proof.profile.value.name === "public-production-rollback"
      ? "workflow_dispatch"
      : undefined;
  if (
    deployRun.repository !== proof.repository ||
    deployRun.workflowPath !== proof.workflowPath ||
    deployRun.runId !== proof.deployRun.runId ||
    deployRun.runAttempt !== proof.deployRun.runAttempt ||
    !new Set(["push", "workflow_dispatch"]).has(deployRun.event) ||
    (expectedEvent !== undefined && deployRun.event !== expectedEvent) ||
    deployRun.ref !== `refs/tags/${proof.release.tag}` ||
    deployRun.headSha !== proof.release.commit ||
    !/^[0-9a-f]{64}$/u.test(deployRun.jobSetSha256)
  ) {
    throw new Error(
      "Functions deploy-run verification does not match the exact deploy proof",
    );
  }
  return structuredClone(deployRun);
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
        label: "Functions deployment evidence",
      });
    } catch {
      existing = undefined;
    }
    if (existing !== contents) {
      throw new Error(
        `refusing to replace non-identical Functions deployment evidence: ${output}`,
      );
    }
  }
  return output;
}

export function createFunctionsDeploymentEvidence(
  proof,
  health,
  runVerification,
  healthArtifactBytes,
  providerCoordinates,
  inventory,
) {
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
      "runtimeArtifact",
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
  const deployRun = requireDeployRunVerification(runVerification, proof);
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
  const targetNames = providerCoordinates?.targets?.map(
    (target) => target.target,
  );
  if (
    providerCoordinates?.buildArtifactSha256 !== proof.runtimeArtifact.sha256 ||
    !providerCoordinates?.sharedSource ||
    !Array.isArray(providerCoordinates?.targets) ||
    inventory?.schemaVersion !== 1 ||
    !Array.isArray(inventory.targets) ||
    providerCoordinates.targets.length !== inventory.targets.length ||
    new Set(targetNames).size !== inventory.targets.length ||
    inventory.targets.some((target) => !targetNames.includes(target))
  ) {
    throw new Error(
      "Functions provider coordinates do not bind the exact runtime artifact and target inventory",
    );
  }
  for (const [label, document] of [
    ["healthLive", health.healthLive],
    ["healthReady", health.healthReady],
  ]) {
    const runtime = document.domainCore.runtime;
    const coordinate = providerCoordinates.targets.find(
      (target) => target.target === label,
    );
    if (
      !coordinate ||
      coordinate.revision !== runtime.revision ||
      !coordinate.service.endsWith(`/${runtime.service}`)
    ) {
      throw new Error(
        `${label} runtime does not match its immutable provider coordinate`,
      );
    }
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
    deployedArtifact: {
      fileName: proof.runtimeArtifact.fileName,
      sha256: proof.runtimeArtifact.sha256,
    },
    providerCoordinates: structuredClone(providerCoordinates),
    deployRun,
    healthArtifactSha256: createHash("sha256")
      .update(healthArtifactBytes)
      .digest("hex"),
  };
}

export function run(argv) {
  const args = parseArguments(argv);
  const healthArtifactPath = regularFile(
    resolve(args.get("--health-artifact")),
    "Functions health artifact",
  );
  const evidence = createFunctionsDeploymentEvidence(
    readJson(resolve(args.get("--deploy-proof")), "Functions deploy proof"),
    readJson(healthArtifactPath, "Functions health artifact"),
    readJson(
      resolve(args.get("--deploy-run-verification")),
      "Functions deploy-run verification",
    ),
    readRegularFileSync(healthArtifactPath, {
      label: "Functions health artifact",
    }),
    readJson(
      resolve(args.get("--provider-coordinates")),
      "Functions provider coordinates",
    ),
    readJson(
      resolve(args.get("--inventory")),
      "protected Functions target inventory",
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
