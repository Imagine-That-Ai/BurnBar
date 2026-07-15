#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  writeFileSync,
} from "node:fs";
import { dirname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const SHA256 = /^[0-9a-f]{64}$/u;
const FULL_SHA = /^[0-9a-f]{40}$/u;
const SEMVER =
  /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/u;

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function regularFile(path, label) {
  const absolute = resolve(path);
  const stat = lstatSync(absolute);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error(`${label} must be a regular non-symlink file`);
  }
  return absolute;
}

function walk(root) {
  const files = [];
  function visit(directory) {
    for (const name of readdirSync(directory).sort()) {
      const path = resolve(directory, name);
      const stat = lstatSync(path);
      if (stat.isSymbolicLink())
        throw new Error(`runtime root contains symlink: ${path}`);
      if (stat.isDirectory()) visit(path);
      else if (stat.isFile()) files.push(path);
      else throw new Error(`runtime root contains special file: ${path}`);
    }
  }
  visit(root);
  return files;
}

function fileEntry(root, path) {
  const bytes = readFileSync(path);
  return {
    path: relative(root, path).split(sep).join("/"),
    sha256: sha256(bytes),
    size: bytes.length,
  };
}

function readProfile(path) {
  const profile = JSON.parse(
    readFileSync(regularFile(path, "profile receipt"), "utf8"),
  );
  const candidate = profile?.candidateIdentity;
  if (
    !candidate ||
    !FULL_SHA.test(candidate.candidateCommit) ||
    !SEMVER.test(candidate.coreVersion) ||
    !Number.isSafeInteger(candidate.abiVersion) ||
    candidate.abiVersion < 1 ||
    !SHA256.test(candidate.sourceSha256)
  ) {
    throw new Error("profile receipt lacks a valid candidate identity");
  }
  return { profile: profile.name, candidate };
}

function consoleFiles(root) {
  const all = walk(root);
  const wasm = all.filter((path) => path.endsWith(".wasm"));
  if (wasm.length !== 1)
    throw new Error(
      `Console artifact must contain exactly one WASM file, found ${wasm.length}`,
    );
  const wasmName = wasm[0].split("/").at(-1);
  const glue = all.filter((path) => {
    if (!path.endsWith(".js")) return false;
    const source = readFileSync(path, "utf8");
    return (
      source.includes(wasmName) ||
      source.includes("domainCoreSourceFingerprint")
    );
  });
  if (glue.length === 0)
    throw new Error(
      "Console artifact contains no JavaScript loader for domain-core WASM",
    );
  const required = [
    resolve(root, "domain-core-build-profile.json"),
    resolve(root, "domain-core-deployment-identity.json"),
  ];
  return [
    ...new Set([
      ...required.map((path) => regularFile(path, "Console runtime identity")),
      ...wasm,
      ...glue,
    ]),
  ];
}

function functionsFiles(root) {
  const required = [
    "lib/domainCoreBuildProfile.js",
    "lib/health.js",
    "lib/index.js",
    "lib/domainCorePricing.js",
    "lib/generated/domainCoreCandidateReceipt.js",
    "vendor/openburnbar/domain-core-wasm/openburnbar-domain-core-source.sha256",
    "vendor/openburnbar/domain-core-wasm/openburnbar_domain_core.js",
    "vendor/openburnbar/domain-core-wasm/openburnbar_domain_core_bg.wasm",
    "vendor/openburnbar/domain-core-wasm/package.json",
    "package.json",
    "package-lock.json",
  ];
  return required.map((path) =>
    regularFile(resolve(root, path), `Functions runtime file ${path}`),
  );
}

export function createRuntimeArtifactManifest({
  consumer,
  root,
  profileReceipt,
}) {
  const resolvedRoot = resolve(root);
  const rootStat = lstatSync(resolvedRoot);
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink())
    throw new Error("runtime root must be a directory");
  const { profile, candidate } = readProfile(profileReceipt);
  const selected =
    consumer === "console"
      ? consoleFiles(resolvedRoot)
      : consumer === "functions"
        ? functionsFiles(resolvedRoot)
        : null;
  if (!selected) throw new Error("consumer must be console or functions");
  const files = selected
    .map((path) => fileEntry(resolvedRoot, path))
    .sort((left, right) => left.path.localeCompare(right.path));
  return {
    schemaVersion: 1,
    manifestKind: "domain-core-runtime-artifact",
    consumer,
    profile,
    candidate,
    files,
  };
}

function argumentsFrom(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (
      !new Set(["--consumer", "--root", "--profile-receipt", "--output"]).has(
        flag,
      ) ||
      !value
    ) {
      throw new Error(
        "usage: create-domain-core-runtime-artifact-manifest.mjs --consumer console|functions --root PATH --profile-receipt PATH --output PATH",
      );
    }
    if (values.has(flag)) throw new Error(`duplicate argument ${flag}`);
    values.set(flag, value);
  }
  for (const flag of [
    "--consumer",
    "--root",
    "--profile-receipt",
    "--output",
  ]) {
    if (!values.has(flag)) throw new Error(`${flag} is required`);
  }
  return values;
}

export function run(argv) {
  const args = argumentsFrom(argv);
  const manifest = createRuntimeArtifactManifest({
    consumer: args.get("--consumer"),
    root: args.get("--root"),
    profileReceipt: args.get("--profile-receipt"),
  });
  const output = resolve(args.get("--output"));
  mkdirSync(dirname(output), { recursive: true });
  writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`, {
    flag: "wx",
    mode: 0o600,
  });
  process.stdout.write(
    `${JSON.stringify({ output, sha256: sha256(readFileSync(output)), manifest })}\n`,
  );
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
