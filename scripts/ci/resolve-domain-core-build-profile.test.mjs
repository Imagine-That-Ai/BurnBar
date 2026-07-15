import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";
import {
  parseDomainCoreFunctionsJavaScript,
  profileAppleEnvironment,
  profileEnvironment,
  profileFunctionsJavaScript,
  profileMSBuildProperties,
  profileWebEnvironment,
  resolveDomainCoreBuildProfile,
  validateDomainCoreBuildProfiles,
} from "../lib/domain-core-build-profile.mjs";

const catalog = JSON.parse(
  readFileSync(resolve("config/domain-core-build-profiles.json"), "utf8"),
);
const candidateIdentity = {
  candidateCommit: "a".repeat(40),
  coreVersion: "0.1.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
};
const signedProfile = (name) =>
  resolveDomainCoreBuildProfile(catalog, name, candidateIdentity);

test("canonical profiles satisfy signed artifact invariants", () => {
  assert.equal(validateDomainCoreBuildProfiles(catalog), catalog);
  assert.equal(signedProfile("public-production").evidenceEnabled, false);
  assert.deepEqual(
    new Set(Object.values(signedProfile("public-production-rollback").modes)),
    new Set(["legacy"]),
  );
  assert.equal(signedProfile("internal").modes.quota, "shadow");
  assert.equal(signedProfile("beta").rolloutChannel, "beta");
});

test("the signed rollback profile is immutable and permanently legacy", () => {
  const mutated = structuredClone(catalog);
  mutated.profiles["public-production-rollback"].modes.pricing = "rust";
  assert.throws(
    () => validateDomainCoreBuildProfiles(mutated),
    /every mode must remain legacy/,
  );
});

test("public signed profiles cannot accidentally enable shadow evidence", () => {
  const mutated = structuredClone(catalog);
  mutated.profiles["public-production"].modes.hermes = "shadow";
  assert.throws(
    () => validateDomainCoreBuildProfiles(mutated),
    /public signed profiles cannot/,
  );
});

test("profile names, authorities, and distributions are inseparable", () => {
  const signedDevelopment = structuredClone(catalog);
  signedDevelopment.profiles.developer.artifactAuthority = "signed";
  assert.throws(
    () => validateDomainCoreBuildProfiles(signedDevelopment),
    /canonical profile identity/,
  );

  const injected = structuredClone(catalog);
  injected.profiles["signed-development"] = {
    ...structuredClone(injected.profiles.developer),
    artifactAuthority: "signed",
  };
  assert.throws(
    () => validateDomainCoreBuildProfiles(injected),
    /profiles must exactly declare/,
  );

  const wrongDefault = structuredClone(catalog);
  wrongDefault.defaultReleaseProfile = "internal";
  assert.throws(
    () => validateDomainCoreBuildProfiles(wrongDefault),
    /must be public-production/,
  );
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
    assert.throws(
      () => validateDomainCoreBuildProfiles(mutated),
      /signed internal profiles require/,
    );
  }
});

test("resolved environment is exhaustive and does not serialize null channels", () => {
  const environment = profileEnvironment(signedProfile("public-production"));
  assert.equal(environment.OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL, "");
  assert.equal(environment.OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED, "0");
  assert.deepEqual(Object.keys(environment).sort(), [
    "OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY",
    "OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE",
    "OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT",
    "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE",
    "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE",
    "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE",
    "OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION",
    "OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED",
    "OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION",
    "OPENBURNBAR_DOMAIN_CORE_EXPECTED_SOURCE_SHA256",
    "OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION",
    "OPENBURNBAR_DOMAIN_CORE_HERMES_MODE",
    "OPENBURNBAR_DOMAIN_CORE_PRICING_MODE",
    "OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE",
    "OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL",
  ]);
});

test("unknown profiles fail closed at build resolution", () => {
  assert.throws(
    () => resolveDomainCoreBuildProfile(catalog, "nightly-ish"),
    /unknown domain-core build profile/,
  );
});

