#!/usr/bin/env node

import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  DOMAIN_CORE_REPOSITORY,
  RELEASE_CONSUMERS,
  regularFile,
  safeAssetName,
} from "../lib/domain-core-release-evidence.mjs";
import {
  createGhClient,
  validateManifest,
  verifyBundle,
} from "./publish-domain-core-release-evidence.mjs";

function parseJson(path, label) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`unable to read ${label}: ${error.message}`);
  }
}

function parseArguments(argv) {
  const required = [
    "--apple-plan",
    "--android-plan",
    "--output-dir",
    "--github-output",
  ];
  if (argv.length !== required.length * 2)
    throw new Error("invalid evidence hydration arguments");
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (
      !required.includes(argv[index]) ||
      values.has(argv[index]) ||
      !argv[index + 1]
    ) {
      throw new Error(
        `invalid evidence hydration argument: ${String(argv[index])}`,
      );
    }
    values.set(argv[index], argv[index + 1]);
  }
  for (const flag of required)
    if (!values.has(flag)) throw new Error(`${flag} is required`);
  return values;
}

function release(client, plan) {
  const tag = client.run([
    "api",
    `repos/${DOMAIN_CORE_REPOSITORY}/commits/${encodeURIComponent(plan.tag)}`,
  ]);
  if (parseJsonText(tag.stdout, "release tag").sha !== plan.commit) {
    throw new Error("release tag moved away from the evidence candidate");
  }
  const result = client.run(
    ["api", `repos/${DOMAIN_CORE_REPOSITORY}/releases/tags/${plan.tag}`],
    { allowFailure: true },
  );
  if (result.status !== 0) {
    const detail = `${result.stderr || ""}\n${result.stdout || ""}`;
    if (/\bHTTP 404\b/u.test(detail)) return null;
    throw new Error(`release lookup failed: ${detail.trim()}`);
  }
  const value = parseJsonText(result.stdout, "release lookup");
  if (
    value.tag_name !== plan.tag ||
    value.target_commitish !== plan.commit ||
    typeof value.draft !== "boolean" ||
    !Array.isArray(value.assets)
  ) {
    throw new Error("release metadata does not match the evidence candidate");
  }
  const names = value.assets.map((asset) => asset?.name);
  if (
    names.some((name) => typeof name !== "string") ||
    new Set(names).size !== names.length
  ) {
    throw new Error("release evidence asset names are invalid");
  }
  for (const name of names) safeAssetName(name, "release evidence asset");
  return { published: !value.draft, names: new Set(names) };
}

function parseJsonText(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${label} returned invalid JSON: ${error.message}`);
  }
}

function download(client, plan, name, directory) {
  client.run([
    "release",
    "download",
    plan.tag,
    "--repo",
    DOMAIN_CORE_REPOSITORY,
    "--pattern",
    name,
    "--dir",
    directory,
  ]);
  return regularFile(join(directory, name), `existing evidence ${name}`);
}

function key(consumer, domain) {
  return `${consumer}_${domain.replace(/[A-Z]/gu, (value) => `_${value.toLowerCase()}`)}_existing`;
}

export function hydrateExistingEvidence(plans, outputDirectory, client) {
  mkdirSync(outputDirectory, { recursive: true });
  const outputs = { release_published: "false" };
  let sharedRelease;
  for (const plan of plans) {
    const contract = RELEASE_CONSUMERS[plan.consumer];
    if (!contract || !new Set(["apple", "android"]).has(plan.consumer)) {
      throw new Error(
        "evidence hydration accepts only Apple and Android plans",
      );
    }
    const state = release(client, plan);
    if (sharedRelease === undefined) sharedRelease = state;
    else if (
      (sharedRelease?.published ?? null) !== (state?.published ?? null)
    ) {
      throw new Error(
        "Apple and Android plans observed inconsistent release state",
      );
    }
    if (state?.published) outputs.release_published = "true";
    for (const domain of contract.domains)
      outputs[key(plan.consumer, domain)] = "false";
    for (const entry of plan.domains) {
      safeAssetName(entry.bundleAssetName, "planned evidence asset");
      if (!state?.names.has(entry.bundleAssetName)) continue;
      const bundlePath = download(
        client,
        plan,
        entry.bundleAssetName,
        outputDirectory,
      );
      const manifest = validateManifest({
        schemaVersion: 2,
        repository: DOMAIN_CORE_REPOSITORY,
        tag: plan.tag,
        commit: plan.commit,
        consumer: plan.consumer,
        signerWorkflow: plan.signerWorkflow,
        releaseState: "draft-then-publish",
        nativeArtifactOnly: false,
        artifactPath: plan.artifactPath,
        bundles: [
          {
            domain: entry.domain,
            assetName: entry.bundleAssetName,
            bundlePath,
            predicatePath: entry.predicatePath,
          },
        ],
      });
      verifyBundle(
        client,
        manifest,
        manifest.bundles[0],
        manifest.artifactPath,
        bundlePath,
      );
      outputs[key(plan.consumer, entry.domain)] = "true";
    }
  }
  return outputs;
}

export function run(argv) {
  const args = parseArguments(argv);
  const plans = [
    parseJson(resolve(args.get("--apple-plan")), "Apple evidence plan"),
    parseJson(resolve(args.get("--android-plan")), "Android evidence plan"),
  ];
  const outputs = hydrateExistingEvidence(
    plans,
    resolve(args.get("--output-dir")),
    createGhClient(),
  );
  appendFileSync(
    resolve(args.get("--github-output")),
    `${Object.entries(outputs)
      .map(([name, value]) => `${name}=${value}`)
      .join("\n")}\n`,
  );
  process.stdout.write(`${JSON.stringify({ ok: true, ...outputs })}\n`);
  return outputs;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
