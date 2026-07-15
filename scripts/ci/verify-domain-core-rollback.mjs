#!/usr/bin/env node

import { readFileSync, writeFileSync } from "node:fs";

const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  args.set(process.argv[index], process.argv[index + 1]);
}
const artifactPath = args.get("--artifact");
const reportPath = args.get("--report");
const expectedCommit = args.get("--expected-candidate-commit");
if (!artifactPath || !reportPath || !expectedCommit) {
  throw new Error("--artifact, --report, and --expected-candidate-commit are required");
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
  profile.name !== "public-production" ||
  profile.artifactAuthority !== "signed" ||
  profile.distribution !== "public" ||
  profile.evidenceEnabled !== false ||
  profile.rolloutChannel !== null ||
  profile.candidateIdentity?.candidateCommit !== expectedCommit
) {
  throw new Error("rollback artifact is not the signed public-production candidate profile");
}
const actualDomains = Object.keys(profile.modes ?? {}).sort();
if (
  actualDomains.length !== expectedDomains.length ||
  actualDomains.some((domain, index) => domain !== expectedDomains[index]) ||
  actualDomains.some((domain) => profile.modes[domain] !== "legacy")
) {
  throw new Error("rollback artifact does not restore every domain to the legacy implementation");
}
const report = {
  schemaVersion: 1,
  drill: "signed-public-production-profile",
  candidateCommit: expectedCommit,
  restoredMode: "legacy",
  restoredDomains: actualDomains,
};
writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