test("web build environment exposes only statically embeddable public names", () => {
  const environment = profileWebEnvironment(signedProfile("public-production"));
  assert.equal(
    environment.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY,
    "signed",
  );
  assert.equal(
    Object.keys(environment).every((key) => key.startsWith("NEXT_PUBLIC_")),
    true,
  );
});

test("signed profiles require one complete immutable candidate identity", () => {
  assert.throws(
    () => resolveDomainCoreBuildProfile(catalog, "public-production"),
    /require a complete candidate identity/,
  );
  assert.throws(
    () =>
      resolveDomainCoreBuildProfile(catalog, "public-production", {
        ...candidateIdentity,
        extra: true,
      }),
    /must contain exactly/,
  );
  assert.throws(
    () =>
      resolveDomainCoreBuildProfile(catalog, "public-production", {
        ...candidateIdentity,
        candidateCommit: "abc",
      }),
    /full lowercase Git SHA-1/,
  );
});

test("developer profiles may omit or carry one complete test candidate identity", () => {
  const profile = resolveDomainCoreBuildProfile(catalog, "developer");
  assert.equal(profile.candidateIdentity, null);
  assert.equal(
    "OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT" in profileEnvironment(profile),
    false,
  );
  assert.deepEqual(
    resolveDomainCoreBuildProfile(catalog, "developer", candidateIdentity)
      .candidateIdentity,
    candidateIdentity,
  );
  assert.throws(
    () =>
      resolveDomainCoreBuildProfile(catalog, "developer", {
        ...candidateIdentity,
        sourceSha256: "bad",
      }),
    /lowercase SHA-256/,
  );
});

test("all signed platform formatters carry the exact same candidate tuple", () => {
  const profile = signedProfile("internal");
  assert.deepEqual(
    {
      generic: {
        commit:
          profileEnvironment(profile).OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT,
        version:
          profileEnvironment(profile).OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION,
        abi: profileEnvironment(profile)
          .OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION,
        source:
          profileEnvironment(profile)
            .OPENBURNBAR_DOMAIN_CORE_EXPECTED_SOURCE_SHA256,
      },
      apple: {
        commit: profileAppleEnvironment(profile).DOMAIN_CORE_CANDIDATE_COMMIT,
        version: profileAppleEnvironment(profile).DOMAIN_CORE_EXPECTED_VERSION,
        abi: profileAppleEnvironment(profile).DOMAIN_CORE_EXPECTED_ABI_VERSION,
        source:
          profileAppleEnvironment(profile).DOMAIN_CORE_EXPECTED_SOURCE_SHA256,
      },
      windows: {
        commit: profileMSBuildProperties(profile).DomainCoreCandidateCommit,
        version: profileMSBuildProperties(profile).DomainCoreExpectedVersion,
        abi: profileMSBuildProperties(profile).DomainCoreExpectedAbiVersion,
        source:
          profileMSBuildProperties(profile).DomainCoreExpectedSourceSha256,
      },
    },
    {
      generic: {
        commit: candidateIdentity.candidateCommit,
        version: "0.1.0",
        abi: "3",
        source: candidateIdentity.sourceSha256,
      },
      apple: {
        commit: candidateIdentity.candidateCommit,
        version: "0.1.0",
        abi: "3",
        source: candidateIdentity.sourceSha256,
      },
      windows: {
        commit: candidateIdentity.candidateCommit,
        version: "0.1.0",
        abi: "3",
        source: candidateIdentity.sourceSha256,
      },
    },
  );
});

