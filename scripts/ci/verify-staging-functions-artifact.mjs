#!/usr/bin/env node

import { createHash } from "node:crypto";
import { lstatSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, resolve, sep } from "node:path";

const MAX_ARTIFACT_BYTES = 128 * 1024 * 1024;
const MAX_ARTIFACT_FILES = 10_000;
// 3.5 deploy codebases. The artifact ships only the codebases involved in the
// scoped targets, so any non-empty subset of these dirs is valid.
const CODEBASE_DIRS = [
  "functions",
  "functions-identity",
  "functions-sync",
  "functions-media",
];
const REQUIRED_TOP_LEVEL_ENTRIES = ["CANDIDATE_SHA", "SHA256SUMS"];
const ALLOWED_APP_STORE_CERTIFICATES = new Set([
  "lib/domains/billing/appstore/certs/AppleIncRootCertificate.cer",
  "lib/domains/billing/appstore/certs/AppleRootCA-G2.cer",
  "lib/domains/billing/appstore/certs/AppleRootCA-G3.cer",
]);
const ALLOWED_VENDOR_FILES = new Set([
  "vendor/openburnbar/brace-expansion-cjs.tgz",
]);
const ALLOWED_VENDOR_PREFIXES = [
  "vendor/openburnbar/domain-core-wasm/",
  "vendor/openburnbar/entitlements/",
  "vendor/openburnbar/functions-shared/",
  "vendor/openburnbar/signal-envelope-contracts/",
];

function usage() {
  console.error(
    "Usage: verify-staging-functions-artifact.mjs --artifact-root <path> --candidate-sha <40-hex-sha>",
  );
}

function parseArgs(argv) {
  const args = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      usage();
      process.exit(2);
    }
    args.set(key, value);
  }
  return {
    artifactRoot: args.get("--artifact-root"),
    candidateSha: args.get("--candidate-sha"),
  };
}

function toPosixPath(path) {
  return sep === "/" ? path : path.split(sep).join("/");
}

function walk(root) {
  const entries = [];
  const visit = (directory) => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const absolutePath = join(directory, entry.name);
      const artifactPath = toPosixPath(relative(root, absolutePath));
      const metadata = lstatSync(absolutePath);
      if (metadata.isSymbolicLink()) {
        throw new Error(`symbolic links are forbidden: ${artifactPath}`);
      }
      if (metadata.isDirectory()) {
        visit(absolutePath);
      } else if (metadata.isFile()) {
        entries.push({
          absolutePath,
          artifactPath,
          bytes: metadata.size,
        });
      } else {
        throw new Error(`unsupported filesystem entry: ${artifactPath}`);
      }
    }
  };
  visit(root);
  return entries.sort((left, right) =>
    left.artifactPath.localeCompare(right.artifactPath),
  );
}

function isAllowedFunctionsPath(path) {
  if (
    path === "package.json" ||
    path === "package-lock.json" ||
    path === ".env.burnbar-staging"
  ) {
    return true;
  }
  if (ALLOWED_APP_STORE_CERTIFICATES.has(path)) return true;
  if (
    path.startsWith("lib/") &&
    (path.endsWith(".js") || path.endsWith(".js.map") || path.endsWith(".cjs"))
  ) {
    return true;
  }
  if (ALLOWED_VENDOR_FILES.has(path)) return true;
  return ALLOWED_VENDOR_PREFIXES.some((prefix) => path.startsWith(prefix));
}

