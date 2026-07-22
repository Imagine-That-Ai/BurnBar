import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  RELEASE_PREDICATE_TYPE,
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

function healthyFunctionsEvidence(commit = "a".repeat(40), tag = "v1.2.3") {
  const source = {
    repository: "https://github.com/Imagine-That-Ai/BurnBar",
    commit,
  };
  return {
    generatedAt: "2026-07-14T00:00:00Z",
    project: "burnbar",
    tag,
    healthLive: {
      status: "alive",
      timestamp: "volatile",
      source: { ...source },
    },
    healthReady: {
      status: "ready",
      timestamp: "volatile",
      version: tag,
      source: { ...source },
      sentry: { enabled: true, environment: "production" },
    },
  };
}

function healthyConsoleEvidence(commit = "a".repeat(40), tag = "v1.2.3") {
  const publicProfileSha256 = canonicalSha256({
    artifactAuthority: "signed",
    distribution: "public",
    rolloutChannel: null,
    evidenceEnabled: false,
    domain: "cloudVault",
    mode: "rust",
  });
  return {
    schemaVersion: 1,
    project: "burnbar",
    tag,
    commit,
    checks: { marketing: "ok", console: "ok", deploymentIdentity: "ok" },
    deploymentIdentity: {
      schemaVersion: 1,
      consumer: "console",
      target: "firebase-hosting-production",
      repository: "https://github.com/Imagine-That-Ai/BurnBar",
      commit,
      tag,
      profile: { domain: "cloudVault", mode: "rust", publicProfileSha256 },
    },
  };
}

test("functions deployment evidence exactly binds the stable pricing profile", () => {
  const directory = mkdtempSync(
    join(tmpdir(), "domain-core-functions-evidence-"),
  );
  const artifactPath = join(
    directory,
    "OpenBurnBar-1.2.3-functions-deployment.json",
  );
  const predicatePath = join(directory, "predicate.json");
  const catalogPath = join(directory, "profiles.json");
  const healthPath = join(directory, "deploy-health.json");
  writeFileSync(
    catalogPath,
    `${JSON.stringify(catalogWithRust("pricing"), null, 2)}\n`,
  );
  writeFileSync(
    healthPath,
    `${JSON.stringify(healthyFunctionsEvidence(), null, 2)}\n`,
  );

  main([
    "node",
    "script",
    "--consumer",
    "functions",
    "--domain",
    "pricing",
    "--version",
    "1.2.3",
    "--tag",
    "v1.2.3",
    "--commit",
    "a".repeat(40),
    "--artifact",
    artifactPath,
    "--predicate",
    predicatePath,
    "--profile-catalog",
    catalogPath,
    "--health-artifact",
    healthPath,
  ]);

  const receipt = JSON.parse(readFileSync(artifactPath, "utf8"));
  const predicate = JSON.parse(readFileSync(predicatePath, "utf8"));
  const expectedProfileDigest = canonicalSha256({
    artifactAuthority: "signed",
    distribution: "public",
    rolloutChannel: null,
    evidenceEnabled: false,
    domain: "pricing",
    mode: "rust",
  });
  assert.deepEqual(receipt, {
    schemaVersion: 1,
    consumer: "functions",
    artifactKind: "functions-deployment-receipt",
    target: "firebase-functions-production",
    release: {
      version: "1.2.3",
      tag: "v1.2.3",
      commit: "a".repeat(40),
      publicProfileSha256: expectedProfileDigest,
    },
    deployment: {
      provider: "firebase-functions",
      project: "burnbar",
      environment: "production",
      status: "healthy",
      healthChecks: ["healthLive", "healthReady"],
    },
  });
  assert.deepEqual(predicate, {
    schemaVersion: 1,
    consumer: "functions",
    artifactKind: "functions-deployment-receipt",
    target: "firebase-functions-production",
    artifact: {
      fileName: "OpenBurnBar-1.2.3-functions-deployment.json",
      sha256: sha256File(artifactPath),
    },
    release: {
      version: "1.2.3",
      tag: "v1.2.3",
      commit: "a".repeat(40),
      publicProfileSha256: expectedProfileDigest,
    },
  });
  assert.equal(
    RELEASE_PREDICATE_TYPE,
    "https://openburnbar.dev/attestations/domain-core-release-artifact/v1",
  );
});

test("release evidence skips legacy authority and rejects cross-consumer domain substitution", () => {
  const base = {
    catalog: rootCatalog,
    consumer: "functions",
    domain: "pricing",
    version: "1.2.3",
    tag: "v1.2.3",
    commit: "a".repeat(40),
    artifactPath: "/tmp/OpenBurnBar-1.2.3-functions-deployment.json",
  };
  assert.deepEqual(buildReleaseEvidence(base), {
    enabled: false,
    expectedFileName: "OpenBurnBar-1.2.3-functions-deployment.json",
  });
  assert.throws(
    () =>
      buildReleaseEvidence({
        ...base,
        catalog: catalogWithRust("cloudVault"),
        domain: "cloudVault",
      }),
    /functions does not ship.*cloudVault/,
  );
});

