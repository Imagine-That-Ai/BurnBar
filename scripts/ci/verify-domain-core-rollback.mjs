#!/usr/bin/env node

import { readFileSync, writeFileSync } from "node:fs";

const FULL_SHA = /^[0-9a-f]{40}$/u;

const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  args.set(process.argv[index], process.argv[index + 1]);
}
const artifactPath = args.get("--artifact");
const reportPath = args.get("--report");
const expectedCommit = args.get("--expected-candidate-commit");
const expectedReleaseCommit = args.get("--expected-release-commit");
const expectedReleaseVersion = args.get("--expected-release-version");
const expectedReleaseTag = args.get("--expected-release-tag");
if (!artifactPath || !reportPath || !expectedCommit) {
  throw new Error("--artifact, --report, and --expected-candidate-commit are required");
}
const hasReleaseCoords =
  expectedReleaseCommit !== undefined ||
  expectedReleaseVersion !== undefined ||
  expectedReleaseTag !== undefined;
if (
  hasReleaseCoords &&
  (expectedReleaseCommit === undefined ||
    expectedReleaseVersion === undefined ||
    expectedReleaseTag === undefined)
) {
  throw new Error(
    "--expected-release-commit, --expected-release-version, and --expected-release-tag must be supplied together",
  );
}
const profile = JSON.parse(readFileSync(artifactPath, "utf8"));
const expectedDomains = [
  "cloudVault",
  "cloudVaultRewrap",
  "cloudVaultSearch",
  "hermes",
  "pricing",
  "quota",
];
if (
  profile.schemaVersion !== 1 ||
  profile.name !== "public-production-rollback" ||
  profile.artifactAuthority !== "signed" ||
  profile.distribution !== "public" ||
  profile.evidenceEnabled !== false ||
  profile.rolloutChannel !== null ||
  profile.candidateIdentity?.candidateCommit !== expectedCommit
) {
  throw new Error("rollback artifact is not the dedicated signed public-production-rollback candidate profile");
}
const actualDomains = Object.keys(profile.modes ?? {}).sort();
if (
  actualDomains.length !== expectedDomains.length ||
  actualDomains.some((domain, index) => domain !== expectedDomains[index]) ||
  actualDomains.some((domain) => profile.modes[domain] !== "legacy")
) {
  throw new Error("rollback artifact does not restore every domain to the legacy implementation");
}
if (hasReleaseCoords) {
  const release = profile.release;
  if (
    !release ||
    typeof release !== "object" ||
    Array.isArray(release)
  ) {
    throw new Error("rollback artifact release coordinates are missing");
  }
  const releaseKeys = Object.keys(release).sort();
  const expectedReleaseKeys = ["commit", "tag", "version"];
  if (
    releaseKeys.length !== expectedReleaseKeys.length ||
    releaseKeys.some((key, index) => key !== expectedReleaseKeys[index])
  ) {
    throw new Error("rollback artifact release coordinates are missing");
  }
  if (
    typeof release.commit !== "string" ||
    !FULL_SHA.test(release.commit) ||
    release.commit !== expectedReleaseCommit
  ) {
    throw new Error(
      "rollback artifact release commit does not match the expected release P",
    );
  }
  if (release.version !== expectedReleaseVersion) {
    throw new Error(
      "rollback artifact release version does not match the expected release version",
    );
  }
  if (release.tag !== expectedReleaseTag) {
    throw new Error(
      "rollback artifact release tag does not match the expected release tag",
    );
  }
  if (release.commit === profile.candidateIdentity?.candidateCommit) {
    throw new Error(
      "rollback artifact release commit must be distinct from the candidate commit",
    );
  }
}
const report = {
  schemaVersion: 1,
  drill: "signed-public-production-rollback-profile",
  artifactProfile: "public-production-rollback",
  candidateCommit: expectedCommit,
  restoredMode: "legacy",
  restoredDomains: actualDomains,
};
writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });