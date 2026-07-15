#!/usr/bin/env node

import { lstatSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { validateManifest } from "./publish-domain-core-release-evidence.mjs";

function readJson(path, label) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`unable to read ${label}: ${error.message}`);
  }
}

function regularFile(path, label) {
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size === 0) {
    throw new Error(`${label} must be a nonempty regular file`);
  }
  return path;
}

function parseArguments(argv) {
  if (argv.length !== 6) {
    throw new Error("usage: --plan PATH --bundle-dir DIR --output PATH");
  }
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (!new Set(["--plan", "--bundle-dir", "--output"]).has(argv[index])) {
      throw new Error(`unknown argument: ${argv[index]}`);
    }
    if (!argv[index + 1] || argv[index + 1].startsWith("--")) {
      throw new Error(`${argv[index]} requires a value`);
    }
    values.set(argv[index], argv[index + 1]);
  }
  return values;
}

export function buildPublicationManifest(plan, bundleDirectory) {
  if (
    plan?.schemaVersion !== 2 ||
    !Array.isArray(plan.domains) ||
    plan.domains.length === 0
  ) {
    throw new Error("native evidence plan must contain at least one v2 domain");
  }
  const seenDomains = new Set();
  const seenAssets = new Set();
  const bundles = plan.domains.map((entry, index) => {
    if (
      !entry ||
      typeof entry.domain !== "string" ||
      typeof entry.predicatePath !== "string" ||
      typeof entry.bundleAssetName !== "string"
    ) {
      throw new Error(`native evidence plan domains[${index}] is invalid`);
    }
    if (seenDomains.has(entry.domain)) {
      throw new Error(`duplicate native evidence domain: ${entry.domain}`);
    }
    if (
      basename(entry.bundleAssetName) !== entry.bundleAssetName ||
      entry.bundleAssetName === "." ||
      entry.bundleAssetName === ".."
    ) {
      throw new Error(
        `native evidence bundle for ${entry.domain} must be a safe basename`,
      );
    }
    if (seenAssets.has(entry.bundleAssetName)) {
      throw new Error(
        `duplicate native evidence bundle asset: ${entry.bundleAssetName}`,
      );
    }
    seenDomains.add(entry.domain);
    seenAssets.add(entry.bundleAssetName);
    return {
      domain: entry.domain,
      assetName: entry.bundleAssetName,
      bundlePath: regularFile(
        join(bundleDirectory, entry.bundleAssetName),
        `attestation bundle for ${entry.domain}`,
      ),
      predicatePath: regularFile(
        resolve(entry.predicatePath),
        `predicate for ${entry.domain}`,
      ),
    };
  });
  return {
    schemaVersion: 2,
    repository: "Imagine-That-Ai/BurnBar",
    tag: plan.tag,
    commit: plan.commit,
    consumer: plan.consumer,
    signerWorkflow: plan.signerWorkflow,
    artifactPath: regularFile(
      resolve(plan.artifactPath),
      "native release artifact",
    ),
    bundles,
  };
}

export function run(argv) {
  const args = parseArguments(argv);
  const manifest = buildPublicationManifest(
    readJson(resolve(args.get("--plan")), "native evidence plan"),
    resolve(args.get("--bundle-dir")),
  );
  validateManifest(manifest);
  const output = resolve(args.get("--output"));
  mkdirSync(dirname(output), { recursive: true });
  const contents = `${JSON.stringify(manifest, null, 2)}\n`;
  try {
    writeFileSync(output, contents, {
      encoding: "utf8",
      flag: "wx",
      mode: 0o600,
    });
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    regularFile(output, "immutable publication manifest");
    if (readFileSync(output, "utf8") !== contents) {
      throw new Error(
        `refusing to replace non-identical publication manifest: ${output}`,
      );
    }
  }
  process.stdout.write(`${JSON.stringify({ ok: true, output })}\n`);
  return manifest;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