test("Functions release evidence rejects stale or incomplete health proof", () => {
  const base = {
    catalog: catalogWithRust("pricing"),
    consumer: "functions",
    domain: "pricing",
    version: "1.2.3",
    tag: "v1.2.3",
    commit: "a".repeat(40),
    artifactPath: "/tmp/OpenBurnBar-1.2.3-functions-deployment.json",
    healthEvidence: healthyFunctionsEvidence(),
  };
  assert.equal(buildReleaseEvidence(base).enabled, true);
  const stale = structuredClone(base.healthEvidence);
  stale.healthReady.source.commit = "b".repeat(40);
  assert.throws(
    () => buildReleaseEvidence({ ...base, healthEvidence: stale }),
    /healthReady.*release commit/,
  );
  const wrongVersion = structuredClone(base.healthEvidence);
  wrongVersion.healthReady.version = "v1.2.2";
  assert.throws(
    () => buildReleaseEvidence({ ...base, healthEvidence: wrongVersion }),
    /release version/,
  );
  const noSentry = structuredClone(base.healthEvidence);
  noSentry.healthReady.sentry.enabled = false;
  assert.throws(
    () => buildReleaseEvidence({ ...base, healthEvidence: noSentry }),
    /Sentry state/,
  );
});

test("volatile health timestamps never change the deterministic deployment receipt", () => {
  const base = {
    catalog: catalogWithRust("pricing"),
    consumer: "functions",
    domain: "pricing",
    version: "1.2.3",
    tag: "v1.2.3",
    commit: "a".repeat(40),
    artifactPath: "/tmp/OpenBurnBar-1.2.3-functions-deployment.json",
  };
  const first = healthyFunctionsEvidence();
  const second = healthyFunctionsEvidence();
  second.generatedAt = "2026-07-15T12:34:56Z";
  second.healthLive.timestamp = "different";
  second.healthReady.timestamp = "different";
  assert.deepEqual(
    buildReleaseEvidence({ ...base, healthEvidence: first }).deploymentReceipt,
    buildReleaseEvidence({ ...base, healthEvidence: second }).deploymentReceipt,
  );
});

test("release evidence requires exact stable tag and immutable asset name", () => {
  const base = {
    catalog: catalogWithRust("pricing"),
    consumer: "functions",
    domain: "pricing",
    version: "1.2.3",
    tag: "v1.2.3",
    commit: "a".repeat(40),
    artifactPath: "/tmp/OpenBurnBar-1.2.3-functions-deployment.json",
  };
  assert.throws(
    () => buildReleaseEvidence({ ...base, tag: "v1.2.3-beta.1" }),
    /tag must be v1.2.3/,
  );
  assert.throws(
    () =>
      buildReleaseEvidence({ ...base, artifactPath: "/tmp/functions.json" }),
    /artifact filename/,
  );
});

test("stable build metadata is accepted consistently without allowing prereleases", () => {
  const evidence = buildReleaseEvidence({
    catalog: catalogWithRust("pricing"),
    consumer: "functions",
    domain: "pricing",
    version: "1.2.3+build.7",
    tag: "v1.2.3+build.7",
    commit: "a".repeat(40),
    artifactPath: "/tmp/OpenBurnBar-1.2.3+build.7-functions-deployment.json",
    healthEvidence: healthyFunctionsEvidence("a".repeat(40), "v1.2.3+build.7"),
  });
  assert.equal(evidence.enabled, true);
  assert.equal(evidence.deploymentReceipt.release.version, "1.2.3+build.7");
});

test("console deployment evidence binds the exact live hosting identity", () => {
  const evidence = buildReleaseEvidence({
    catalog: catalogWithRust("cloudVault"),
    consumer: "console",
    domain: "cloudVault",
    version: "1.2.3",
    tag: "v1.2.3",
    commit: "a".repeat(40),
    artifactPath: "/tmp/OpenBurnBar-1.2.3-console-deployment.json",
    healthEvidence: healthyConsoleEvidence(),
  });
  assert.deepEqual(evidence.deploymentReceipt.deployment, {
    provider: "firebase-hosting",
    project: "burnbar",
    environment: "production",
    status: "healthy",
    healthChecks: ["marketing", "console", "deploymentIdentity"],
  });
});

test("console deployment evidence rejects stale and legacy live identities", () => {
  const base = {
    catalog: catalogWithRust("cloudVault"),
    consumer: "console",
    domain: "cloudVault",
    version: "1.2.3",
    tag: "v1.2.3",
    commit: "a".repeat(40),
    artifactPath: "/tmp/OpenBurnBar-1.2.3-console-deployment.json",
    healthEvidence: healthyConsoleEvidence(),
  };
  const stale = structuredClone(base.healthEvidence);
  stale.deploymentIdentity.commit = "b".repeat(40);
  assert.throws(
    () => buildReleaseEvidence({ ...base, healthEvidence: stale }),
    /live Rust deployment identity/,
  );
  const legacy = structuredClone(base.healthEvidence);
  legacy.deploymentIdentity.profile.mode = "legacy";
  assert.throws(
    () => buildReleaseEvidence({ ...base, healthEvidence: legacy }),
    /live Rust deployment identity/,
  );
});

test("console deployment evidence rejects unknown or contradictory health fields", () => {
  const base = {
    catalog: catalogWithRust("cloudVault"),
    consumer: "console",
    domain: "cloudVault",
    version: "1.2.3",
    tag: "v1.2.3",
    commit: "a".repeat(40),
    artifactPath: "/tmp/OpenBurnBar-1.2.3-console-deployment.json",
    healthEvidence: healthyConsoleEvidence(),
  };
  for (const mutate of [
    (health) => delete health.schemaVersion,
    (health) => (health.schemaVersion = 2),
    (health) => (health.untrusted = true),
    (health) => delete health.checks.console,
    (health) => (health.checks.extra = "ok"),
    (health) => (health.deploymentIdentity.extra = true),
    (health) => (health.deploymentIdentity.profile.extra = true),
  ]) {
    const invalid = structuredClone(base.healthEvidence);
    mutate(invalid);
    assert.throws(
      () => buildReleaseEvidence({ ...base, healthEvidence: invalid }),
      /Console health evidence|Console deployment/,
    );
  }
});
