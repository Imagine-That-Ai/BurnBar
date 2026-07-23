import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  buildReleaseEvidence,
  canonicalSha256,
  main,
  sha256File,
} from "./create-domain-core-release-evidence.mjs";
import { loadDomainCoreBuildProfiles } from "../lib/domain-core-build-profile.mjs";

const rootCatalog = loadDomainCoreBuildProfiles(
  new URL("../../config/domain-core-build-profiles.json", import.meta.url),
);

function catalogWithRust(domain) {
  const catalog = structuredClone(rootCatalog);
  catalog.profiles["public-production"].modes[domain] = "rust";
  return catalog;
}

function expectedProfileDigest(domain) {
  return canonicalSha256({
    artifactAuthority: "signed",
    distribution: "public",
    rolloutChannel: null,
    evidenceEnabled: false,
    domain,
    mode: "rust",
  });
}

for (const domain of ["quota", "cloudVault"]) {
  test(`Windows ${domain} evidence binds the canonical dual-architecture artifact`, () => {
    const directory = mkdtempSync(
      join(tmpdir(), "domain-core-windows-evidence-"),
    );
    const artifact = join(directory, "OpenBurnBar-1.2.3-windows-release.zip");
    const predicate = join(directory, `${domain}.predicate.json`);
    const catalog = join(directory, "profiles.json");
    writeFileSync(artifact, "signed x64 and arm64 bytes");
    writeFileSync(
      catalog,
      `${JSON.stringify(catalogWithRust(domain), null, 2)}\n`,
    );

    main([
      "node",
      "script",
      "--consumer",
      "windows",
      "--domain",
      domain,
      "--version",
      "1.2.3",
      "--tag",
      "windows-v1.2.3",
      "--commit",
      "a".repeat(40),
      "--artifact",
      artifact,
      "--predicate",
      predicate,
      "--profile-catalog",
      catalog,
    ]);

    assert.deepEqual(JSON.parse(readFileSync(predicate, "utf8")), {
      schemaVersion: 1,
      consumer: "windows",
      artifactKind: "windows-release-bundle",
      target: "windows-x64-arm64",
      artifact: {
        fileName: "OpenBurnBar-1.2.3-windows-release.zip",
        sha256: sha256File(artifact),
      },
      release: {
        version: "1.2.3",
        tag: "windows-v1.2.3",
        commit: "a".repeat(40),
        publicProfileSha256: expectedProfileDigest(domain),
      },
    });
    assert.equal(
      readFileSync(artifact, "utf8"),
      "signed x64 and arm64 bytes",
      "predicate generation must not rewrite the signed artifact",
    );
  });
}

test("Windows evidence skips legacy authority and rejects non-Windows domains", () => {
  const base = {
    catalog: rootCatalog,
    consumer: "windows",
    domain: "quota",
    version: "1.2.3",
    tag: "windows-v1.2.3",
    commit: "a".repeat(40),
    artifactPath: "/tmp/OpenBurnBar-1.2.3-windows-release.zip",
  };
  assert.deepEqual(buildReleaseEvidence(base), {
    enabled: false,
    expectedFileName: "OpenBurnBar-1.2.3-windows-release.zip",
  });
  assert.throws(
    () =>
      buildReleaseEvidence({
        ...base,
        catalog: catalogWithRust("cloudVaultSearch"),
        domain: "cloudVaultSearch",
      }),
    /windows does not ship.*cloudVaultSearch/,
  );
});

test("Windows evidence rejects generic tags and partial artifact names", () => {
  const base = {
    catalog: catalogWithRust("quota"),
    consumer: "windows",
    domain: "quota",
    version: "1.2.3",
    tag: "windows-v1.2.3",
    commit: "a".repeat(40),
    artifactPath: "/tmp/OpenBurnBar-1.2.3-windows-release.zip",
  };
  assert.throws(
    () => buildReleaseEvidence({ ...base, tag: "v1.2.3" }),
    /tag must be windows-v1.2.3/,
  );
  assert.throws(
    () =>
      buildReleaseEvidence({
        ...base,
        artifactPath: "/tmp/OpenBurnBar-1.2.3-win-x64.zip",
      }),
    /artifact filename/,
  );
});

test("quota and CloudVault public profile digests cannot be substituted", () => {
  assert.notEqual(
    expectedProfileDigest("quota"),
    expectedProfileDigest("cloudVault"),
  );
});
