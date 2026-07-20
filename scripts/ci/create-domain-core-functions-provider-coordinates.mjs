#!/usr/bin/env node

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { readRegularFileSync } from "../lib/atomic-regular-file.mjs";

const FULL_SHA = /^[0-9a-f]{40}$/u;
const SHA256 = /^[0-9a-f]{64}$/u;

function json(path, label) {
  return JSON.parse(
    readRegularFileSync(resolve(path), { encoding: "utf8", label }),
  );
}

function requiredString(value, label) {
  if (typeof value !== "string" || value.length === 0)
    throw new Error(`${label} must be nonempty`);
  return value;
}

export function buildFunctionsProviderCoordinates({
  inventory,
  descriptions,
  tag,
  commit,
  artifactSha256,
}) {
  if (
    inventory?.schemaVersion !== 1 ||
    !Array.isArray(inventory.targets) ||
    inventory.targets.length === 0
  ) {
    throw new Error("Functions target inventory is invalid");
  }
  if (
    new Set(inventory.targets).size !== inventory.targets.length ||
    inventory.targets.some((target) => !/^[A-Za-z][A-Za-z0-9]*$/u.test(target))
  ) {
    throw new Error(
      "Functions target inventory contains invalid or duplicate targets",
    );
  }
  if (
    !/^v\d+\.\d+\.\d+(?:\+[0-9A-Za-z.-]+)?$/u.test(tag) ||
    !FULL_SHA.test(commit) ||
    !SHA256.test(artifactSha256)
  ) {
    throw new Error("Functions release coordinates are invalid");
  }
  const expected = new Map(
    descriptions.map((item) => [item.target, item.value]),
  );
  if (
    descriptions.length !== inventory.targets.length ||
    expected.size !== inventory.targets.length ||
    inventory.targets.some((target) => !expected.has(target))
  ) {
    throw new Error(
      "Functions descriptions do not exactly match the protected target inventory",
    );
  }
  let sharedSource;
  const targets = inventory.targets.map((target) => {
    const value = expected.get(target);
    const suffix = `/functions/${target}`;
    if (!value?.name?.endsWith(suffix) || value.state !== "ACTIVE")
      throw new Error(`${target} is not the exact active deployed Function`);
    const environment = value.serviceConfig?.environmentVariables;
    if (
      environment?.FUNCTION_VERSION !== tag ||
      environment?.OPENBURNBAR_SOURCE_COMMIT !== commit ||
      environment?.OPENBURNBAR_DOMAIN_CORE_RUNTIME_MANIFEST_SHA256 !==
        artifactSha256
    ) {
      throw new Error(
        `${target} is not serving the exact release build environment`,
      );
    }
    const source = value.buildConfig?.source?.storageSource;
    const normalizedSource = {
      bucket: requiredString(source?.bucket, `${target} source bucket`),
      object: requiredString(source?.object, `${target} source object`),
      generation: String(source?.generation ?? ""),
    };
    if (!/^[1-9]\d*$/u.test(normalizedSource.generation))
      throw new Error(`${target} source generation is invalid`);
    if (sharedSource === undefined) sharedSource = normalizedSource;
    else if (
      JSON.stringify(sharedSource) !== JSON.stringify(normalizedSource)
    ) {
      throw new Error(
        "domain-core-relevant Functions do not share one immutable provider source object",
      );
    }
    return {
      target,
      function: value.name,
      build: requiredString(value.buildConfig?.build, `${target} build`),
      service: requiredString(
        value.serviceConfig?.service,
        `${target} service`,
      ),
      revision: requiredString(
        value.serviceConfig?.revision,
        `${target} revision`,
      ),
    };
  });
  return {
    buildArtifactSha256: artifactSha256,
    sharedSource,
    targets,
  };
}

function args(argv) {
  const values = new Map();
  const allowed = new Set([
    "--inventory",
    "--descriptions",
    "--tag",
    "--commit",
    "--artifact-sha256",
    "--output",
  ]);
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag) || !value || values.has(flag)) {
      throw new Error(`invalid or duplicate argument ${String(flag)}`);
    }
    values.set(flag, value);
  }
  for (const flag of allowed) {
    if (!values.get(flag)) throw new Error(`${flag} is required`);
  }
  return values;
}

export function run(argv) {
  const values = args(argv);
  const coordinates = buildFunctionsProviderCoordinates({
    inventory: json(values.get("--inventory"), "target inventory"),
    descriptions: json(values.get("--descriptions"), "Function descriptions"),
    tag: values.get("--tag"),
    commit: values.get("--commit"),
    artifactSha256: values.get("--artifact-sha256"),
  });
  const output = resolve(values.get("--output"));
  mkdirSync(dirname(output), { recursive: true });
  writeFileSync(output, `${JSON.stringify(coordinates, null, 2)}\n`, {
    flag: "wx",
    mode: 0o600,
  });
  process.stdout.write(`${JSON.stringify({ output, coordinates })}\n`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
