import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  domainCoreProfileFromApplePlist,
  parseDomainCoreArtifactVerifierArgs,
  verifyAndroidRuntimeProfile,
  verifyConsoleRuntimeProfile,
  verifyWindowsRuntimeProfile,
} from "./domain-core-artifact-profile.mjs";

const profile = {
  schemaVersion: 1,
  name: "public-production",
  artifactAuthority: "signed",
  distribution: "public",
  rolloutChannel: null,
  evidenceEnabled: false,
  candidateIdentity: {
    candidateCommit: "a".repeat(40),
    coreVersion: "1.2.3",
    abiVersion: 7,
    sourceSha256: "b".repeat(64),
  },
  modes: {
    quota: "legacy",
    cloudVault: "rust",
    cloudVaultRewrap: "legacy",
    cloudVaultSearch: "rust",
    hermes: "legacy",
    pricing: "rust",
  },
};

test("artifact verifier arguments are exact and unambiguous", () => {
  assert.equal(
    parseDomainCoreArtifactVerifierArgs([
      "--profile",
      "public-production",
      "--receipt",
      "receipt.json",
    ]).get("--receipt"),
    "receipt.json",
  );
  for (const argv of [
    ["--profile", "public-production"],
    [
      "--profile",
      "public-production",
      "--receipt",
      "one",
      "--console-dir",
      "two",
    ],
    ["--profile", "public-production", "--receipt", "one", "--receipt", "two"],
    ["--profile", "public-production", "--unknown", "value"],
    ["--profile", "--receipt", "value"],
  ]) {
    assert.throws(() => parseDomainCoreArtifactVerifierArgs(argv));
  }
});

test("release coordinates must be supplied as a complete commit/version/tag triplet", () => {
  const complete = parseDomainCoreArtifactVerifierArgs([
    "--profile",
    "public-production",
    "--expected-candidate-commit",
    "a".repeat(40),
    "--expected-release-commit",
    "b".repeat(40),
    "--expected-release-version",
    "1.0.0",
    "--expected-release-tag",
    "v1.0.0",
    "--receipt",
    "receipt.json",
  ]);
  assert.equal(complete.get("--expected-release-commit"), "b".repeat(40));
  assert.equal(complete.get("--expected-release-version"), "1.0.0");
  assert.equal(complete.get("--expected-release-tag"), "v1.0.0");

  for (const argv of [
    // commit only — missing version and tag
    [
      "--profile",
      "public-production",
      "--expected-release-commit",
      "b".repeat(40),
      "--receipt",
      "receipt.json",
    ],
    // version only — missing commit and tag
    [
      "--profile",
      "public-production",
      "--expected-release-version",
      "1.0.0",
      "--receipt",
      "receipt.json",
    ],
    // tag only — missing commit and version
    [
      "--profile",
      "public-production",
      "--expected-release-tag",
      "v1.0.0",
      "--receipt",
      "receipt.json",
    ],
    // commit + version — missing tag
    [
      "--profile",
      "public-production",
      "--expected-release-commit",
      "b".repeat(40),
      "--expected-release-version",
      "1.0.0",
      "--receipt",
      "receipt.json",
    ],
    // commit + tag — missing version
    [
      "--profile",
      "public-production",
      "--expected-release-commit",
      "b".repeat(40),
      "--expected-release-tag",
      "v1.0.0",
      "--receipt",
      "receipt.json",
    ],
    // version + tag — missing commit
    [
      "--profile",
      "public-production",
      "--expected-release-version",
      "1.0.0",
      "--expected-release-tag",
      "v1.0.0",
      "--receipt",
      "receipt.json",
    ],
  ]) {
    assert.throws(
      () => parseDomainCoreArtifactVerifierArgs(argv),
      /must be supplied together/,
    );
  }
});

