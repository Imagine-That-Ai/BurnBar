#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const args = process.argv.slice(2);

let sourcePath = resolve(repoRoot, "firebase.json");
let outputPath = resolve(repoRoot, "firebase-hosting.ci.json");
let manifestPath = "";
let mode = "hosting";
let check = false;

function usage() {
  console.error(
    [
      "Usage: node scripts/ci/write-firebase-hosting-ci-config.mjs [options]",
      "",
      "Options:",
      "  --source <path>     Firebase config to read (default: firebase.json)",
      "  --output <path>     CI config to write (default: firebase-hosting.ci.json)",
      "  --manifest <path>   Public-dir manifest path for hosting mode",
      "  --mode <mode>       hosting | functions | firestore (default: hosting)",
      "  --check             Verify the generated config contains no predeploy hooks",
    ].join("\n"),
  );
}

for (let index = 0; index < args.length; index += 1) {
  const arg = args[index];
  if (arg === "--source") {
    sourcePath = resolve(repoRoot, args[++index] ?? "");
  } else if (arg === "--output") {
    outputPath = resolve(repoRoot, args[++index] ?? "");
  } else if (arg === "--manifest") {
    manifestPath = resolve(repoRoot, args[++index] ?? "");
  } else if (arg === "--mode") {
    mode = args[++index] ?? "";
  } else if (arg === "--check") {
    check = true;
  } else if (arg === "--help" || arg === "-h") {
    usage();
    process.exit(0);
  } else {
    throw new Error(`Unknown argument: ${arg}`);
  }
}

const supportedModes = new Set(["hosting", "functions", "firestore"]);
if (!supportedModes.has(mode)) {
  throw new Error(`Unsupported mode ${mode}; expected one of ${[...supportedModes].join(", ")}`);
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`Failed to parse ${path}: ${error.message}`);
  }
}

function assertNoPredeploy(value, label) {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => assertNoPredeploy(entry, `${label}[${index}]`));
    return;
  }
  if (!value || typeof value !== "object") return;
  for (const [key, child] of Object.entries(value)) {
    if (key === "predeploy") {
      throw new Error(`${label} still contains a predeploy hook`);
    }
    assertNoPredeploy(child, `${label}.${key}`);
  }
}

function requirePlainObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value;
}

function copyDefined(source, keys) {
  const result = {};
  for (const key of keys) {
    if (Object.prototype.hasOwnProperty.call(source, key)) {
      result[key] = source[key];
    }
  }
  return result;
}

function buildHostingConfig(firebaseJson) {
  const hosting = firebaseJson.hosting;
  if (!Array.isArray(hosting)) {
    throw new Error("firebase.json hosting must be an array for CI hosting deploys");
  }

  const expectedPublicDirs = new Map([
    ["marketing", "website/dist"],
    ["console", "apps/console/out"],
  ]);
  const allowedHostingKeys = new Set([
    "target",
    "public",
    "ignore",
    "headers",
    "redirects",
    "rewrites",
    "cleanUrls",
    "trailingSlash",
    "i18n",
    "predeploy",
  ]);
  const preservedKeys = [
    "target",
    "public",
    "ignore",
    "headers",
    "redirects",
    "rewrites",
    "cleanUrls",
    "trailingSlash",
    "i18n",
  ];

  const seenTargets = new Set();
  const ciHosting = [];

  for (const entry of hosting) {
    requirePlainObject(entry, "hosting entry");
    for (const key of Object.keys(entry)) {
      if (!allowedHostingKeys.has(key)) {
        throw new Error(`hosting target ${entry.target ?? "<missing>"} has unsupported key ${key}`);
      }
    }

    const target = entry.target;
    if (!expectedPublicDirs.has(target)) {
      throw new Error(`unexpected hosting target ${target ?? "<missing>"}`);
    }
    if (seenTargets.has(target)) {
      throw new Error(`duplicate hosting target ${target}`);
    }
    seenTargets.add(target);

    const expectedPublic = expectedPublicDirs.get(target);
    if (entry.public !== expectedPublic) {
      throw new Error(
        `hosting target ${target} public dir drifted: ${entry.public ?? "<missing>"} != ${expectedPublic}`,
      );
    }

    ciHosting.push(copyDefined(entry, preservedKeys));
  }

  for (const target of expectedPublicDirs.keys()) {
    if (!seenTargets.has(target)) {
      throw new Error(`missing hosting target ${target}`);
    }
  }

  const config = { hosting: ciHosting };
  assertNoPredeploy(config, "firebase-hosting.ci.json");
  return {
    config,
    manifest: {
      hostingPublicDirs: Object.fromEntries(expectedPublicDirs.entries()),
    },
  };
}

function buildFunctionsConfig(firebaseJson) {
  const functions = requirePlainObject(firebaseJson.functions, "firebase.json functions");
  const allowedKeys = new Set(["source", "runtime", "ignore", "codebase", "predeploy"]);
  for (const key of Object.keys(functions)) {
    if (!allowedKeys.has(key)) {
      throw new Error(`functions config has unsupported key ${key}`);
    }
  }
  const config = {
    functions: copyDefined(functions, ["source", "runtime", "ignore", "codebase"]),
  };
  assertNoPredeploy(config, "firebase-functions.ci.json");
  return { config, manifest: { functionsSource: config.functions.source } };
}

function buildFirestoreConfig(firebaseJson) {
  const config = {};
  if (firebaseJson.firestore !== undefined) {
    config.firestore = firebaseJson.firestore;
  }
  if (firebaseJson.storage !== undefined) {
    config.storage = firebaseJson.storage;
  }
  if (!config.firestore && !config.storage) {
    throw new Error("firebase.json must contain firestore or storage config for firestore mode");
  }
  assertNoPredeploy(config, "firebase-firestore.ci.json");
  return {
    config,
    manifest: {
      firestoreRules: config.firestore?.rules,
      firestoreIndexes: config.firestore?.indexes,
      storageRules: config.storage?.rules,
    },
  };
}

const firebaseJson = readJson(sourcePath);
const builders = {
  hosting: buildHostingConfig,
  functions: buildFunctionsConfig,
  firestore: buildFirestoreConfig,
};
const { config, manifest } = builders[mode](firebaseJson);
assertNoPredeploy(config, outputPath);

writeFileSync(outputPath, `${JSON.stringify(config, null, 2)}\n`);
if (manifestPath) {
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
}

if (check) {
  const generated = readJson(outputPath);
  assertNoPredeploy(generated, outputPath);
}

console.log(`Wrote ${mode} Firebase CI config without predeploy hooks: ${outputPath}`);
if (manifestPath) {
  console.log(`Wrote ${mode} Firebase CI manifest: ${manifestPath}`);
}
