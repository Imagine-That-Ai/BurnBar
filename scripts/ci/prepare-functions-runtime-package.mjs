#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const DEV_ONLY_OVERRIDE_KEYS = Object.freeze([
  "brace-expansion@^1.1.7",
  "firebase-tools@15.23.0",
]);

function fail(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  let functionsDir = "";
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--functions-dir") {
      functionsDir = argv[++index] ?? fail("--functions-dir requires a value");
    } else {
      fail(`unknown argument: ${value}`);
    }
  }
  if (!functionsDir) fail("--functions-dir is required");
  return { functionsDir };
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
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail(`${label} must be a JSON object`);
  }
  return value;
}

function writeAtomic(path, contents) {
  const temporary = `${path}.tmp-${process.pid}`;
  writeFileSync(temporary, contents, { encoding: "utf8", mode: 0o600 });
  renameSync(temporary, path);
}

function dollarOverridePath(value, path = "overrides") {
  if (typeof value === "string") {
    return value.startsWith("$") ? path : "";
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) return "";
  for (const [key, child] of Object.entries(value)) {
    const found = dollarOverridePath(child, `${path}.${key}`);
    if (found) return found;
  }
  return "";
}

export function createRuntimePackageJson(source) {
  if (!source || typeof source !== "object" || Array.isArray(source)) {
    fail("Functions package.json must be a JSON object");
  }
  const runtimePackage = structuredClone(source);
  runtimePackage.scripts = {};
  delete runtimePackage.devDependencies;

  if (runtimePackage.overrides !== undefined) {
    if (
      !runtimePackage.overrides ||
      typeof runtimePackage.overrides !== "object" ||
      Array.isArray(runtimePackage.overrides)
    ) {
      fail("Functions package.json overrides must be a JSON object");
    }
    for (const key of DEV_ONLY_OVERRIDE_KEYS) {
      delete runtimePackage.overrides[key];
    }
    if (Object.keys(runtimePackage.overrides).length === 0) {
      delete runtimePackage.overrides;
    }
  }

  assertRuntimePackageJson(runtimePackage);
  return runtimePackage;
}

export function assertRuntimePackageJson(packageJson) {
  if (
    !packageJson.scripts ||
    typeof packageJson.scripts !== "object" ||
    Array.isArray(packageJson.scripts) ||
    Object.keys(packageJson.scripts).length !== 0
  ) {
    fail("runtime Functions package must contain an empty scripts object");
  }
  if (packageJson.devDependencies !== undefined) {
    fail("runtime Functions package must not contain devDependencies");
  }
  for (const key of DEV_ONLY_OVERRIDE_KEYS) {
    if (packageJson.overrides?.[key] !== undefined) {
      fail(`runtime Functions package retained dev-only override ${key}`);
    }
  }
  const aliasPath = dollarOverridePath(packageJson.overrides);
  if (aliasPath) {
    fail(
      `runtime Functions package retained npm dependency alias at ${aliasPath}`,
    );
  }
}

export function assertRuntimeLockfile(lockfile, packageJson) {
  if (lockfile.lockfileVersion !== 3) {
    fail("runtime Functions package-lock.json must use lockfileVersion 3");
  }
  const root = lockfile.packages?.[""];
  if (!root || typeof root !== "object" || Array.isArray(root)) {
    fail("runtime Functions package-lock.json is missing its root package");
  }
  if (root.devDependencies !== undefined) {
    fail("runtime Functions lockfile root must not contain devDependencies");
  }
  if (root.hasInstallScript !== undefined) {
    fail("runtime Functions lockfile root must not advertise install scripts");
  }
  const normalizedDependencies = (dependencies) =>
    Object.fromEntries(Object.entries(dependencies ?? {}).sort());
  if (
    JSON.stringify(normalizedDependencies(root.dependencies)) !==
    JSON.stringify(normalizedDependencies(packageJson.dependencies))
  ) {
    fail(
      "runtime Functions lockfile root dependencies do not match package.json",
    );
  }
  for (const [path, entry] of Object.entries(lockfile.packages ?? {})) {
    if (entry?.dev === true) {
      fail(`runtime Functions lockfile retained dev-only package ${path}`);
    }
  }
  for (const path of [
    "node_modules/firebase-tools",
    "node_modules/openburnbar-brace-expansion-cjs",
  ]) {
    if (lockfile.packages?.[path] !== undefined) {
      fail(`runtime Functions lockfile retained dev-only package ${path}`);
    }
  }
}

export function prepareFunctionsRuntimePackage(rawFunctionsDir) {
  const functionsDir = resolve(rawFunctionsDir);
  const packagePath = join(functionsDir, "package.json");
  const lockPath = join(functionsDir, "package-lock.json");
  const runtimePackage = createRuntimePackageJson(
    readJson(packagePath, "Functions package.json"),
  );
  writeAtomic(packagePath, `${JSON.stringify(runtimePackage, null, 2)}\n`);

  const install = spawnSync(
    "npm",
    [
      "install",
      "--package-lock-only",
      "--omit=dev",
      "--ignore-scripts",
      "--offline",
      "--no-audit",
      "--no-fund",
    ],
    {
      cwd: functionsDir,
      encoding: "utf8",
      env: {
        ...process.env,
        npm_config_update_notifier: "false",
      },
    },
  );
  if (install.error) {
    fail(`failed to start npm: ${install.error.message}`);
  }
  if (install.status !== 0) {
    fail(
      `npm could not regenerate the production-only lockfile offline:\n${install.stdout}${install.stderr}`,
    );
  }

  const writtenPackage = readJson(
    packagePath,
    "runtime Functions package.json",
  );
  assertRuntimePackageJson(writtenPackage);
  assertRuntimeLockfile(
    readJson(lockPath, "runtime Functions package-lock.json"),
    writtenPackage,
  );
  return { packagePath, lockPath };
}

function main() {
  const { functionsDir } = parseArgs(process.argv.slice(2));
  prepareFunctionsRuntimePackage(functionsDir);
  process.stdout.write(
    "Prepared deterministic production-only Firebase Functions package.\n",
  );
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    console.error(
      `MISCONFIGURED: ${error instanceof Error ? error.message : String(error)}`,
    );
    process.exitCode = 2;
  }
}
