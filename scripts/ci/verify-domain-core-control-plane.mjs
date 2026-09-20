#!/usr/bin/env node

import { createHash } from "node:crypto";
import { existsSync, lstatSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, extname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const DEFAULT_MANIFEST = "config/domain-core-control-plane-manifest.json";
const TRUSTED_WORKFLOWS = Object.freeze([
  ".github/workflows/burnbar-ci-gate.yml",
  ".github/workflows/ci-impact.yml",
  ".github/workflows/domain-core.yml",
  ".github/workflows/domain-core-deletion-guard.yml",
  ".github/workflows/domain-core-promotion-proof.yml",
  ".github/workflows/deploy-production.yml",
  ".github/workflows/domain-core-functions-release-evidence.yml",
  ".github/workflows/deploy-hosting.yml",
  ".github/workflows/domain-core-console-release-evidence.yml",
  ".github/workflows/release.yml",
  ".github/workflows/openburnbar-release-windows.yml",
  ".github/workflows/linux-release.yml",
  ".github/workflows/domain-core-ios-release-evidence.yml",
  ".github/workflows/domain-core-post-deletion-completion.yml",
]);
const SEED_PATHS = Object.freeze([
  ...TRUSTED_WORKFLOWS,
  ".firebaserc",
  "OpenBurnBarCore/Package.swift",
  "OpenBurnBarCore/Sources/OpenBurnBarDomainCore/Generated/openburnbar_domain_ffi.swift",
  "OpenBurnBarCore/Sources/OpenBurnBarDomainCoreFFISmoke/main.swift",
  "android/build.gradle.kts",
  "android/gradle.properties",
  "android/gradle/ktlint-android-sources.gradle.kts",
  "android/gradle/wrapper/gradle-wrapper.jar",
  "android/gradle/wrapper/gradle-wrapper.properties",
  "android/gradlew",
  "android/openburnbar-domain-core/build.gradle.kts",
  "android/openburnbar-domain-core/src/androidTest/java/com/openburnbar/domaincore/DomainCoreNativeLoadTest.kt",
  "android/openburnbar-domain-core/src/main/java/uniffi/openburnbar_domain_ffi/openburnbar_domain_ffi.kt",
  "android/settings.gradle.kts",
  "apps/console/package-lock.json",
  "apps/console/package.json",
  "config/domain-core-build-profiles.json",
  "config/domain-core-ci-paths.json",
  "config/domain-core-deployment-receipt.schema.json",
  "config/domain-core-functions-relevant-targets.json",
  "config/domain-core-deterministic-candidate-bundle.schema.json",
  "config/domain-core-promotion-policy.json",
  "governance/burnbar-ci-gate.json",
  "governance/burnbar-ci-gate.fast.json",
  "config/domain-core-release-predicate.schema.json",
  "crates/openburnbar-domain-core/domain-wasm/tests/package-smoke.mjs",
  "crates/openburnbar-domain-core/union-abi-manifest.json",
  "functions/src/domainCoreBuildProfile.ts",
  "functions/src/domainCorePricing.ts",
  "functions/src/__tests__/pricing.test.ts",
  "functions/src/generated/domainCoreCandidateReceipt.ts",
  "functions/src/health.ts",
  // The vendored brace-expansion CJS shim executes inside the Firebase CLI
  // during authenticated deploys. Trust the selecting npm manifest, lockfile,
  // consumed archive, and every checked-in package input used to rebuild it so
  // a candidate cannot redirect or replace the shim after the protected
  // control-plane comparison.
  "functions/package.json",
  "functions/package-lock.json",
  "functions/vendor/openburnbar/brace-expansion-cjs.tgz",
  "functions/vendor/openburnbar/brace-expansion-cjs/README.md",
  "functions/vendor/openburnbar/brace-expansion-cjs/index.js",
  "functions/vendor/openburnbar/brace-expansion-cjs/package.json",
  "functions/vendor/openburnbar/domain-core-wasm/openburnbar-domain-core-source.sha256",
  "functions/vendor/openburnbar/domain-core-wasm/openburnbar_domain_core.js",
  "functions/vendor/openburnbar/domain-core-wasm/openburnbar_domain_core_bg.wasm",
  "functions/vendor/openburnbar/domain-core-wasm/package.json",
  // These decision and mutation helpers were historically discovered through
  // the workflow's push.paths text. Keep them explicit now that exact-main
  // proof runs on every main commit without a path filter.
  "scripts/ci/evaluate-domain-core-promotion.mjs",
  "scripts/ci/domain_core_source_fingerprint.py",
  "scripts/ci/verify-domain-core-control-plane.mjs",
  "scripts/ci/verify-domain-core-legacy-absence.py",
  "scripts/ci/verify-domain-core-protected-attestation.mjs",
  "scripts/ci/write_burnbar_source_provenance.py",
  "scripts/ci/check_agpl_legal_release_review.py",
  "scripts/lib/branch-protection-drift.mjs",
  "scripts/ops/create-domain-core-activation-annulment-receipt.py",
  "scripts/ops/create-domain-core-deletion-plan.py",
  "scripts/ops/create-domain-core-promotion-receipt.py",
  "scripts/ops/create-domain-core-rollback-receipt.py",
  "scripts/ops/create-domain-core-stable-receipt.py",
  "scripts/ops/export-domain-core-promotion-evidence.mjs",
  "scripts/ops/manage-domain-core-shadow-enrollment.mjs",
  "tests/test_domain_core_console_release_evidence_workflow.py",
  "tests/test_domain_core_functions_release_workflow.py",
  "tests/test_domain_core_python_hermes.py",
  "tests/test_domain_core_union_gate.py",
  "tests/fixtures/domain-core/hermes/v1/hermes-crypto-kat.json",
  "tools/hermes-platform-burnbar/adapter.py",
  "tools/hermes-platform-burnbar/domain_core_hermes.py",
  "tools/hermes-platform-burnbar/legacy/__init__.py",
  "tools/hermes-platform-burnbar/legacy/hermes_ratchet_legacy.py",
  "tools/hermes-platform-burnbar/smoke_local.py",
  "tools/hermes-platform-burnbar/vendor/openburnbar-domain-core-python/openburnbar-domain-core-source.sha256",
  "tools/hermes-platform-burnbar/vendor/openburnbar-domain-core-python/openburnbar_domain_ffi.py",
  "windows/Directory.Build.props",
  "windows/Directory.Build.targets",
  "windows/app/OpenBurnBar.App.Configuration/OpenBurnBar.App.Configuration.csproj",
  "windows/app/OpenBurnBar.App.Presentation/OpenBurnBar.App.Presentation.csproj",
  "windows/storage/OpenBurnBar.Storage/OpenBurnBar.Storage.csproj",
  "windows/tests/quota/DomainCoreQuotaBridgeTests.cs",
  "windows/tests/quota/OpenBurnBar.App.Quota.Tests.csproj",
  "crates/openburnbar-domain-core/bindings/csharp/OpenBurnBarDomainCore.Ffi/OpenBurnBarDomainCore.Ffi.csproj",
  "crates/openburnbar-domain-core/bindings/csharp/OpenBurnBarDomainCore.Ffi/generated/openburnbar_domain_ffi.cs",
]);
const EXECUTABLE_REFERENCE =
  /(?:^|[\s"'(])((?:\.\/)?(?:scripts|tools)\/[A-Za-z0-9_./-]+\.(?:js|mjs|py|sh))/gmu;
const LOCAL_IMPORT = /(?:from\s+|import\s*\()(["'])(\.{1,2}\/[^"']+)\1/gmu;
const DYNAMIC_PYTHON_CI_MODULE =
  /load_ci_module\([^,]+,\s*(["'])([A-Za-z_][A-Za-z0-9_]*)\1\s*\)/gmu;

function fail(message) {
  throw new Error(message);
}

function regularRepoFile(root, path, label = "control-plane file") {
  const parts = typeof path === "string" ? path.split("/") : [];
  if (
    typeof path !== "string" ||
    path.length === 0 ||
    path.startsWith("/") ||
    path.includes("\\") ||
    parts.some((part) => part.length === 0 || part === "." || part === "..")
  ) {
    fail(
      `${label} must be a normalized repository-relative path: ${String(path)}`,
    );
  }
  let current = resolve(root);
  for (const [index, part] of parts.entries()) {
    current = resolve(current, part);
    let stat;
    try {
      stat = lstatSync(current);
    } catch (error) {
      fail(`${label} is missing: ${path}: ${error.message}`);
    }
    if (stat.isSymbolicLink())
      fail(`${label} cannot traverse a symlink: ${path}`);
    const isLast = index === parts.length - 1;
    if (isLast ? !stat.isFile() : !stat.isDirectory()) {
      fail(
        `${label} must resolve through directories to a regular file: ${path}`,
      );
    }
  }
  return current;
}

function sha256(root, path) {
  return createHash("sha256")
    .update(readFileSync(regularRepoFile(root, path)))
    .digest("hex");
}

function repoPath(root, absolutePath) {
  const value = relative(root, absolutePath).split(sep).join("/");
  if (!value || value === ".." || value.startsWith("../")) {
    fail(`control-plane path escapes repository: ${absolutePath}`);
  }
  return value;
}

function resolveImport(root, importer, specifier) {
  const base = resolve(dirname(resolve(root, importer)), specifier);
  const candidates = extname(base)
    ? [base]
    : [`${base}.mjs`, `${base}.js`, `${base}.json`, resolve(base, "index.mjs")];
  return candidates.find((candidate) => {
    if (!existsSync(candidate)) return false;
    const path = repoPath(root, candidate);
    try {
      regularRepoFile(root, path, "trusted control-plane import");
      return true;
    } catch {
      return false;
    }
  });
}

export function discoverDomainCoreControlPlane(root = SCRIPT_ROOT) {
  const discovered = new Set(SEED_PATHS);
  for (const workflow of TRUSTED_WORKFLOWS) {
    const source = readFileSync(
      regularRepoFile(root, workflow, "trusted workflow"),
      "utf8",
    );
    for (const match of source.matchAll(EXECUTABLE_REFERENCE)) {
      discovered.add(match[1].replace(/^\.\//u, ""));
    }
  }

  const pending = [...discovered];
  while (pending.length > 0) {
    const path = pending.pop();
    if (
      !path.endsWith(".mjs") &&
      !path.endsWith(".js") &&
      !path.endsWith(".py") &&
      !path.endsWith(".sh")
    )
      continue;
    const absolute = regularRepoFile(root, path, "trusted control-plane file");
    const source = readFileSync(absolute, "utf8");
    const references = [];
    if (path.endsWith(".mjs") || path.endsWith(".js")) {
      for (const match of source.matchAll(LOCAL_IMPORT)) {
        const imported = resolveImport(root, path, match[2]);
        if (!imported) fail(`${path} imports missing local module ${match[2]}`);
        references.push(repoPath(root, imported));
      }
    }
    if (path.endsWith(".py") || path.endsWith(".sh")) {
      for (const match of source.matchAll(EXECUTABLE_REFERENCE))
        references.push(match[1].replace(/^\.\//u, ""));
    }
    if (path.endsWith(".py")) {
      for (const match of source.matchAll(DYNAMIC_PYTHON_CI_MODULE))
        references.push(`scripts/ci/${match[2]}.py`);
    }
    for (const referencedPath of references) {
      regularRepoFile(root, referencedPath, "trusted control-plane dependency");
      if (discovered.has(referencedPath)) continue;
      discovered.add(referencedPath);
      pending.push(referencedPath);
    }
  }
  return [...discovered].sort();
}

export function createDomainCoreControlPlaneManifest(root = SCRIPT_ROOT) {
  return {
    schemaVersion: 2,
    files: Object.fromEntries(
      discoverDomainCoreControlPlane(root).map((path) => [
        path,
        sha256(root, path).match(/.{1,16}/gu),
      ]),
    ),
  };
}

function serializeDomainCoreControlPlaneManifest(manifest) {
  const files = Object.entries(manifest.files)
    .map(
      ([path, chunks]) =>
        `    ${JSON.stringify(path)}: ${JSON.stringify(chunks)}`,
    )
    .join(",\n");
  return `{\n  "schemaVersion": ${manifest.schemaVersion},\n  "files": {\n${files}\n  }\n}\n`;
}

export function verifyDomainCoreControlPlane({
  trustedRoot,
  candidateRoot,
  manifest,
}) {
  if (
    manifest?.schemaVersion !== 2 ||
    !manifest.files ||
    typeof manifest.files !== "object" ||
    Array.isArray(manifest.files)
  ) {
    fail("control-plane manifest must be schemaVersion 2 with a files object");
  }
  const manifestEntries = new Map();
  for (const [path, chunks] of Object.entries(manifest.files)) {
    if (
      !Array.isArray(chunks) ||
      chunks.length !== 4 ||
      chunks.some(
        (chunk) => typeof chunk !== "string" || !/^[0-9a-f]{16}$/u.test(chunk),
      )
    ) {
      fail("control-plane manifest contains an invalid file digest");
    }
    manifestEntries.set(path, chunks.join(""));
  }
  const expectedPaths = discoverDomainCoreControlPlane(trustedRoot);
  const manifestPaths = [...manifestEntries.keys()].sort();
  if (JSON.stringify(manifestPaths) !== JSON.stringify(expectedPaths)) {
    fail(
      "control-plane manifest paths do not exactly cover trusted workflow executables and imports",
    );
  }
  for (const path of expectedPaths) {
    regularRepoFile(trustedRoot, path, "trusted control-plane file");
    regularRepoFile(candidateRoot, path, "candidate control-plane file");
    const trustedDigest = sha256(trustedRoot, path);
    if (manifestEntries.get(path) !== trustedDigest) {
      fail(`trusted control-plane digest does not match manifest: ${path}`);
    }
    if (sha256(candidateRoot, path) !== trustedDigest) {
      fail(`candidate control-plane file differs from trusted main: ${path}`);
    }
  }
  return { schemaVersion: 2, verifiedFileCount: expectedPaths.length };
}

function argument(argv, flag, fallback) {
  const index = argv.indexOf(flag);
  if (index === -1) return fallback;
  if (!argv[index + 1] || argv[index + 1].startsWith("--"))
    fail(`${flag} requires a value`);
  return argv[index + 1];
}

export function run(argv) {
  const trustedRoot = resolve(argument(argv, "--trusted-root", SCRIPT_ROOT));
  const manifestPath = resolve(
    trustedRoot,
    argument(argv, "--manifest", DEFAULT_MANIFEST),
  );
  if (argv.includes("--write")) {
    writeFileSync(
      manifestPath,
      serializeDomainCoreControlPlaneManifest(
        createDomainCoreControlPlaneManifest(trustedRoot),
      ),
    );
    return;
  }
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const candidateRoot = resolve(argument(argv, "--candidate-root"));
  const result = verifyDomainCoreControlPlane({
    trustedRoot,
    candidateRoot,
    manifest,
  });
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
