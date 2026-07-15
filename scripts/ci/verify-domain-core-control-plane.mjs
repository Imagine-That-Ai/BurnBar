#!/usr/bin/env node

import { createHash } from "node:crypto";
import { existsSync, lstatSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, extname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const DEFAULT_MANIFEST = "config/domain-core-control-plane-manifest.json";
const SEED_PATHS = Object.freeze([
  ".github/workflows/domain-core.yml",
  ".github/workflows/domain-core-promotion-proof.yml",
  // npm proof jobs trust their exact install, test-runner, typecheck, lint, and
  // local hook configuration so candidate bytes cannot weaken the checks.
  "apps/console/eslint.config.mjs",
  "apps/console/package-lock.json",
  "apps/console/package.json",
  "apps/console/scripts/sync-domains.mjs",
  "apps/console/tsconfig.json",
  "apps/console/vitest.config.ts",
  "OpenBurnBarCore/Package.swift",
  "OpenBurnBarCore/Sources/OpenBurnBarDomainCore/Generated/openburnbar_domain_ffi.swift",
  "OpenBurnBarCore/Sources/OpenBurnBarDomainCoreFFISmoke/main.swift",
  "android/build.gradle.kts",
  "android/gradle/ktlint-android-sources.gradle.kts",
  "android/gradle/wrapper/gradle-wrapper.jar",
  "android/gradle/wrapper/gradle-wrapper.properties",
  "android/gradlew",
  "android/openburnbar-domain-core/build.gradle.kts",
  "android/openburnbar-domain-core/src/androidTest/java/com/openburnbar/domaincore/DomainCoreNativeLoadTest.kt",
  "android/openburnbar-domain-core/src/main/java/uniffi/openburnbar_domain_ffi/openburnbar_domain_ffi.kt",
  "android/settings.gradle.kts",
  "config/domain-core-build-profiles.json",
  "config/domain-core-deterministic-candidate-bundle.schema.json",
  "config/domain-core-promotion-policy.json",
  "config/domain-core-shadow-diagnostic-policy.json",
  "crates/openburnbar-domain-core/domain-wasm/tests/package-smoke.mjs",
  "crates/openburnbar-domain-core/union-abi-manifest.json",
  "functions/eslint.config.mjs",
  "functions/package-lock.json",
  "functions/package.json",
  "functions/scripts/copy-certs.mjs",
  "functions/scripts/postinstall-sync-local-packages.mjs",
  "functions/scripts/sync-local-packages.mjs",
  "functions/tsconfig.json",
  "functions/vitest.config.ts",
  // npm install hooks invoked by the Functions proof job use these local
  // package builders and their build-command/dependency configuration.
  "packages/entitlements/package-lock.json",
  "packages/entitlements/package.json",
  "packages/entitlements/tsconfig.json",
  "packages/signal-envelope-contracts/package-lock.json",
  "packages/signal-envelope-contracts/package.json",
  "packages/signal-envelope-contracts/tsconfig.json",
  "scripts/build-entitlements.sh",
  "scripts/build-signal-envelope-contracts.sh",
  "scripts/ci/stage-domain-core-attestation-artifact.test.mjs",
  "scripts/ci/verify-domain-core-control-plane.mjs",
  "scripts/ci/verify-domain-core-protected-attestation.mjs",
  "windows/Directory.Build.props",
  "windows/Directory.Build.targets",
  "windows/app/OpenBurnBar.App.Configuration/OpenBurnBar.App.Configuration.csproj",
  "windows/app/OpenBurnBar.App.Presentation/OpenBurnBar.App.Presentation.csproj",
  "windows/storage/OpenBurnBar.Storage/OpenBurnBar.Storage.csproj",
  "windows/tests/quota/DomainCoreQuotaBridgeTests.cs",
  "windows/tests/quota/OpenBurnBar.App.Quota.Tests.csproj",
  "crates/openburnbar-domain-core/bindings/csharp/OpenBurnBarDomainCore.Ffi/OpenBurnBarDomainCore.Ffi.csproj",
  "crates/openburnbar-domain-core/bindings/csharp/OpenBurnBarDomainCore.Ffi/generated/openburnbar_domain_ffi.cs",
  // Test fixtures read by proof-job tests — a candidate could weaken these
  // while leaving the seeded harness unchanged, passing the workflow without
  // the protected signer comparing those bytes.
  "tests/fixtures/domain-core/cloudvault/v1/cloudvault-document-rewrap-contract.json",
  "tests/fixtures/domain-core/cloudvault/v1/cloudvault-deterministic-kat.json",
  "tests/fixtures/domain-core/cloudvault/v1/cloudvault-search-contract.json",
  "tests/fixtures/domain-core/quota/v1/codex-usage-expected.json",
  "tests/fixtures/domain-core/quota/v1/claude-statusline-expected.json",
  "tests/fixtures/domain-core/quota/v1/cursor-usage-summary-expected.json",
  "tests/fixtures/domain-core/quota/v1/claude-statusline-input.json",
  "tests/fixtures/domain-core/quota/v1/cursor-usage-summary-input.json",
  "tests/fixtures/domain-core/quota/v1/anthropic-ratelimit-headers-input.json",
  "tests/fixtures/domain-core/quota/v1/anthropic-ratelimit-headers-expected.json",
  "tests/fixtures/domain-core/quota/v1/codex-usage-input.json",
  "tests/fixtures/domain-core/hermes/v1/hermes-crypto-kat.json",
  "tests/fixtures/domain-core/pricing/v2/pricing-kat.json",
  // Windows dotnet test projects executed by proof jobs
  "windows/tests/cloudsync/OpenBurnBar.CloudSync.Crypto.Tests.csproj",
  "windows/tests/configuration/OpenBurnBar.App.Configuration.Tests.csproj",
  // Functions vitest contract files executed by the functions-pricing proof job
  "functions/src/__tests__/pricing.test.ts",
  "functions/src/__tests__/domainCoreBuildProfile.test.ts",
  "functions/src/__tests__/domainCoreShadowEvidence.test.ts",
  // Console vitest contract files executed by the console-consumer-contracts proof job
  "apps/console/test/domainCoreBuildProfile.test.ts",
  "apps/console/test/domainCoreCloudVault.test.ts",
  "apps/console/test/domainCoreCloudVaultInitialization.test.ts",
  "apps/console/test/domainCoreShadowEvidence.test.ts",
  "apps/console/test/escrow.test.ts",
  // Android gradle consumer contract test files executed by the android proof job
  "android/app/src/test/java/com/openburnbar/data/DomainCoreBuildProfileTest.kt",
  "android/app/src/test/java/com/openburnbar/data/DomainCoreShadowEvidenceTest.kt",
  "android/app/src/test/java/com/openburnbar/data/cloud/CloudVaultDocumentRewrapDomainCoreTest.kt",
  "android/app/src/test/java/com/openburnbar/data/cloud/CloudVaultDomainCoreTest.kt",
  "android/app/src/test/java/com/openburnbar/data/cloud/CloudVaultSearchDomainCoreTest.kt",
  "android/app/src/test/java/com/openburnbar/data/cloud/CloudVaultAadParityTest.kt",
  "android/app/src/test/java/com/openburnbar/data/hermes/relay/HermesDomainCoreAdapterTest.kt",
  "android/app/src/test/java/com/openburnbar/data/hermes/relay/HermesRatchetCryptoTest.kt",
  // Swift consumer contract test files executed by the swift-consumer-contracts proof job
  "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/ClaudeQuotaDomainCoreAdapterTests.swift",
  "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/CloudVaultAADParityTests.swift",
  "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/CloudVaultCryptoTests.swift",
  "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/CloudVaultDocumentRewrapDomainCoreAdapterTests.swift",
  "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/CloudVaultDomainCoreAdapterTests.swift",
  "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/CloudVaultSearchContractTests.swift",
  "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/CloudVaultSearchDomainCoreAdapterTests.swift",
  "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/CloudVaultSignalEnvelopeTests.swift",
  "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/DomainCoreBuildProfileTests.swift",
  "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/DomainCorePricingAdapterTests.swift",
  "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/DomainCoreQuotaConsumerTests.swift",
  "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/DomainCoreShadowRuntimeTests.swift",
  "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/HermesDomainCoreAdapterBoundaryTests.swift",
  "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/HermesDomainCoreMigrationTests.swift",
  "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/HermesRatchetCryptoTests.swift",
  // AgentLens shadow evidence spool test executed by test-openburnbar-app.sh
  "AgentLensTests/Active/DomainCoreShadowEvidenceSpoolTests.swift",
]);
const EXECUTABLE_REFERENCE =
  /(?:^|[\s"'(])((?:\.\/)?(?:scripts|tools)\/[A-Za-z0-9_./-]+\.(?:js|mjs|py|sh))/gmu;
const LOCAL_IMPORT = /(?:from\s+|import\s*\()(["'])(\.{1,2}\/[^"']+)\1/gmu;

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
  for (const workflow of [
    ".github/workflows/domain-core.yml",
    ".github/workflows/domain-core-promotion-proof.yml",
  ]) {
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
    if (!path.endsWith(".mjs") && !path.endsWith(".js")) continue;
    const absolute = regularRepoFile(root, path, "trusted control-plane file");
    const source = readFileSync(absolute, "utf8");
    for (const match of source.matchAll(LOCAL_IMPORT)) {
      const imported = resolveImport(root, path, match[2]);
      if (!imported) fail(`${path} imports missing local module ${match[2]}`);
      const importedPath = repoPath(root, imported);
      if (!discovered.has(importedPath)) {
        discovered.add(importedPath);
        pending.push(importedPath);
      }
    }
  }
  return [...discovered].sort();
}

export function createDomainCoreControlPlaneManifest(root = SCRIPT_ROOT) {
  return {
    schemaVersion: 1,
    files: Object.fromEntries(
      discoverDomainCoreControlPlane(root).map((path) => [
        path,
        sha256(root, path),
      ]),
    ),
  };
}

export function verifyDomainCoreControlPlane({
  trustedRoot,
  candidateRoot,
  manifest,
}) {
  if (
    manifest?.schemaVersion !== 1 ||
    !manifest.files ||
    typeof manifest.files !== "object" ||
    Array.isArray(manifest.files)
  ) {
    fail("control-plane manifest must be schemaVersion 1 with a files object");
  }
  const expectedPaths = discoverDomainCoreControlPlane(trustedRoot);
  const manifestPaths = Object.keys(manifest.files).sort();
  if (JSON.stringify(manifestPaths) !== JSON.stringify(expectedPaths)) {
    fail(
      "control-plane manifest paths do not exactly cover trusted workflow executables and imports",
    );
  }
  for (const path of expectedPaths) {
    regularRepoFile(trustedRoot, path, "trusted control-plane file");
    regularRepoFile(candidateRoot, path, "candidate control-plane file");
    const trustedDigest = sha256(trustedRoot, path);
    if (manifest.files[path] !== trustedDigest) {
      fail(`trusted control-plane digest does not match manifest: ${path}`);
    }
    if (sha256(candidateRoot, path) !== trustedDigest) {
      fail(`candidate control-plane file differs from trusted main: ${path}`);
    }
  }
  return { schemaVersion: 1, verifiedFileCount: expectedPaths.length };
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
      `${JSON.stringify(createDomainCoreControlPlaneManifest(trustedRoot), null, 2)}\n`,
    );
    return;
  }
  const candidateRoot = resolve(argument(argv, "--candidate-root"));
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
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
