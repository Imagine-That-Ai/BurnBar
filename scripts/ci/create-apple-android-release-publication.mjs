#!/usr/bin/env node

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { regularFile } from "../lib/domain-core-release-evidence.mjs";
import { validateAppleAndroidPublication } from "./publish-apple-android-release.mjs";

function parseJson(path, label) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`unable to read ${label}: ${error.message}`);
  }
}

function parseArguments(argv) {
  const single = new Set([
    "--apple",
    "--android",
    "--notes",
    "--tag",
    "--commit",
    "--promote",
    "--output",
  ]);
  const values = new Map();
  const assets = [];
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (
      (!single.has(flag) && flag !== "--asset") ||
      !value ||
      value.startsWith("--")
    ) {
      throw new Error(`invalid publication argument: ${String(flag)}`);
    }
    if (flag === "--asset") {
      assets.push(resolve(value));
    } else {
      if (values.has(flag)) throw new Error(`duplicate argument: ${flag}`);
      values.set(flag, value);
    }
  }
  for (const flag of single) {
    if (!values.has(flag)) throw new Error(`${flag} is required`);
  }
  if (assets.length === 0) throw new Error("at least one --asset is required");
  return { values, assets };
}

export function buildAppleAndroidPublication({
  apple,
  android,
  notesPath,
  tag,
  commit,
  promote,
  assets,
}) {
  const version = tag.startsWith("v") ? tag.slice(1) : "";
  return validateAppleAndroidPublication({
    schemaVersion: 1,
    repository: "Imagine-That-Ai/BurnBar",
    tag,
    commit,
    title: `OpenBurnBar ${version}`,
    notesPath: regularFile(resolve(notesPath), "release notes"),
    prerelease: version.split("+", 1)[0].includes("-"),
    promote,
    apple,
    android,
    assets: assets.map((path) => ({
      path: regularFile(resolve(path), "release asset"),
    })),
  });
}

function serializable(publication, generalAssets) {
  return {
    schemaVersion: 1,
    repository: publication.repository,
    tag: publication.tag,
    commit: publication.commit,
    title: publication.title,
    notesPath: publication.notesPath,
    prerelease: publication.prerelease,
    promote: publication.promote,
    apple: {
      schemaVersion: 2,
      repository: publication.apple.repository,
      tag: publication.apple.tag,
      commit: publication.apple.commit,
      consumer: publication.apple.consumer,
      signerWorkflow: publication.apple.signerWorkflow,
      releaseState: publication.apple.releaseState,
      nativeArtifactOnly: publication.apple.nativeArtifactOnly,
      artifactPath: publication.apple.artifactPath,
      bundles: publication.apple.bundles.map(
        ({ domain, assetName, bundlePath, predicatePath }) => ({
          domain,
          assetName,
          bundlePath,
          predicatePath,
        }),
      ),
    },
    android: {
      schemaVersion: 2,
      repository: publication.android.repository,
      tag: publication.android.tag,
      commit: publication.android.commit,
      consumer: publication.android.consumer,
      signerWorkflow: publication.android.signerWorkflow,
      releaseState: publication.android.releaseState,
      nativeArtifactOnly: publication.android.nativeArtifactOnly,
      artifactPath: publication.android.artifactPath,
      bundles: publication.android.bundles.map(
        ({ domain, assetName, bundlePath, predicatePath }) => ({
          domain,
          assetName,
          bundlePath,
          predicatePath,
        }),
      ),
    },
    assets: generalAssets.map((path) => ({ path })),
  };
}

export function run(argv) {
  const { values, assets } = parseArguments(argv);
  const publication = buildAppleAndroidPublication({
    apple: parseJson(
      resolve(values.get("--apple")),
      "Apple publication manifest",
    ),
    android: parseJson(
      resolve(values.get("--android")),
      "Android publication manifest",
    ),
    notesPath: values.get("--notes"),
    tag: values.get("--tag"),
    commit: values.get("--commit"),
    promote: values.get("--promote") === "true",
    assets,
  });
  if (!new Set(["true", "false"]).has(values.get("--promote"))) {
    throw new Error("--promote must be true or false");
  }
  const output = resolve(values.get("--output"));
  const contents = `${JSON.stringify(serializable(publication, assets), null, 2)}\n`;
  mkdirSync(dirname(output), { recursive: true });
  try {
    writeFileSync(output, contents, {
      encoding: "utf8",
      flag: "wx",
      mode: 0o600,
    });
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    regularFile(output, "immutable Apple and Android publication manifest");
    if (readFileSync(output, "utf8") !== contents) {
      throw new Error("refusing to replace non-identical publication manifest");
    }
  }
  process.stdout.write(`${JSON.stringify({ ok: true, output })}\n`);
  return publication;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
