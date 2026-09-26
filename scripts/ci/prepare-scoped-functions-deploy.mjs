#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  appendFileSync,
  existsSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

import { prepareFunctionsRuntimePackage } from "./prepare-functions-runtime-package.mjs";

const SCHEMA_VERSION = "openburnbar.staging-function-targets.v2";
// 3.5 deploy codebases, resolved relative to --functions-dir (the admin
// codebase, which also hosts the staging target manifest).
const CODEBASE_DIRS = {
  admin: ".",
  identity: "../functions-identity",
  sync: "../functions-sync",
  media: "../functions-media",
};
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
const manifestPath = join(functionsDir, "staging-deploy-targets.json");

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
for (const targetName of requestedNames) {
  if (!TARGETS_RE.test(`functions:${targetName}`))
    fail(`target ${targetName} is not a valid Firebase Functions selector`);
}
if (new Set(requestedNames).size !== requestedNames.length)
  fail("targets must not contain duplicates");

const byCodebase = new Map();
for (const targetName of requestedNames) {
  const entry = manifest.targets[targetName];
  if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
    fail(`target ${targetName} is not approved for scoped staging deployment`);
  }
  const moduleSpecifier = entry.module;
  const exportName = entry.export;
  const codebase = entry.codebase;
  if (
    typeof moduleSpecifier !== "string" ||
    typeof exportName !== "string" ||
    !EXPORT_RE.test(exportName) ||
    typeof codebase !== "string" ||
    !(codebase in CODEBASE_DIRS)
  ) {
    fail(`target ${targetName} has an invalid manifest binding`);
  }
  if (!byCodebase.has(codebase)) byCodebase.set(codebase, []);
  byCodebase.get(codebase).push({ targetName, moduleSpecifier, exportName });
}

const involvedCodebases = [...byCodebase.keys()].sort();
const digests = [];
for (const codebase of involvedCodebases) {
  const codebaseDir = resolve(functionsDir, CODEBASE_DIRS[codebase]);
  const packagePath = join(codebaseDir, "package.json");
  const libDir = join(codebaseDir, "lib");
  const outputPath = join(libDir, "staging-scoped-index.cjs");
  const packageJson = readJson(packagePath, `${codebase} package.json`);
  if (packageJson.main !== "lib/index.js") {
    fail(
      `${codebase} package.json must use the canonical lib/index.js entrypoint before preparation`,
    );
  }

  // Candidate source is built and tested before artifact packaging. The trusted
  // deploy artifact contains compiled lib/ plus locked local packages only, so no
  // npm lifecycle/build/test script is valid inside Cloud Build. Removing every
  // script also prevents candidate-controlled lifecycle code from executing
  // after the trusted workflow has authenticated.
  packageJson.scripts = {};

  const modules = new Map();
  const bindings = [];
  for (const { targetName, moduleSpecifier, exportName } of byCodebase.get(
    codebase,
  )) {
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
  prepareFunctionsRuntimePackage(codebaseDir);
  digests.push(
    `${codebase}:sha256=${createHash("sha256").update(generated).digest("hex")}`,
  );
}

// The trusted deploy must receive the resolved selector list so a blank input
// deploys with a filtered `--only functions:<name>,...` scope. An unscoped
// `--only functions` deploy against the scoped entrypoint would ask the
// non-interactive Firebase CLI to delete every remote function missing from
// the manifest and abort. The packaging step also needs the involved codebase
// dirs so the artifact ships only reviewed code.
const resolvedTargets = requestedNames
  .map((targetName) => `functions:${targetName}`)
  .join(",");
if (process.env.GITHUB_OUTPUT) {
  appendFileSync(
    process.env.GITHUB_OUTPUT,
    `function_targets=${resolvedTargets}\n` +
      `involved_codebases=${involvedCodebases
        .map((codebase) =>
          codebase === "admin" ? "functions" : `functions-${codebase}`,
        )
        .join(",")}\n`,
    "utf8",
  );
}

console.log(
  `Scoped staging Functions entrypoints: ${requestedNames.length} reviewed target(s) across ${involvedCodebases.join(",")} (${digests.join(" ")})`,
);
