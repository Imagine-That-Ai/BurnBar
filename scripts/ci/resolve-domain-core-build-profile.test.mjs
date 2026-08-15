import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
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

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(SCRIPT_DIR, "..", "..");
const VERIFIER_REL = "scripts/ci/verify-domain-core-build-profile-artifact.mjs";
const RESOLVER_REL = "scripts/ci/resolve-domain-core-build-profile.mjs";
const VERIFIER_SUPPORT_RELS = [
  VERIFIER_REL,
  RESOLVER_REL,
  "scripts/lib/domain-core-activation.mjs",
  "scripts/lib/domain-core-artifact-profile.mjs",
  "scripts/lib/domain-core-build-profile.mjs",
  "scripts/lib/domain-core-candidate-receipt.mjs",
  "scripts/lib/domain-core-release-evidence.mjs",
];
const MANIFEST_REL = "crates/openburnbar-domain-core/union-abi-manifest.json";
const PROFILES_REL = "config/domain-core-build-profiles.json";
const DELETION_REL = "config/domain-core-legacy-deletion.json";

function fixtureGit(root, ...args) {
  return execFileSync("git", ["-C", root, ...args], {
    encoding: "utf8",
  }).trim();
}

/**
 * Build a synthetic git repo where commit C is the candidate (carrying the
 * union ABI manifest) and commit P is the activation (a descendant of C whose
 * diff touches only activation-allowed paths). HEAD is left at P, and the
 * artifact verifier sources are staged inside so the subprocess resolves the
 * fixture as its repo root.
 *
 * Mirrors the fixture shape from verify-domain-core-ios-profile-artifact.test.mjs.
 * The real checkout HEAD is a valid activation commit P only on the activation
 * merge itself; every descendant commit's C..HEAD diff carries unrelated
 * (forbidden) paths, so the release-bound C != P verification path must be
 * exercised against a fixture rather than the live checkout.
 */
function activationFixture({
  postActivationMainAdvance = false,
  postActivationArtifactSwap = false,
} = {}) {
  const root = mkdtempSync(join(tmpdir(), "resolve-profile-activation-"));
  for (const relativePath of VERIFIER_SUPPORT_RELS) {
    const destination = join(root, relativePath);
    mkdirSync(dirname(destination), { recursive: true });
    writeFileSync(destination, readFileSync(join(REPO_ROOT, relativePath)));
  }
  mkdirSync(join(root, "crates/openburnbar-domain-core"), { recursive: true });
  mkdirSync(join(root, "config"), { recursive: true });
  const manifest = {
    coreVersion: "0.3.0",
    abiVersion: 3,
    sourceSha256: "a".repeat(64),
  };
  writeFileSync(join(root, MANIFEST_REL), JSON.stringify(manifest));
  // Keep the candidate catalog valid but byte-distinct from activation P so
  // the required build-profile activation path is present in C..P.
  writeFileSync(join(root, PROFILES_REL), JSON.stringify(catalog));
  writeFileSync(join(root, DELETION_REL), JSON.stringify({ rows: [] }));
  fixtureGit(root, "init", "-q");
  fixtureGit(root, "config", "user.email", "test@openburnbar.invalid");
  fixtureGit(root, "config", "user.name", "OpenBurnBar Test");
  fixtureGit(root, "add", ".");
  fixtureGit(root, "commit", "-qm", "candidate C");
  const candidateCommit = fixtureGit(root, "rev-parse", "HEAD");

  // Activation P: change only the two REQUIRED_EXACT activation paths without
  // touching the manifest, so the attested core closure is unchanged.
  writeFileSync(join(root, PROFILES_REL), JSON.stringify(catalog, null, 2));
  writeFileSync(
    join(root, DELETION_REL),
    JSON.stringify({ rows: [{ id: "x" }] }),
  );
  fixtureGit(root, "add", ".");
  fixtureGit(root, "commit", "-qm", "activation P");
  const activationCommit = fixtureGit(root, "rev-parse", "HEAD");
  assert.notEqual(
    candidateCommit,
    activationCommit,
    "fixture requires distinct C and P",
  );
  if (postActivationMainAdvance) {
    // The ca605df1 shape: protected main advances past activation P with a
    // commit mixing an unrelated path and a trusted control-plane manifest
    // refresh before the release commit R is cut.
    mkdirSync(join(root, "functions"), { recursive: true });
    writeFileSync(
      join(root, "functions/.env.burnbar.production"),
      "MIN_INSTANCES=1\n",
    );
    writeFileSync(
      join(root, "config/domain-core-control-plane-manifest.json"),
      "release control plane\n",
    );
    fixtureGit(root, "add", ".");
    fixtureGit(root, "commit", "-qm", "post-activation mixed main advance");
  }
  if (postActivationArtifactSwap) {
    mkdirSync(join(root, "functions/vendor/openburnbar/domain-core-wasm"), {
      recursive: true,
    });
    writeFileSync(
      join(
        root,
        "functions/vendor/openburnbar/domain-core-wasm/openburnbar_domain_core_bg.wasm",
      ),
      "swapped wasm bytes\n",
    );
    fixtureGit(root, "add", ".");
    fixtureGit(root, "commit", "-qm", "post-activation artifact swap");
  }
  const releaseCommit = fixtureGit(root, "rev-parse", "HEAD");
  return { root, candidateCommit, activationCommit, releaseCommit, manifest };
}

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
  const temporaryRoot = mkdtempSync(
    join(tmpdir(), "openburnbar-domain-core-profile-"),
  );
  const windowsDirectory = join(temporaryRoot, "publish");
  const artifactPath = join(windowsDirectory, "domain-core-build-profile.json");
  const verifier = resolve(
    "scripts/ci/verify-domain-core-build-profile-artifact.mjs",
  );
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
    assert.match(
      valid.stdout,
      /domain-core artifact profile verified: public-production/,
    );

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
    assert.notEqual(
      malformed.status,
      0,
      "malformed BOM-prefixed receipts must still fail closed",
    );
    assert.match(malformed.stderr, /SyntaxError/);
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
});

