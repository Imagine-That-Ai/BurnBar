import assert from "node:assert/strict";
import test from "node:test";

import {
  DOMAIN_CORE_PUBLIC_PROFILE,
  DOMAIN_CORE_ROLLBACK_PROFILE,
  candidateArtifactName,
  nativeAttestationName,
  nativeEvidenceDomains,
  nativePredicateName,
  publicProfileSha256,
  publicDomainProfileSha256,
  resolveNativeReleaseProfile,
  resolveProtectedSignerCoordinates,
  rollbackArtifactName,
  validateNativeActivationSelector,
  validateResolvedProfile,
} from "./domain-core-native-release.mjs";
import { validateReleaseActivation } from "./domain-core-release-evidence.mjs";

const CANDIDATE = {
  candidateCommit: "a".repeat(40),
  coreVersion: "1.2.3",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
};

function profile(name = DOMAIN_CORE_PUBLIC_PROFILE) {
  return {
    schemaVersion: 1,
    name,
    artifactAuthority: "signed",
    distribution: "public",
    rolloutChannel: null,
    evidenceEnabled: false,
    modes: {
      quota: "rust",
      cloudVault: "rust",
      cloudVaultRewrap:
        name === DOMAIN_CORE_ROLLBACK_PROFILE ? "legacy" : "rust",
      cloudVaultSearch:
        name === DOMAIN_CORE_ROLLBACK_PROFILE ? "legacy" : "rust",
      hermes: name === DOMAIN_CORE_ROLLBACK_PROFILE ? "legacy" : "rust",
      pricing: name === DOMAIN_CORE_ROLLBACK_PROFILE ? "legacy" : "rust",
    },
    candidateIdentity: CANDIDATE,
  };
}

function rollbackProfile() {
  const value = profile(DOMAIN_CORE_ROLLBACK_PROFILE);
  value.modes = Object.fromEntries(
    Object.keys(value.modes).map((domain) => [domain, "legacy"]),
  );
  return value;
}

test("tag releases force public-production", () => {
  assert.equal(
    resolveNativeReleaseProfile({ eventName: "push", requestedProfile: "" }),
    DOMAIN_CORE_PUBLIC_PROFILE,
  );
  assert.throws(
    () =>
      resolveNativeReleaseProfile({
        eventName: "push",
        requestedProfile: DOMAIN_CORE_ROLLBACK_PROFILE,
      }),
    /must use public-production/,
  );
});

test("manual rollback requires an explicit immutable profile name", () => {
  assert.equal(
    resolveNativeReleaseProfile({
      eventName: "workflow_dispatch",
      requestedProfile: DOMAIN_CORE_ROLLBACK_PROFILE,
    }),
    DOMAIN_CORE_ROLLBACK_PROFILE,
  );
  for (const requestedProfile of ["", "developer", "internal", undefined]) {
    assert.throws(() =>
      resolveNativeReleaseProfile({
        eventName: "workflow_dispatch",
        requestedProfile,
      }),
    );
  }
});

test("source artifact names bind candidate, run, and attempt", () => {
  const run = { runId: 123, runAttempt: 4 };
  assert.equal(
    candidateArtifactName(CANDIDATE.candidateCommit, run),
    `domain-core-candidate-bundle-${CANDIDATE.candidateCommit}-123-4`,
  );
  assert.equal(
    rollbackArtifactName(CANDIDATE.candidateCommit, run),
    `domain-core-public-production-rollback-${CANDIDATE.candidateCommit}-123-4`,
  );
});

test("protected signer coordinates must be unique and exact", () => {
  const verified = [
    {
      verificationResult: {
        statement: {
          subject: [
            {
              name: "domain-core-candidate-bundle.json",
              digest: { sha256: "c".repeat(64) },
            },
          ],
        },
        signature: {
          certificate: {
            runInvocationURI:
              "https://github.com/Imagine-That-Ai/BurnBar/actions/runs/987/attempts/2",
          },
        },
      },
    },
  ];
  assert.deepEqual(resolveProtectedSignerCoordinates(verified, CANDIDATE), {
    runId: 987,
    runAttempt: 2,
  });
  assert.throws(
    () =>
      resolveProtectedSignerCoordinates(
        [...verified, structuredClone(verified[0])].map((entry, index) => {
          entry.verificationResult.signature.certificate.runInvocationURI = `https://github.com/Imagine-That-Ai/BurnBar/actions/runs/${987 + index}/attempts/2`;
          return entry;
        }),
        CANDIDATE,
      ),
    /exactly one protected signer run/,
  );
});