test("Apple plist mapping pins exact case-sensitive receipt keys", () => {
  const requested = [];
  const values = new Map([
    ["OpenBurnBarDomainCoreBuildProfile", profile.name],
    ["OpenBurnBarDomainCoreBuildAuthority", profile.artifactAuthority],
    ["OpenBurnBarDomainCoreDistribution", profile.distribution],
    ["OpenBurnBarDomainCoreRolloutChannel", ""],
    ["OpenBurnBarDomainCoreEvidenceEnabled", "NO"],
    [
      "OpenBurnBarDomainCoreCandidateCommit",
      profile.candidateIdentity.candidateCommit,
    ],
    [
      "OpenBurnBarDomainCoreExpectedVersion",
      profile.candidateIdentity.coreVersion,
    ],
    [
      "OpenBurnBarDomainCoreExpectedABIVersion",
      String(profile.candidateIdentity.abiVersion),
    ],
    [
      "OpenBurnBarDomainCoreExpectedSourceSHA256",
      profile.candidateIdentity.sourceSha256,
    ],
    ["OpenBurnBarDomainCoreModeQuota", profile.modes.quota],
    ["OpenBurnBarDomainCoreModeCloudVault", profile.modes.cloudVault],
    [
      "OpenBurnBarDomainCoreModeCloudVaultRewrap",
      profile.modes.cloudVaultRewrap,
    ],
    [
      "OpenBurnBarDomainCoreModeCloudVaultSearch",
      profile.modes.cloudVaultSearch,
    ],
    ["OpenBurnBarDomainCoreModeHermes", profile.modes.hermes],
    ["OpenBurnBarDomainCoreModePricing", profile.modes.pricing],
  ]);
  assert.deepEqual(
    domainCoreProfileFromApplePlist((key) => {
      requested.push(key);
      return values.get(key);
    }),
    profile,
  );
  assert.ok(requested.includes("OpenBurnBarDomainCoreExpectedABIVersion"));
  assert.ok(requested.includes("OpenBurnBarDomainCoreExpectedSourceSHA256"));
  assert.ok(!requested.includes("OpenBurnBarDomainCoreExpectedAbiVersion"));
  assert.ok(!requested.includes("OpenBurnBarDomainCoreExpectedSourceSha256"));
});

test("runtime artifact checks require tuple values outside parallel receipts", (context) => {
  const root = mkdtempSync(join(tmpdir(), "domain-core-artifacts-"));
  context.after(() => rmSync(root, { recursive: true, force: true }));
  const values = [
    profile.name,
    profile.artifactAuthority,
    profile.distribution,
    ...Object.values(profile.candidateIdentity),
    ...Object.values(profile.modes),
  ].join(" ");
  const androidIdentityWire = [
    profile.candidateIdentity.candidateCommit,
    profile.candidateIdentity.coreVersion,
    profile.candidateIdentity.abiVersion,
    profile.candidateIdentity.sourceSha256,
  ].join("|");

  const consoleDir = join(root, "console");
  mkdirSync(join(consoleDir, "chunks"), { recursive: true });
  writeFileSync(join(consoleDir, "chunks/runtime.js"), values);
  verifyConsoleRuntimeProfile(consoleDir, profile);
  writeFileSync(join(consoleDir, "chunks/runtime.js"), "missing tuple");
  assert.throws(
    () => verifyConsoleRuntimeProfile(consoleDir, profile),
    /does not embed/,
  );

  const windowsDir = join(root, "windows");
  mkdirSync(windowsDir);
  const metadataKeys = [
    "OpenBurnBar.DomainCore.BuildProfile",
    "OpenBurnBar.DomainCore.BuildAuthority",
    "OpenBurnBar.DomainCore.CandidateCommit",
    "OpenBurnBar.DomainCore.ExpectedVersion",
    "OpenBurnBar.DomainCore.ExpectedAbiVersion",
    "OpenBurnBar.DomainCore.ExpectedSourceSha256",
  ].join(" ");
  writeFileSync(
    join(windowsDir, "OpenBurnBar.App.Configuration.dll"),
    `${metadataKeys} ${values}`,
  );
  verifyWindowsRuntimeProfile(windowsDir, profile);

  verifyAndroidRuntimeProfile([Buffer.from(androidIdentityWire)], profile);
  assert.throws(
    () =>
      verifyAndroidRuntimeProfile(
        [Buffer.from(androidIdentityWire.replace("|7|", "|8|"))],
        profile,
      ),
    /does not embed/,
  );
  assert.throws(
    () =>
      verifyAndroidRuntimeProfile(
        [Buffer.from("parallel receipt only")],
        profile,
      ),
    /does not embed/,
  );
});
