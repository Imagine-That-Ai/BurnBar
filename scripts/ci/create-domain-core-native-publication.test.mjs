import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { buildPublicationManifest } from "./create-domain-core-native-publication.mjs";
import { validateManifest } from "./publish-domain-core-release-evidence.mjs";

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "native-publication-"));
  const bundleDirectory = join(root, "bundles");
  mkdirSync(bundleDirectory);
  const artifactPath = join(root, "OpenBurnBar-1.2.3-macOS.dmg");
  const predicatePath = join(root, "quota.predicate.json");
  const bundleAssetName =
    "OpenBurnBar-1.2.3-apple-quota-domain-core.sigstore.json";
  writeFileSync(artifactPath, "artifact");
  writeFileSync(predicatePath, "predicate");
  writeFileSync(join(bundleDirectory, bundleAssetName), "bundle");
  return {
    bundleDirectory,
    plan: {
      schemaVersion: 2,
      consumer: "apple",
      tag: "v1.2.3",
      commit: "a".repeat(40),
      artifactPath,
      signerWorkflow: ".github/workflows/release.yml",
      domains: [
        {
          domain: "quota",
          predicatePath,
          bundleAssetName,
        },
      ],
    },
  };
}

test("builds a publication manifest from exact regular files", () => {
  const { plan, bundleDirectory } = fixture();
  const manifest = buildPublicationManifest(plan, bundleDirectory);
  assert.equal(manifest.schemaVersion, 2);
  assert.equal(manifest.consumer, "apple");
  assert.equal(manifest.releaseState, "draft-then-publish");
  assert.equal(manifest.nativeArtifactOnly, false);
  assert.equal(manifest.bundles[0].domain, "quota");
  assert.equal(manifest.bundles[0].assetName, plan.domains[0].bundleAssetName);
});

test("builds an artifact-only publication for an all-legacy native plan", () => {
  const { plan, bundleDirectory } = fixture();
  plan.domains = [];
  const manifest = buildPublicationManifest(plan, bundleDirectory);
  assert.equal(manifest.nativeArtifactOnly, true);
  assert.deepEqual(manifest.bundles, []);
  assert.equal(validateManifest(manifest).nativeArtifactOnly, true);
});

test("marks Windows publication as draft-then-publish", () => {
  const { plan, bundleDirectory } = fixture();
  plan.consumer = "windows";
  plan.tag = "windows-v1.2.3";
  plan.signerWorkflow = ".github/workflows/openburnbar-release-windows.yml";
  plan.artifactPath = join(
    bundleDirectory,
    "OpenBurnBar-1.2.3-windows-release.zip",
  );
  plan.domains = [];
  writeFileSync(plan.artifactPath, "windows-artifact");
  const manifest = buildPublicationManifest(plan, bundleDirectory);
  assert.equal(manifest.releaseState, "draft-then-publish");
  assert.equal(validateManifest(manifest).releaseState, "draft-then-publish");
});

test("rejects traversal and absolute bundle asset names", () => {
  for (const bundleAssetName of ["../outside.json", "/tmp/outside.json"]) {
    const { plan, bundleDirectory } = fixture();
    plan.domains[0].bundleAssetName = bundleAssetName;
    assert.throws(
      () => buildPublicationManifest(plan, bundleDirectory),
      /safe basename/u,
    );
  }
});

test("rejects duplicate domains and bundle assets", () => {
  const { plan, bundleDirectory } = fixture();
  plan.domains.push({ ...plan.domains[0] });
  assert.throws(
    () => buildPublicationManifest(plan, bundleDirectory),
    /duplicate native evidence domain/u,
  );

  const second = fixture();
  second.plan.domains.push({
    ...second.plan.domains[0],
    domain: "pricing",
  });
  assert.throws(
    () => buildPublicationManifest(second.plan, second.bundleDirectory),
    /duplicate native evidence bundle asset/u,
  );
});
