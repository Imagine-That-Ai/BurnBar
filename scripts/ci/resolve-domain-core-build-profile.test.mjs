import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";
import {
  profileEnvironment,
  profileWebEnvironment,
  resolveDomainCoreBuildProfile,
  validateDomainCoreBuildProfiles,
} from "../lib/domain-core-build-profile.mjs";

const catalog = JSON.parse(readFileSync(resolve("config/domain-core-build-profiles.json"), "utf8"));

test("canonical profiles satisfy signed artifact invariants", () => {
  assert.equal(validateDomainCoreBuildProfiles(catalog), catalog);
  assert.equal(resolveDomainCoreBuildProfile(catalog, "public-production").evidenceEnabled, false);
  assert.equal(resolveDomainCoreBuildProfile(catalog, "internal").modes.quota, "shadow");
  assert.equal(resolveDomainCoreBuildProfile(catalog, "beta").rolloutChannel, "beta");
});

test("public signed profiles cannot accidentally enable shadow evidence", () => {
  const mutated = structuredClone(catalog);
  mutated.profiles["public-production"].modes.hermes = "shadow";
  assert.throws(() => validateDomainCoreBuildProfiles(mutated), /public signed profiles cannot/);
});

test("profile names, authorities, and distributions are inseparable", () => {
  const signedDevelopment = structuredClone(catalog);
  signedDevelopment.profiles.developer.artifactAuthority = "signed";
  assert.throws(() => validateDomainCoreBuildProfiles(signedDevelopment), /canonical profile identity/);

  const injected = structuredClone(catalog);
  injected.profiles["signed-development"] = {
    ...structuredClone(injected.profiles.developer),
    artifactAuthority: "signed",
  };
  assert.throws(() => validateDomainCoreBuildProfiles(injected), /profiles must exactly declare/);

  const wrongDefault = structuredClone(catalog);
  wrongDefault.defaultReleaseProfile = "internal";
  assert.throws(() => validateDomainCoreBuildProfiles(wrongDefault), /must be public-production/);
});

test("internal and beta profiles require the matching evidence channel and quota shadow", () => {
  for (const mutate of [
    (value) => {
      value.rolloutChannel = "beta";
    },
    (value) => {
      value.evidenceEnabled = false;
    },
    (value) => {
      value.modes.quota = "legacy";
    },
  ]) {
    const mutated = structuredClone(catalog);
    mutate(mutated.profiles.internal);
    assert.throws(() => validateDomainCoreBuildProfiles(mutated), /signed internal profiles require/);
  }
});

test("resolved environment is exhaustive and does not serialize null channels", () => {
  const environment = profileEnvironment(resolveDomainCoreBuildProfile(catalog, "public-production"));
  assert.equal(environment.OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL, "");
  assert.equal(environment.OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED, "0");
  assert.deepEqual(Object.keys(environment).sort(), [
    "OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY",
    "OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE",
    "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE",
    "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE",
    "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE",
    "OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION",
    "OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED",
    "OPENBURNBAR_DOMAIN_CORE_HERMES_MODE",
    "OPENBURNBAR_DOMAIN_CORE_PRICING_MODE",
    "OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE",
    "OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL",
  ]);
});

test("unknown profiles fail closed at build resolution", () => {
  assert.throws(() => resolveDomainCoreBuildProfile(catalog, "nightly-ish"), /unknown domain-core build profile/);
});

test("web build environment exposes only statically embeddable public names", () => {
  const environment = profileWebEnvironment(resolveDomainCoreBuildProfile(catalog, "public-production"));
  assert.equal(environment.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY, "signed");
  assert.equal(
    Object.keys(environment).every((key) => key.startsWith("NEXT_PUBLIC_")),
    true,
  );
});