function parseManifest(source) {
  const entries = new Map();
  for (const line of source.split(/\r?\n/u)) {
    if (line.length === 0) continue;
    const match =
      /^([a-f0-9]{64})  ((?:functions|functions-identity|functions-sync|functions-media)\/.+)$/u.exec(
        line,
      );
    if (!match) throw new Error(`invalid SHA256SUMS line: ${line}`);
    const [, digest, path] = match;
    if (
      path.startsWith("/") ||
      path.includes("\\") ||
      path.split("/").includes("..")
    ) {
      throw new Error(`unsafe SHA256SUMS path: ${path}`);
    }
    if (entries.has(path)) {
      throw new Error(`duplicate SHA256SUMS path: ${path}`);
    }
    entries.set(path, digest);
  }
  return entries;
}

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function verify() {
  const { artifactRoot: artifactRootArg, candidateSha } = parseArgs(
    process.argv.slice(2),
  );
  if (!artifactRootArg || !candidateSha) {
    usage();
    process.exit(2);
  }
  if (!/^[a-f0-9]{40}$/u.test(candidateSha)) {
    throw new Error(
      "candidate SHA must be exactly 40 lowercase hex characters",
    );
  }

  const artifactRoot = resolve(artifactRootArg);
  if (!statSync(artifactRoot).isDirectory()) {
    throw new Error(`artifact root is not a directory: ${artifactRoot}`);
  }

  const topLevelEntries = readdirSync(artifactRoot).sort();
  const codebaseDirs = topLevelEntries.filter((entry) =>
    CODEBASE_DIRS.includes(entry),
  );
  const expectedTopLevel = [...REQUIRED_TOP_LEVEL_ENTRIES, ...codebaseDirs].sort();
  if (
    codebaseDirs.length === 0 ||
    JSON.stringify(topLevelEntries) !== JSON.stringify(expectedTopLevel)
  ) {
    throw new Error(
      `unexpected top-level artifact entries: ${topLevelEntries.join(", ")}`,
    );
  }

  const recordedSha = readFileSync(
    join(artifactRoot, "CANDIDATE_SHA"),
    "utf8",
  ).trim();
  if (recordedSha !== candidateSha) {
    throw new Error(
      `candidate SHA mismatch: expected ${candidateSha}, received ${recordedSha}`,
    );
  }

  const files = walk(artifactRoot);
  const functionsFiles = files.filter((file) =>
    codebaseDirs.some((dir) => file.artifactPath.startsWith(`${dir}/`)),
  );
  if (functionsFiles.length === 0) {
    throw new Error("Functions artifact contains no deployable files");
  }
  if (functionsFiles.length > MAX_ARTIFACT_FILES) {
    throw new Error(`Functions artifact exceeds ${MAX_ARTIFACT_FILES} files`);
  }
  const totalBytes = files.reduce((sum, file) => sum + file.bytes, 0);
  if (totalBytes > MAX_ARTIFACT_BYTES) {
    throw new Error(`Functions artifact exceeds ${MAX_ARTIFACT_BYTES} bytes`);
  }

  for (const file of functionsFiles) {
    const codebaseDir = codebaseDirs.find((dir) =>
      file.artifactPath.startsWith(`${dir}/`),
    );
    const functionsPath = file.artifactPath.slice(codebaseDir.length + 1);
    if (!isAllowedFunctionsPath(functionsPath)) {
      throw new Error(`unexpected Functions artifact path: ${file.artifactPath}`);
    }
  }

  for (const codebaseDir of codebaseDirs) {
    const packageJson = JSON.parse(
      readFileSync(join(artifactRoot, codebaseDir, "package.json"), "utf8"),
    );
    if (Object.keys(packageJson.scripts ?? {}).length > 0) {
      throw new Error(
        `Functions deployment package ${codebaseDir} retains executable npm scripts`,
      );
    }
    if (packageJson.devDependencies !== undefined) {
      throw new Error(
        `Functions deployment package ${codebaseDir} retains development dependencies`,
      );
    }
    const overrideValues = JSON.stringify(packageJson.overrides ?? {});
    if (overrideValues.includes('"$')) {
      throw new Error(
        `Functions deployment package ${codebaseDir} retains an npm dependency alias override`,
      );
    }

    const lockfile = JSON.parse(
      readFileSync(
        join(artifactRoot, codebaseDir, "package-lock.json"),
        "utf8",
      ),
    );
    if (lockfile.packages?.[""]?.devDependencies !== undefined) {
      throw new Error(
        `Functions deployment lockfile ${codebaseDir} retains development dependencies`,
      );
    }
    if (lockfile.packages?.[""]?.hasInstallScript !== undefined) {
      throw new Error(
        `Functions deployment lockfile ${codebaseDir} retains an install-script marker`,
      );
    }
    for (const [path, entry] of Object.entries(lockfile.packages ?? {})) {
      if (entry?.dev === true) {
        throw new Error(
          `Functions deployment lockfile ${codebaseDir} retains dev-only package ${path}`,
        );
      }
    }
    for (const path of [
      "node_modules/firebase-tools",
      "node_modules/openburnbar-brace-expansion-cjs",
    ]) {
      if (lockfile.packages?.[path] !== undefined) {
        throw new Error(
          `Functions deployment lockfile ${codebaseDir} retains dev-only package ${path}`,
        );
      }
    }
  }

  const manifest = parseManifest(
    readFileSync(join(artifactRoot, "SHA256SUMS"), "utf8"),
  );
  const expectedPaths = functionsFiles.map((file) => file.artifactPath).sort();
  const manifestPaths = [...manifest.keys()].sort();
  if (JSON.stringify(manifestPaths) !== JSON.stringify(expectedPaths)) {
    throw new Error(
      "SHA256SUMS must contain every Functions file exactly once",
    );
  }
  for (const file of functionsFiles) {
    const expectedDigest = manifest.get(file.artifactPath);
    const actualDigest = sha256(file.absolutePath);
    if (actualDigest !== expectedDigest) {
      throw new Error(`SHA-256 mismatch: ${file.artifactPath}`);
    }
  }

  console.log(
    `PASS: verified ${functionsFiles.length} bounded staging Functions files before authentication.`,
  );
}

try {
  verify();
} catch (error) {
  console.error(
    `Staging Functions artifact verification failed: ${error instanceof Error ? error.message : String(error)}`,
  );
  process.exit(1);
}