test("Functions artifact module embeds the validated signed receipt without runtime environment authority", () => {
  const profile = signedProfile("public-production");
  const source = profileFunctionsJavaScript(profile);
  assert.match(
    source,
    /exports\.DOMAIN_CORE_CANDIDATE_RECEIPT = Object\.freeze/,
  );
  assert.match(source, new RegExp(candidateIdentity.candidateCommit));
  assert.match(source, new RegExp(candidateIdentity.sourceSha256));
  assert.deepEqual(parseDomainCoreFunctionsJavaScript(source), profile);
  assert.throws(
    () =>
      parseDomainCoreFunctionsJavaScript(
        `${source}\nconsole.log("unexpected");\n`,
      ),
    /invalid generated envelope/,
  );
  const moduleExports = {};
  Function("exports", source)(moduleExports);
  assert.equal(
    Object.isFrozen(moduleExports.DOMAIN_CORE_CANDIDATE_RECEIPT),
    true,
  );
  assert.equal(
    Object.isFrozen(
      moduleExports.DOMAIN_CORE_CANDIDATE_RECEIPT.candidateIdentity,
    ),
    true,
  );
  assert.equal(
    Object.isFrozen(moduleExports.DOMAIN_CORE_CANDIDATE_RECEIPT.modes),
    true,
  );
  assert.throws(
    () =>
      profileFunctionsJavaScript(
        resolveDomainCoreBuildProfile(catalog, "developer"),
      ),
    /requires a signed profile/,
  );
});

test("artifact verifier accepts MSBuild UTF-8 BOM receipts and still rejects malformed JSON", () => {
  const temporaryRoot = mkdtempSync(join(tmpdir(), "openburnbar-domain-core-profile-"));
  const windowsDirectory = join(temporaryRoot, "publish");
  const artifactPath = join(windowsDirectory, "domain-core-build-profile.json");
  const verifier = resolve("scripts/ci/verify-domain-core-build-profile-artifact.mjs");
  const manifest = JSON.parse(
    readFileSync(
      resolve("crates/openburnbar-domain-core/union-abi-manifest.json"),
      "utf8",
    ),
  );
  const candidateCommit = spawnSync("git", ["rev-parse", "HEAD"], {
    encoding: "utf8",
  }).stdout.trim();
  const expected = resolveDomainCoreBuildProfile(catalog, "public-production", {
    candidateCommit,
    coreVersion: manifest.coreVersion,
    abiVersion: manifest.abiVersion,
    sourceSha256: manifest.sourceSha256,
  });
  mkdirSync(windowsDirectory, { recursive: true });
  writeFileSync(
    join(windowsDirectory, "OpenBurnBar.App.Configuration.dll"),
    [
      "OpenBurnBar.DomainCore.BuildProfile",
      "OpenBurnBar.DomainCore.BuildAuthority",
      "OpenBurnBar.DomainCore.CandidateCommit",
      "OpenBurnBar.DomainCore.ExpectedVersion",
      "OpenBurnBar.DomainCore.ExpectedAbiVersion",
      "OpenBurnBar.DomainCore.ExpectedSourceSha256",
      expected.name,
      expected.artifactAuthority,
      expected.distribution,
      expected.candidateIdentity.candidateCommit,
      expected.candidateIdentity.coreVersion,
      String(expected.candidateIdentity.abiVersion),
      expected.candidateIdentity.sourceSha256,
      ...Object.values(expected.modes),
    ].join("\0"),
    "utf8",
  );

  try {
    writeFileSync(artifactPath, `\uFEFF${JSON.stringify(expected)}\n`, "utf8");
    const valid = spawnSync(
      process.execPath,
      [
        verifier,
        "--profile",
        "public-production",
        "--expected-candidate-commit",
        candidateCommit,
        "--windows-dir",
        windowsDirectory,
      ],
      { encoding: "utf8" },
    );
    assert.equal(valid.status, 0, valid.stderr || valid.stdout);
    assert.match(valid.stdout, /domain-core artifact profile verified: public-production/);

    writeFileSync(artifactPath, "\uFEFF{not-json}\n", "utf8");
    const malformed = spawnSync(
      process.execPath,
      [
        verifier,
        "--profile",
        "public-production",
        "--expected-candidate-commit",
        candidateCommit,
        "--windows-dir",
        windowsDirectory,
      ],
      { encoding: "utf8" },
    );
    assert.notEqual(malformed.status, 0, "malformed BOM-prefixed receipts must still fail closed");
    assert.match(malformed.stderr, /SyntaxError/);
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
});
