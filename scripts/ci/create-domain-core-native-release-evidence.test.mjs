import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  NATIVE_RELEASE_CONSUMERS,
  buildNativeReleaseEvidencePlan,
  writeNativeReleaseEvidencePlan,
} from "./create-domain-core-native-release-evidence.mjs";
import { loadDomainCoreBuildProfiles } from "../lib/domain-core-build-profile.mjs";

const rootCatalog = loadDomainCoreBuildProfiles(
  new URL("../../config/domain-core-build-profiles.json", import.meta.url),
);

function fixture(consumer, domains) {
  const directory = mkdtempSync(
    join(tmpdir(), `domain-core-${consumer}-native-`),
  );
  const version = "1.2.3";
  const artifactName = NATIVE_RELEASE_CONSUMERS[consumer].artifactName(version);
  const artifactPath = join(directory, artifactName);
  writeFileSync(artifactPath, `${consumer} signed release bytes\n`);
  const catalog = structuredClone(rootCatalog);
  for (const domain of domains)
    catalog.profiles["public-production"].modes[domain] = "rust";
  return { directory, version, artifactPath, catalog };
}

test("Apple plan emits six exact domain predicates over one arm64 DMG", () => {
  const domains = [
    "quota",
    "cloudVault",
    "cloudVaultRewrap",
    "cloudVaultSearch",
    "hermes",
    "pricing",
  ];
  const input = fixture("apple", domains);
  const plan = buildNativeReleaseEvidencePlan({
    catalog: input.catalog,
    consumer: "apple",
    version: input.version,
    tag: "v1.2.3",
    commit: "a".repeat(40),
    artifactPath: input.artifactPath,
  });
  assert.equal(plan.target, "macos-arm64");
  assert.equal(plan.artifactKind, "macos-dmg");
  assert.deepEqual(
    plan.domains.map((item) => item.domain),
    domains,
  );
  for (const item of plan.domains) {
    assert.equal(item.predicate.target, "macos-arm64");
    assert.equal(item.predicate.artifact.sha256, plan.artifact.sha256);
    assert.equal(item.predicate.release.commit, "a".repeat(40));
    assert.match(
      item.bundleFileName,
      /macOS-.*-domain-core-attestation\.sigstore\.json$/,
    );
  }
});

test("Android plan emits four exact domain predicates over the canonical AAB", () => {
  const domains = [
    "cloudVault",
    "cloudVaultRewrap",
    "cloudVaultSearch",
    "hermes",
  ];
  const input = fixture("android", domains);
  const plan = buildNativeReleaseEvidencePlan({
    catalog: input.catalog,
    consumer: "android",
    version: input.version,
    tag: "v1.2.3",
    commit: "b".repeat(40),
    artifactPath: input.artifactPath,
  });
  assert.equal(plan.target, "android-universal");
  assert.equal(plan.artifactKind, "android-aab");
  assert.deepEqual(
    plan.domains.map((item) => item.domain),
    domains,
  );
  assert.equal(plan.artifact.fileName, "OpenBurnBar-1.2.3-Android.aab");
});

test("legacy domains remain dormant and prerelease tags fail closed", () => {
  const input = fixture("apple", []);
  const base = {
    catalog: input.catalog,
    consumer: "apple",
    version: input.version,
    tag: "v1.2.3",
    commit: "a".repeat(40),
    artifactPath: input.artifactPath,
  };
  assert.deepEqual(buildNativeReleaseEvidencePlan(base).domains, []);
  assert.throws(
    () => buildNativeReleaseEvidencePlan({ ...base, tag: "v1.2.3-beta.1" }),
    /tag must be v1\.2\.3/,
  );
});

test("manifest excludes predicates but pins their deterministic filenames and digests", () => {
  const input = fixture("android", ["hermes"]);
  const plan = buildNativeReleaseEvidencePlan({
    catalog: input.catalog,
    consumer: "android",
    version: input.version,
    tag: "v1.2.3",
    commit: "c".repeat(40),
    artifactPath: input.artifactPath,
  });
  const manifestPath = writeNativeReleaseEvidencePlan(plan, input.directory);
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  assert.equal(manifest.domains.length, 1);
  assert.equal("predicate" in manifest.domains[0], false);
  assert.equal(
    manifest.domains[0].predicateFileName,
    "android-hermes.predicate.json",
  );
  assert.equal(
    manifest.domains[0].bundleFileName,
    "OpenBurnBar-1.2.3-Android-hermes-domain-core-attestation.sigstore.json",
  );
  const predicate = JSON.parse(
    readFileSync(
      join(input.directory, manifest.domains[0].predicateFileName),
      "utf8",
    ),
  );
  assert.equal(
    predicate.release.publicProfileSha256,
    manifest.domains[0].publicProfileSha256,
  );
});

test("native plans reject cross-consumer filenames", () => {
  const input = fixture("apple", ["quota"]);
  assert.throws(
    () =>
      buildNativeReleaseEvidencePlan({
        catalog: input.catalog,
        consumer: "android",
        version: input.version,
        tag: "v1.2.3",
        commit: "a".repeat(40),
        artifactPath: input.artifactPath,
      }),
    /artifact filename must be OpenBurnBar-1\.2\.3-Android\.aab/,
  );
});
