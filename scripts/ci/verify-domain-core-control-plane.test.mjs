import assert from "node:assert/strict";
import {
  cpSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

import {
  discoverDomainCoreControlPlane,
  verifyDomainCoreControlPlane,
} from "./verify-domain-core-control-plane.mjs";

const ROOT = resolve(new URL("../..", import.meta.url).pathname);
const MANIFEST = JSON.parse(
  readFileSync(
    new URL(
      "../../config/domain-core-control-plane-manifest.json",
      import.meta.url,
    ),
  ),
);

function candidateCopy(context) {
  const root = mkdtempSync(join(tmpdir(), "domain-core-control-plane-"));
  context.after(() => rmSync(root, { recursive: true, force: true }));
  for (const path of Object.keys(MANIFEST.files)) {
    mkdirSync(resolve(root, path, ".."), { recursive: true });
    cpSync(resolve(ROOT, path), resolve(root, path), { recursive: true });
  }
  return root;
}

function assertCandidateTamperingFails(context, paths) {
  const candidateRoot = candidateCopy(context);
  for (const path of paths) {
    assert.equal(typeof MANIFEST.files[path], "string", path);
    const candidatePath = resolve(candidateRoot, path);
    const trustedBytes = readFileSync(resolve(ROOT, path));
    writeFileSync(
      candidatePath,
      Buffer.concat([trustedBytes, Buffer.from("\ncandidate tamper\n")]),
    );
    assert.throws(
      () =>
        verifyDomainCoreControlPlane({
          trustedRoot: ROOT,
          candidateRoot,
          manifest: MANIFEST,
        }),
      /differs from trusted main/u,
      path,
    );
    writeFileSync(candidatePath, trustedBytes);
  }
}

test("control-plane manifest exhaustively covers workflow executables and local imports", () => {
  const discovered = discoverDomainCoreControlPlane(ROOT);
  assert.deepEqual(Object.keys(MANIFEST.files).sort(), discovered);
  assert.ok(discovered.includes("scripts/test-openburnbar-swift.sh"));
  assert.ok(discovered.includes("scripts/test-openburnbar-app.sh"));
});

test("dot-slash workflow executables are normalized into the trusted manifest", (context) => {
  for (const path of [
    "scripts/test-openburnbar-swift.sh",
    "scripts/test-openburnbar-app.sh",
  ]) {
    const candidateRoot = candidateCopy(context);
    writeFileSync(resolve(candidateRoot, path), "untrusted proof driver\n");
    assert.throws(
      () =>
        verifyDomainCoreControlPlane({
          trustedRoot: ROOT,
          candidateRoot,
          manifest: MANIFEST,
        }),
      /differs from trusted main/u,
      path,
    );
  }
});

test("candidate control-plane drift, omission, and an incomplete trusted manifest fail closed", (context) => {
  const candidateRoot = candidateCopy(context);
  assert.doesNotThrow(() =>
    verifyDomainCoreControlPlane({
      trustedRoot: ROOT,
      candidateRoot,
      manifest: MANIFEST,
    }),
  );

  const path = "scripts/ci/domain-core-proof-fragment.mjs";
  writeFileSync(
    resolve(candidateRoot, path),
    "malicious candidate proof generator\n",
  );
  assert.throws(
    () =>
      verifyDomainCoreControlPlane({
        trustedRoot: ROOT,
        candidateRoot,
        manifest: MANIFEST,
      }),
    /differs from trusted main/u,
  );

  const incomplete = structuredClone(MANIFEST);
  delete incomplete.files[path];
  assert.throws(
    () =>
      verifyDomainCoreControlPlane({
        trustedRoot: ROOT,
        candidateRoot: ROOT,
        manifest: incomplete,
      }),
    /do not exactly cover/u,
  );
});

test("every loaded-identity observer, harness, binding, and union contract are trusted bytes", (context) => {
  const observerPaths = [
    "OpenBurnBarCore/Package.swift",
    "OpenBurnBarCore/Sources/OpenBurnBarDomainCore/Generated/openburnbar_domain_ffi.swift",
    "OpenBurnBarCore/Sources/OpenBurnBarDomainCoreFFISmoke/main.swift",
    "android/openburnbar-domain-core/build.gradle.kts",
    "android/openburnbar-domain-core/src/androidTest/java/com/openburnbar/domaincore/DomainCoreNativeLoadTest.kt",
    "android/openburnbar-domain-core/src/main/java/uniffi/openburnbar_domain_ffi/openburnbar_domain_ffi.kt",
    "crates/openburnbar-domain-core/domain-wasm/tests/package-smoke.mjs",
    "crates/openburnbar-domain-core/bindings/csharp/OpenBurnBarDomainCore.Ffi/generated/openburnbar_domain_ffi.cs",
    "windows/tests/quota/DomainCoreQuotaBridgeTests.cs",
    "windows/tests/quota/OpenBurnBar.App.Quota.Tests.csproj",
    "crates/openburnbar-domain-core/union-abi-manifest.json",
  ];
  for (const path of observerPaths)
    assert.equal(typeof MANIFEST.files[path], "string", path);

  const candidateRoot = candidateCopy(context);
  writeFileSync(
    resolve(candidateRoot, observerPaths[0]),
    "forged observed identity\n",
  );
  assert.throws(
    () =>
      verifyDomainCoreControlPlane({
        trustedRoot: ROOT,
        candidateRoot,
        manifest: MANIFEST,
      }),
    /differs from trusted main/u,
  );
});

test("candidate control-plane files and parent directories cannot be symlink escapes", (context) => {
  const path = "scripts/ci/domain-core-proof-fragment.mjs";
  const linkedFileRoot = candidateCopy(context);
  unlinkSync(resolve(linkedFileRoot, path));
  symlinkSync(resolve(ROOT, path), resolve(linkedFileRoot, path));
  assert.throws(
    () =>
      verifyDomainCoreControlPlane({
        trustedRoot: ROOT,
        candidateRoot: linkedFileRoot,
        manifest: MANIFEST,
      }),
    /cannot traverse a symlink/u,
  );

  const linkedParentRoot = candidateCopy(context);
  rmSync(resolve(linkedParentRoot, "scripts/ci"), { recursive: true });
  symlinkSync(
    resolve(ROOT, "scripts/ci"),
    resolve(linkedParentRoot, "scripts/ci"),
    "dir",
  );
  assert.throws(
    () =>
      verifyDomainCoreControlPlane({
        trustedRoot: ROOT,
        candidateRoot: linkedParentRoot,
        manifest: MANIFEST,
      }),
    /cannot traverse a symlink/u,
  );
});

test("candidate fixture file modification is detected as control-plane drift", (context) => {
  const fixturePath =
    "tests/fixtures/domain-core/cloudvault/v1/cloudvault-deterministic-kat.json";
  assert.equal(typeof MANIFEST.files[fixturePath], "string", fixturePath);

  const candidateRoot = candidateCopy(context);
  const original = readFileSync(resolve(ROOT, fixturePath), "utf8");
  const tampered = JSON.parse(original);
  tampered.__drift = "weakened fixture";
  writeFileSync(
    resolve(candidateRoot, fixturePath),
    `${JSON.stringify(tampered, null, 2)}\n`,
  );
  assert.throws(
    () =>
      verifyDomainCoreControlPlane({
        trustedRoot: ROOT,
        candidateRoot,
        manifest: MANIFEST,
      }),
    /differs from trusted main/u,
  );
});

test("candidate artifact contract and diagnostic policy tampering are rejected", (context) => {
  assertCandidateTamperingFails(context, [
    "apps/console/test/domainCoreCloudVaultInitialization.test.ts",
    "scripts/ci/stage-domain-core-attestation-artifact.test.mjs",
    "config/domain-core-shadow-diagnostic-policy.json",
  ]);
});

test("candidate package, checker, and local hook tampering are rejected", (context) => {
  assertCandidateTamperingFails(context, [
    "apps/console/eslint.config.mjs",
    "apps/console/package-lock.json",
    "apps/console/package.json",
    "apps/console/scripts/sync-domains.mjs",
    "apps/console/tsconfig.json",
    "apps/console/vitest.config.ts",
    "functions/eslint.config.mjs",
    "functions/package-lock.json",
    "functions/package.json",
    "functions/scripts/copy-certs.mjs",
    "functions/scripts/postinstall-sync-local-packages.mjs",
    "functions/scripts/sync-local-packages.mjs",
    "functions/tsconfig.json",
    "functions/vitest.config.ts",
    "packages/entitlements/package-lock.json",
    "packages/entitlements/package.json",
    "packages/entitlements/tsconfig.json",
    "packages/signal-envelope-contracts/package-lock.json",
    "packages/signal-envelope-contracts/package.json",
    "packages/signal-envelope-contracts/tsconfig.json",
    "scripts/build-entitlements.sh",
    "scripts/build-signal-envelope-contracts.sh",
  ]);
});