test("release-bound verification keeps Functions artifacts candidate-scoped", () => {
  const fx = activationFixture();
  const temporaryRoot = mkdtempSync(
    join(tmpdir(), "openburnbar-functions-release-"),
  );
  const functionsDirectory = join(temporaryRoot, "functions");
  const generatedDirectory = join(functionsDirectory, "generated");
  const releaseVersion = "1.2.3";
  const releaseTag = `v${releaseVersion}`;
  const identity = {
    candidateCommit: fx.candidateCommit,
    coreVersion: fx.manifest.coreVersion,
    abiVersion: fx.manifest.abiVersion,
    sourceSha256: fx.manifest.sourceSha256,
  };
  const expected = resolveDomainCoreBuildProfile(
    catalog,
    "public-production",
    identity,
  );
  assert.equal(expected.release, undefined);
  mkdirSync(generatedDirectory, { recursive: true });
  writeFileSync(
    join(generatedDirectory, "domainCoreCandidateReceipt.js"),
    profileFunctionsJavaScript(expected),
    "utf8",
  );

  try {
    const valid = spawnSync(
      process.execPath,
      [
        join(fx.root, VERIFIER_REL),
        "--profile",
        "public-production",
        "--expected-candidate-commit",
        fx.candidateCommit,
        "--expected-release-commit",
        fx.releaseCommit,
        "--expected-release-version",
        releaseVersion,
        "--expected-release-tag",
        releaseTag,
        "--functions-dir",
        functionsDirectory,
      ],
      { encoding: "utf8" },
    );
    assert.equal(valid.status, 0, valid.stderr || valid.stdout);
    assert.match(
      valid.stdout,
      /domain-core artifact profile verified: public-production/,
    );
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
    rmSync(fx.root, { recursive: true, force: true });
  }
});

