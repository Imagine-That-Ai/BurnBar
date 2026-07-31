#!/usr/bin/env node

import { createHash } from "node:crypto";
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

const SCHEMA_VERSION = "openburnbar.staging-function-targets.v1";
const TARGETS_RE =
  /^functions:[A-Za-z][A-Za-z0-9_-]*(,functions:[A-Za-z][A-Za-z0-9_-]*)*$/u;
const MODULE_RE = /^\.\/[A-Za-z0-9_./-]+\.js$/u;
const EXPORT_RE = /^[A-Za-z][A-Za-z0-9_]*$/u;

function fail(message) {
  console.error(`MISCONFIGURED: ${message}`);
  process.exit(2);
}

function parseArgs(argv) {
  const args = { targets: "", functionsDir: "" };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--targets")
      args.targets = argv[++index] ?? fail("--targets requires a value");
    else if (value === "--functions-dir")
      args.functionsDir =
        argv[++index] ?? fail("--functions-dir requires a value");
    else fail(`unknown argument: ${value}`);
  }
  if (!args.functionsDir) fail("--functions-dir is required");
  return args;
}

function readJson(path, label) {
  let value;
  try {
    value = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    fail(
      `${label} is not valid JSON: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
  if (!value || typeof value !== "object" || Array.isArray(value))
    fail(`${label} must be a JSON object`);
  return value;
}

function writeAtomic(path, contents) {
  const temporary = `${path}.tmp-${process.pid}`;
  writeFileSync(temporary, contents, { encoding: "utf8", mode: 0o600 });
  renameSync(temporary, path);
}

function validateModulePath(libDir, moduleSpecifier, targetName) {
  if (
    !MODULE_RE.test(moduleSpecifier) ||
    moduleSpecifier.split("/").includes("..")
  ) {
    fail(`target ${targetName} has an unsafe module path`);
  }
  const modulePath = resolve(libDir, moduleSpecifier.slice(2));
  const relativePath = relative(libDir, modulePath);
  if (
    isAbsolute(relativePath) ||
    relativePath === ".." ||
    relativePath.startsWith(`..${sep}`)
  ) {
    fail(`target ${targetName} escapes the compiled Functions directory`);
  }
  if (!existsSync(modulePath))
    fail(
      `compiled module is missing for target ${targetName}: ${moduleSpecifier}`,
    );
}

const { targets, functionsDir: rawFunctionsDir } = parseArgs(
  process.argv.slice(2),
);
const functionsDir = resolve(rawFunctionsDir);
const packagePath = join(functionsDir, "package.json");
const manifestPath = join(functionsDir, "staging-deploy-targets.json");
const libDir = join(functionsDir, "lib");
const outputPath = join(libDir, "staging-scoped-index.cjs");
const packageJson = readJson(packagePath, "Functions package.json");
if (packageJson.main !== "lib/index.js") {
  fail(
    "Functions package.json must use the canonical lib/index.js entrypoint before preparation",
  );
}

// Candidate source is built and tested before artifact packaging. The trusted
// deploy artifact contains compiled lib/ plus locked local packages only, so no
// npm lifecycle/build/test script is valid inside Cloud Build. Removing every
// script also prevents candidate-controlled lifecycle code from executing
// after the trusted workflow has authenticated.
packageJson.scripts = {};

if (targets && !TARGETS_RE.test(targets))
  fail(
    "targets must be a comma-separated list of explicit Firebase Functions selectors",
  );

const manifest = readJson(manifestPath, "staging target manifest");
if (manifest.schemaVersion !== SCHEMA_VERSION)
  fail(`staging target manifest must use ${SCHEMA_VERSION}`);
if (
  !manifest.targets ||
  typeof manifest.targets !== "object" ||
  Array.isArray(manifest.targets)
) {
  fail("staging target manifest must contain a targets object");
}

const requestedNames = targets
  ? targets.split(",").map((target) => target.slice("functions:".length))
  : Object.keys(manifest.targets);
if (requestedNames.length === 0) {
  fail("staging target manifest must approve at least one Function");
}
if (new Set(requestedNames).size !== requestedNames.length)
  fail("targets must not contain duplicates");

const modules = new Map();
const bindings = [];
for (const targetName of requestedNames) {
  const entry = manifest.targets[targetName];
  if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
    fail(`target ${targetName} is not approved for scoped staging deployment`);
  }
  const moduleSpecifier = entry.module;
  const exportName = entry.export;
  if (
    typeof moduleSpecifier !== "string" ||
    typeof exportName !== "string" ||
    !EXPORT_RE.test(exportName)
  ) {
    fail(`target ${targetName} has an invalid manifest binding`);
  }
  validateModulePath(libDir, moduleSpecifier, targetName);
  if (!modules.has(moduleSpecifier))
    modules.set(moduleSpecifier, `targetModule${modules.size}`);
  bindings.push({
    targetName,
    exportName,
    variable: modules.get(moduleSpecifier),
  });
}

const generated = [
  '"use strict";',
  "// Generated before staging authentication. Do not commit this file.",
  ...[...modules].map(
    ([moduleSpecifier, variable]) =>
      `const ${variable} = require(${JSON.stringify(moduleSpecifier)});`,
  ),
  ...bindings.flatMap(({ targetName, exportName, variable }) => [
    `if (typeof ${variable}[${JSON.stringify(exportName)}] !== "function") {`,
    `  throw new Error(${JSON.stringify(`Scoped staging target ${targetName} is not a function export.`)});`,
    "}",
    `exports[${JSON.stringify(targetName)}] = ${variable}[${JSON.stringify(exportName)}];`,
  ]),
  "",
].join("\n");
writeAtomic(outputPath, generated);

packageJson.main = "lib/staging-scoped-index.cjs";
writeAtomic(packagePath, `${JSON.stringify(packageJson, null, 2)}\n`);

const digest = createHash("sha256").update(generated).digest("hex");
console.log(
  `Scoped staging Functions entrypoint: ${requestedNames.length} reviewed target(s), sha256=${digest}`,
);
