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

test("control-plane manifest exhaustively covers workflow executables and local imports", () => {
  const discovered = discoverDomainCoreControlPlane(ROOT);
  assert.deepEqual(Object.keys(MANIFEST.files).sort(), discovered);
  assert.ok(discovered.includes("scripts/test-openburnbar-swift.sh"));
  assert.ok(discovered.includes("scripts/test-openburnbar-app.sh"));
  assert.ok(
    discovered.includes("scripts/ci/write_burnbar_source_provenance.py"),
  );
  assert.ok(
    discovered.includes("scripts/ci/check_agpl_legal_release_review.py"),
  );
});

test("dynamic Python helpers executed by a trusted preflight are trusted bytes", (context) => {
  for (const path of [
    "scripts/ci/write_burnbar_source_provenance.py",
    "scripts/ci/check_agpl_legal_release_review.py",
  ]) {
    const candidateRoot = candidateCopy(context);
    writeFileSync(resolve(candidateRoot, path), "untrusted post-auth helper\n");
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