test("main Functions artifact without release flags stays valid and remains release-free", () => {
  const temporaryRoot = mkdtempSync(
    join(tmpdir(), "openburnbar-functions-main-"),
  );
  const functionsDirectory = join(temporaryRoot, "functions");
  const generatedDirectory = join(functionsDirectory, "generated");
  const verifier = resolve(
    "scripts/ci/verify-domain-core-build-profile-artifact.mjs",
  );
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
  assert.equal(expected.release, undefined);
  mkdirSync(generatedDirectory, { recursive: true });
  writeFileSync(
    join(generatedDirectory, "domainCoreCandidateReceipt.js"),
    profileFunctionsJavaScript(expected),
    "utf8",
  );

  try {
    const valid = spawnSync(
      process.execPath,
      [
        verifier,
        "--profile",
        "public-production",
        "--expected-candidate-commit",
        candidateCommit,
        "--functions-dir",
        functionsDirectory,
      ],
      { encoding: "utf8" },
    );
    assert.equal(valid.status, 0, valid.stderr || valid.stdout);
    assert.match(
      valid.stdout,
      /domain-core artifact profile verified: public-production/,
    );
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
});

test("mismatched release coordinates fail receipt verification", () => {
  const fx = activationFixture();
  const temporaryRoot = mkdtempSync(
    join(tmpdir(), "openburnbar-release-receipt-mismatch-"),
  );
  const artifactPath = join(temporaryRoot, "domain-core-build-profile.json");
  const releaseVersion = "1.2.3";
  const releaseTag = `v${releaseVersion}`;
  // Bake a well-formed but wrong release commit into the artifact; it can
  // never match the expected activation commit P.
  const artifactReleaseCommit = "f".repeat(40);
  const artifactProfile = resolveDomainCoreBuildProfile(
    catalog,
    "public-production",
    {
      candidateCommit: fx.candidateCommit,
      coreVersion: fx.manifest.coreVersion,
      abiVersion: fx.manifest.abiVersion,
      sourceSha256: fx.manifest.sourceSha256,
    },
    { version: releaseVersion, tag: releaseTag, commit: artifactReleaseCommit },
  );
  writeFileSync(artifactPath, JSON.stringify(artifactProfile), "utf8");

  try {
    const mismatched = spawnSync(
      process.execPath,
      [
        join(fx.root, VERIFIER_REL),
        "--profile",
        "public-production",
        "--expected-candidate-commit",
        fx.candidateCommit,
        "--expected-release-commit",
        fx.releaseCommit,
        "--expected-release-version",
        releaseVersion,
        "--expected-release-tag",
        releaseTag,
        "--receipt",
        artifactPath,
      ],
      { encoding: "utf8" },
    );
    assert.notEqual(
      mismatched.status,
      0,
      "mismatched release commit must fail verification",
    );
    assert.match(mismatched.stderr, /artifact profile mismatch/);
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
    rmSync(fx.root, { recursive: true, force: true });
  }
});

test("partial release triplets fail closed at profile resolution", () => {
  const validCoords = {
    version: "1.0.0",
    tag: "v1.0.0",
    commit: "c".repeat(40),
  };
  assert.deepEqual(
    resolveDomainCoreBuildProfile(
      catalog,
      "public-production",
      candidateIdentity,
      validCoords,
    ).release,
    validCoords,
  );
  for (const partial of [
    { commit: "c".repeat(40) },
    { version: "1.0.0" },
    { tag: "v1.0.0" },
    { commit: "c".repeat(40), version: "1.0.0" },
    { commit: "c".repeat(40), tag: "v1.0.0" },
    { version: "1.0.0", tag: "v1.0.0" },
  ]) {
    assert.throws(() =>
      resolveDomainCoreBuildProfile(
        catalog,
        "public-production",
        candidateIdentity,
        partial,
      ),
    );
  }
});

test("release coordinates validate the tag/version binding and commit format", () => {
  const releaseCommit = "c".repeat(40);
  assert.throws(
    () =>
      resolveDomainCoreBuildProfile(
        catalog,
        "public-production",
        candidateIdentity,
        {
          version: "1.0.0",
          tag: "v2.0.0",
          commit: releaseCommit,
        },
      ),
    /release tag must be v1.0.0/,
  );
  const prerelease = {
    version: "1.0.0-beta.1+build.7",
    tag: "v1.0.0-beta.1+build.7",
    commit: releaseCommit,
  };
  assert.deepEqual(
    resolveDomainCoreBuildProfile(
      catalog,
      "public-production",
      candidateIdentity,
      prerelease,
    ).release,
    prerelease,
  );
  assert.throws(
    () =>
      resolveDomainCoreBuildProfile(
        catalog,
        "public-production",
        candidateIdentity,
        { version: "1.0", tag: "v1.0", commit: releaseCommit },
      ),
    /release version is invalid/,
  );
  assert.throws(
    () =>
      resolveDomainCoreBuildProfile(
        catalog,
        "public-production",
        candidateIdentity,
        {
          version: "1.0.0",
          tag: "v1.0.0",
          commit: "short",
        },
      ),
    /release commit must be a full lowercase Git SHA-1/,
  );
});

test("active Rust release still enforces candidate/release commit separation", () => {
  const rustCatalog = structuredClone(catalog);
  rustCatalog.profiles["public-production"].modes.quota = "rust";
  assert.equal(validateDomainCoreBuildProfiles(rustCatalog), rustCatalog);
  const candidateCommit = "a".repeat(40);
  const releaseCommit = "c".repeat(40);
  assert.throws(
    () =>
      resolveDomainCoreBuildProfile(
        rustCatalog,
        "public-production",
        {
          ...candidateIdentity,
          candidateCommit,
        },
        {
          version: "1.0.0",
          tag: "v1.0.0",
          commit: candidateCommit,
        },
      ),
    /Rust activation requires distinct candidate and release commits/,
  );
  const separated = resolveDomainCoreBuildProfile(
    rustCatalog,
    "public-production",
    { ...candidateIdentity, candidateCommit },
    { version: "1.0.0", tag: "v1.0.0", commit: releaseCommit },
  );
  assert.deepEqual(separated.release, {
    version: "1.0.0",
    tag: "v1.0.0",
    commit: releaseCommit,
  });
  assert.notEqual(
    separated.release.commit,
    separated.candidateIdentity.candidateCommit,
  );
});

test("release checkout past activation P still resolves the signed candidate identity", () => {
  // Deploy workflows pass the release HEAD R as --expected-release-commit.
  // R is not the activation commit once protected main advances past P, so
  // both the profile resolver and the artifact verifier must re-derive P
  // from the committed authority files instead of validating C..R.
  const fx = activationFixture({ postActivationMainAdvance: true });
  assert.notEqual(fx.activationCommit, fx.releaseCommit);
  const temporaryRoot = mkdtempSync(
    join(tmpdir(), "openburnbar-release-past-activation-"),
  );
  const functionsDirectory = join(temporaryRoot, "functions");
  const generatedDirectory = join(functionsDirectory, "generated");
  const expected = resolveDomainCoreBuildProfile(catalog, "public-production", {
    candidateCommit: fx.candidateCommit,
    coreVersion: fx.manifest.coreVersion,
    abiVersion: fx.manifest.abiVersion,
    sourceSha256: fx.manifest.sourceSha256,
  });
  mkdirSync(generatedDirectory, { recursive: true });
  writeFileSync(
    join(generatedDirectory, "domainCoreCandidateReceipt.js"),
    profileFunctionsJavaScript(expected),
    "utf8",
  );

  try {
    const resolved = spawnSync(
      process.execPath,
      [
        join(fx.root, RESOLVER_REL),
        "--profile",
        "public-production",
        "--expected-candidate-commit",
        fx.candidateCommit,
        "--expected-release-commit",
        fx.releaseCommit,
        "--format",
        "json",
      ],
      { encoding: "utf8" },
    );
    assert.equal(resolved.status, 0, resolved.stderr || resolved.stdout);
    const profile = JSON.parse(resolved.stdout);
    assert.equal(profile.candidateIdentity.candidateCommit, fx.candidateCommit);
    assert.equal(
      profile.candidateIdentity.sourceSha256,
      fx.manifest.sourceSha256,
    );

    const verified = spawnSync(
      process.execPath,
      [
        join(fx.root, VERIFIER_REL),
        "--profile",
        "public-production",
        "--expected-candidate-commit",
        fx.candidateCommit,
        "--expected-release-commit",
        fx.releaseCommit,
        "--expected-release-version",
        "1.2.3",
        "--expected-release-tag",
        "v1.2.3",
        "--functions-dir",
        functionsDirectory,
      ],
      { encoding: "utf8" },
    );
    assert.equal(verified.status, 0, verified.stderr || verified.stdout);
    assert.match(
      verified.stdout,
      /domain-core artifact profile verified: public-production/,
    );
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
    rmSync(fx.root, { recursive: true, force: true });
  }
});

test("release checkout rejects post-activation deployed artifact drift", () => {
  const fx = activationFixture({ postActivationArtifactSwap: true });
  try {
    const resolved = spawnSync(
      process.execPath,
      [
        join(fx.root, RESOLVER_REL),
        "--profile",
        "public-production",
        "--expected-candidate-commit",
        fx.candidateCommit,
        "--expected-release-commit",
        fx.releaseCommit,
        "--format",
        "json",
      ],
      { encoding: "utf8" },
    );
    assert.notEqual(resolved.status, 0);
    assert.match(
      resolved.stderr,
      /domain-core activation authority drift after activation/,
    );
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
  }
});