test("profile digest binds the exact candidate and modes", () => {
  const value = profile();
  const digest = publicProfileSha256(value, value.name, CANDIDATE);
  assert.match(digest, /^[0-9a-f]{64}$/u);
  const changed = structuredClone(value);
  changed.modes.quota = "legacy";
  assert.notEqual(
    digest,
    publicProfileSha256(changed, changed.name, CANDIDATE),
  );
  const wrongCandidate = structuredClone(value);
  wrongCandidate.candidateIdentity.candidateCommit = "c".repeat(40);
  assert.throws(() =>
    validateResolvedProfile(wrongCandidate, wrongCandidate.name, CANDIDATE),
  );
});

test("rollback profile is all-legacy and cannot emit native domain attestations", () => {
  const value = rollbackProfile();
  validateResolvedProfile(value, value.name, CANDIDATE);
  for (const consumer of ["apple", "android", "windows"]) {
    assert.deepEqual(nativeEvidenceDomains(consumer, value, value.name), []);
  }
  const hostile = structuredClone(value);
  hostile.modes.quota = "rust";
  assert.throws(
    () => validateResolvedProfile(hostile, hostile.name, CANDIDATE),
    /permanently select legacy/,
  );
});

test("public evidence includes only Rust-authoritative consumer domains", () => {
  const value = profile();
  value.modes.cloudVaultSearch = "legacy";
  assert.deepEqual(nativeEvidenceDomains("android", value, value.name), [
    "cloudVault",
    "cloudVaultRewrap",
    "hermes",
  ]);
});

test("native evidence names are deterministic and traversal-safe", () => {
  assert.equal(
    nativePredicateName("apple", "1.2.3", "quota"),
    "OpenBurnBar-1.2.3-apple-quota-domain-core.predicate.json",
  );
  assert.equal(
    nativeAttestationName("windows", "1.2.3", "cloudVault"),
    "OpenBurnBar-1.2.3-windows-cloudVault-domain-core.sigstore.json",
  );
  assert.throws(() => nativePredicateName("apple", "../1.2.3", "quota"));
});

function activationSelector({
  activationCommit,
  releaseCommit,
  selectedProfile,
}) {
  return {
    active: true,
    candidateCommit: CANDIDATE.candidateCommit,
    activationCommit,
    releaseCommit,
    coreVersion: CANDIDATE.coreVersion,
    abiVersion: CANDIDATE.abiVersion,
    sourceSha256: CANDIDATE.sourceSha256,
    changedPathsSha256: "d".repeat(64),
    domains: Object.entries(selectedProfile.modes)
      .filter(([, mode]) => mode === "rust")
      .map(([domain], index) => ({
        domain,
        rowId: `${domain}.row`,
        promotionReceiptPath: `receipts/${domain}.json`,
        attestationPath: `attestations/${domain}.json`,
        bundlePath: `bundles/${domain}.json`,
        provenancePath: `provenance/${domain}.json`,
        signerRunId: 100 + index,
        signerRunAttempt: 1,
        publicProfileSha256: publicDomainProfileSha256(selectedProfile, domain),
      })),
  };
}

test("native selector binds authority P independently from post-deletion release D", () => {
  const selectedProfile = profile();
  const activationCommit = "c".repeat(40);
  const releaseCommit = "d".repeat(40);
  const selector = activationSelector({
    activationCommit,
    releaseCommit,
    selectedProfile,
  });
  const result = validateNativeActivationSelector(selector, {
    candidate: CANDIDATE,
    releaseCommit,
    profile: selectedProfile,
    profileName: DOMAIN_CORE_PUBLIC_PROFILE,
  });
  assert.equal(result.activation.activationCommit, activationCommit);
  assert.equal(result.releaseCommit, releaseCommit);
  assert.deepEqual(
    validateReleaseActivation(result.activation, {
      candidate: CANDIDATE,
      releaseCommit,
    }),
    result.activation,
  );

  for (const invalid of [
    { ...selector, releaseCommit: activationCommit },
    Object.fromEntries(
      Object.entries(selector).filter(([key]) => key !== "releaseCommit"),
    ),
  ]) {
    assert.throws(
      () =>
        validateNativeActivationSelector(invalid, {
          candidate: CANDIDATE,
          releaseCommit,
          profile: selectedProfile,
          profileName: DOMAIN_CORE_PUBLIC_PROFILE,
        }),
      /release|selector/u,
    );
  }
});

test("release A selector keeps authority and release at P", () => {
  const selectedProfile = profile();
  const activationCommit = "c".repeat(40);
  const result = validateNativeActivationSelector(
    activationSelector({
      activationCommit,
      releaseCommit: activationCommit,
      selectedProfile,
    }),
    {
      candidate: CANDIDATE,
      releaseCommit: activationCommit,
      profile: selectedProfile,
      profileName: DOMAIN_CORE_PUBLIC_PROFILE,
    },
  );
  assert.equal(result.activation.activationCommit, activationCommit);
  assert.equal(result.releaseCommit, activationCommit);
});
