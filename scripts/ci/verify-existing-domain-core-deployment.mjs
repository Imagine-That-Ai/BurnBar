#!/usr/bin/env node

import { createHash } from "node:crypto";
import { isDeepStrictEqual } from "node:util";
import { lstatSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

function bytes(path, label) {
  const absolute = resolve(path);
  const stat = lstatSync(absolute);
  if (!stat.isFile() || stat.isSymbolicLink())
    throw new Error(`${label} must be a regular file`);
  return readFileSync(absolute);
}

function json(path, label) {
  return JSON.parse(bytes(path, label));
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function exactTargetSet(targets, expected, label) {
  if (
    !Array.isArray(targets) ||
    targets.length !== expected.length ||
    new Set(targets.map((item) => item?.target)).size !== expected.length ||
    expected.some((target) => !targets.some((item) => item?.target === target))
  ) {
    throw new Error(
      `${label} does not exactly match the protected target inventory`,
    );
  }
}

export function verifyExistingDeployment({
  consumer,
  receipt,
  tag,
  commit,
  artifactBytes,
  live,
  providerCoordinates,
  inventory,
}) {
  if (
    receipt?.schemaVersion !== 2 ||
    receipt?.consumer !== consumer ||
    receipt?.release?.tag !== tag ||
    receipt?.release?.commit !== commit ||
    receipt?.candidate?.candidateCommit !== commit ||
    receipt?.deployment?.status !== "healthy" ||
    receipt?.deployment?.deployedArtifact?.sha256 !== sha256(artifactBytes)
  ) {
    throw new Error(
      "existing evidence does not match the exact stable deployment artifact",
    );
  }
  const coordinates = receipt.deployment.providerCoordinates;
  if (!isDeepStrictEqual(providerCoordinates, coordinates)) {
    throw new Error(
      `current ${consumer} provider coordinates differ from existing evidence`,
    );
  }
  if (consumer === "console") {
    if (!Buffer.from(live).equals(artifactBytes))
      throw new Error(
        "live Console runtime manifest differs from existing evidence",
      );
    const expectedSites = ["console", "marketing"];
    exactTargetSet(coordinates?.sites, expectedSites, "Hosting coordinates");
  } else if (consumer === "functions") {
    if (
      inventory?.schemaVersion !== 1 ||
      !Array.isArray(inventory.targets) ||
      inventory.targets.length === 0 ||
      new Set(inventory.targets).size !== inventory.targets.length ||
      inventory.targets.some(
        (target) => !/^[A-Za-z][A-Za-z0-9]*$/u.test(target),
      )
    ) {
      throw new Error("protected Functions target inventory is invalid");
    }
    exactTargetSet(
      coordinates?.targets,
      inventory.targets,
      "Functions receipt coordinates",
    );
    exactTargetSet(
      providerCoordinates?.targets,
      inventory.targets,
      "current Functions coordinates",
    );
    const healthTargets = ["healthLive", "healthReady"];
    if (
      !live ||
      Object.keys(live).length !== healthTargets.length ||
      healthTargets.some((target) => !Object.hasOwn(live, target))
    ) {
      throw new Error(
        "live Functions health documents are incomplete or unexpected",
      );
    }
    for (const target of healthTargets) {
      const document = live[target];
      if (
        document?.domainCore?.artifactManifest?.sha256 !== sha256(artifactBytes)
      ) {
        throw new Error(
          `${target} live artifact manifest differs from existing evidence`,
        );
      }
      const expected = coordinates?.targets?.find(
        (item) => item.target === target,
      );
      if (
        !expected ||
        expected.revision !== document.domainCore.runtime?.revision ||
        !expected.service.endsWith(`/${document.domainCore.runtime?.service}`)
      ) {
        throw new Error(
          `${target} live revision differs from existing evidence`,
        );
      }
    }
    if (coordinates?.buildArtifactSha256 !== sha256(artifactBytes)) {
      throw new Error(
        "existing Functions build coordinate differs from runtime artifact",
      );
    }
  } else {
    throw new Error("consumer must be console or functions");
  }
  return {
    reused: true,
    providerCoordinates: receipt.deployment.providerCoordinates,
  };
}

function args(argv) {
  const values = new Map();
  const allowed = new Set([
    "--consumer",
    "--receipt",
    "--tag",
    "--commit",
    "--artifact",
    "--live",
    "--provider-coordinates",
    "--inventory",
  ]);
  for (let index = 0; index < argv.length; index += 2) {
    if (
      !allowed.has(argv[index]) ||
      !argv[index + 1] ||
      values.has(argv[index])
    ) {
      throw new Error(`invalid or duplicate argument ${String(argv[index])}`);
    }
    values.set(argv[index], argv[index + 1]);
  }
  for (const flag of [
    "--consumer",
    "--receipt",
    "--tag",
    "--commit",
    "--artifact",
    "--live",
    "--provider-coordinates",
  ]) {
    if (!values.get(flag)) throw new Error(`${flag} is required`);
  }
  if (values.get("--consumer") === "functions" && !values.get("--inventory")) {
    throw new Error(
      "--inventory is required for Functions replay verification",
    );
  }
  return values;
}

export function run(argv) {
  const values = args(argv);
  const consumer = values.get("--consumer");
  const live =
    consumer === "console"
      ? bytes(values.get("--live"), "live Console runtime manifest")
      : json(values.get("--live"), "live Functions health documents");
  const result = verifyExistingDeployment({
    consumer,
    receipt: json(values.get("--receipt"), "existing deployment receipt"),
    tag: values.get("--tag"),
    commit: values.get("--commit"),
    artifactBytes: bytes(
      values.get("--artifact"),
      "local runtime artifact manifest",
    ),
    live,
    providerCoordinates: json(
      values.get("--provider-coordinates"),
      "current provider coordinates",
    ),
    inventory: values.get("--inventory")
      ? json(values.get("--inventory"), "protected Functions target inventory")
      : undefined,
  });
  process.stdout.write(`${JSON.stringify(result)}\n`);
  return result;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
